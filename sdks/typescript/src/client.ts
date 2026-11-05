import { Socket } from "phoenix";
import type { Channel } from "phoenix";
import { ApiError, asApiError, channelError } from "./errors.js";
import { endpointURL, request } from "./http.js";
import type { CallOptions, Client, ClientOptions, FyrletContract, Subscription, SubscriptionState } from "./types.js";

interface Identity { project_id: string; subject_id: string }
type ManagedController = AbortController & { dispose: () => void };
interface Snapshot extends Identity {
  protocol_version: number;
  subscription_id: string;
  generation: string;
  seq: number;
  data: unknown;
}

interface Entry {
  id: string;
  name: string;
  params: unknown;
  state: SubscriptionState<unknown>;
  listeners: Set<(state: SubscriptionState<unknown>) => void>;
  channel: Channel | undefined;
}

export function createClient<Contract extends FyrletContract>(options: ClientOptions): Client<Contract> {
  return new FyrletClient(options) as Client<Contract>;
}

class FyrletClient implements Client<FyrletContract> {
  private readonly endpoint: string;
  private readonly fetcher: typeof globalThis.fetch;
  private readonly createId: () => string;
  private readonly entries = new Map<string, Entry>();
  private readonly controllers = new Set<ManagedController>();
  private socket: Socket | undefined;
  private identity: Identity | undefined;
  private token: string | undefined;
  private tokenFlight: Promise<string> | undefined;
  private tokenFlightForced = false;
  private connecting: Promise<void> | undefined;
  private retryTimer: ReturnType<typeof setTimeout> | undefined;
  private epoch = 0;
  private retries = 0;
  private closed = false;

  constructor(private readonly options: ClientOptions) {
    this.endpoint = endpointURL(options.endpoint);
    this.fetcher = options.fetch ?? globalThis.fetch;
    this.createId = options.createId ?? (() => {
      if (!globalThis.crypto?.randomUUID) throw new TypeError("Provide createId on runtimes without crypto.randomUUID");
      return globalThis.crypto.randomUUID();
    });
    if (!options.projectId) throw new TypeError("projectId is required");
  }

  async call(name: string, input: unknown, options: CallOptions = {}): Promise<unknown> {
    this.assertOpen();
    const idempotencyKey = options.idempotencyKey ?? this.createId();
    const controller = this.controller(options.signal);
    const perform = async (token: string) => this.http<unknown>(`/api/v1/operations/${encodeURIComponent(name)}`, token, {
      method: "POST",
      headers: { "content-type": "application/json", "idempotency-key": idempotencyKey },
      body: JSON.stringify({ input }),
      signal: controller.signal,
    });

    try {
      const token = await this.awaitToken(this.authorize(false), controller.signal);
      this.assertOpen();
      try {
        return await perform(token);
      } catch (error) {
        if (!(error instanceof ApiError) || error.status !== 401) throw error;
        const fresh = await this.awaitToken(this.authorize(true), controller.signal);
        this.assertOpen();
        return await perform(fresh);
      }
    } catch (error) {
      if (this.isAuthError(error)) this.failAll(error as ApiError);
      throw error;
    } finally {
      this.controllers.delete(controller);
      controller.dispose();
    }
  }

  subscribe(name: string, params: unknown): Subscription<unknown> {
    this.assertOpen();
    const id = this.createId();
    if (this.entries.has(id)) throw new TypeError("createId returned a duplicate subscription ID");
    const entry: Entry = {
      id, name, params, listeners: new Set(), channel: undefined,
      state: { status: "connecting", data: undefined, error: undefined, generation: undefined, seq: 0 },
    };
    this.entries.set(id, entry);
    if (this.socket) this.attach(entry, this.socket, this.epoch);
    else this.start(false);

    return {
      getState: () => entry.state,
      onChange: (listener) => {
        entry.listeners.add(listener);
        this.notify(entry, listener);
        return () => { entry.listeners.delete(listener); };
      },
      refresh: () => new Promise<void>((resolve, reject) => {
        if (entry.state.status !== "ready" || !entry.channel) {
          reject(new ApiError({ code: "NOT_READY", message: "The subscription is not ready" }));
          return;
        }
        entry.channel.push("refresh", {}, this.options.timeoutMs ?? 10_000)
          .receive("ok", () => resolve())
          .receive("error", (payload: unknown) => reject(channelError(payload)))
          .receive("timeout", () => reject(new ApiError({ code: "TIMEOUT", message: "Refresh was not acknowledged", retryable: true })));
      }),
      unsubscribe: () => {
        if (!this.entries.delete(id)) return;
        const channel = entry.channel;
        entry.channel = undefined;
        channel?.leave(0);
        this.setState(entry, { ...entry.state, status: "closed", data: undefined, error: undefined });
        entry.listeners.clear();
        if (!this.entries.size) this.detach();
      },
    };
  }

  async reconnect(): Promise<void> {
    this.assertOpen();
    this.detach();
    for (const entry of this.entries.values()) this.setState(entry, { ...entry.state, status: "recovering", error: undefined });
    if (this.entries.size) {
      try { await this.connect(true); }
      catch (error) { this.connectionFailed(error); throw error; }
    }
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.detach();
    for (const controller of this.controllers) { controller.abort(); controller.dispose(); }
    this.controllers.clear();
    for (const entry of this.entries.values()) {
      this.setState(entry, { ...entry.state, status: "closed", data: undefined, error: undefined });
      entry.listeners.clear();
    }
    this.entries.clear();
    this.token = undefined;
  }

  private authorize(forceRefresh: boolean): Promise<string> {
    if (this.tokenFlight) {
      if (forceRefresh && !this.tokenFlightForced) {
        return this.tokenFlight.then(() => this.authorize(true), () => this.authorize(true));
      }
      return this.tokenFlight;
    }
    if (this.token && !forceRefresh) return Promise.resolve(this.token);
    this.assertOpen();
    const epoch = this.epoch;
    const flight = (async () => {
      let token = await this.options.getToken({ forceRefresh });
      this.assertOpen();
      if (typeof token !== "string" || !token.startsWith("rts_")) {
        throw new ApiError({ code: "UNAUTHENTICATED", message: "getToken must return a user session token" });
      }
      const controller = this.controller();
      try {
        let identity: Identity;
        try {
          identity = await this.http<Identity>("/api/v1/identity", token, { signal: controller.signal });
        } catch (error) {
          if (forceRefresh || !(error instanceof ApiError) || error.status !== 401) throw error;
          token = await this.options.getToken({ forceRefresh: true });
          if (typeof token !== "string" || !token.startsWith("rts_")) throw new ApiError({ code: "UNAUTHENTICATED", message: "Expected a user session token" });
          this.assertOpen();
          identity = await this.http<Identity>("/api/v1/identity", token, { signal: controller.signal });
        }
        this.assertOpen();
        if (identity.project_id !== this.options.projectId || (this.identity && identity.subject_id !== this.identity.subject_id)) {
          throw new ApiError({ code: "FORBIDDEN", message: "Create a new client when changing accounts" });
        }
        this.identity = identity;
        if (this.epoch === epoch) this.token = token;
        return token;
      } finally {
        this.controllers.delete(controller);
        controller.dispose();
      }
    })();
    this.tokenFlight = flight;
    this.tokenFlightForced = forceRefresh;
    void flight.finally(() => { if (this.tokenFlight === flight) this.tokenFlight = undefined; }).catch(() => {});
    return flight;
  }

  private connect(forceRefresh: boolean): Promise<void> {
    if (this.connecting) return this.connecting;
    if (this.closed || !this.entries.size) return Promise.resolve();
    const epoch = this.epoch;
    const flight = (async () => {
      const token = await this.authorize(forceRefresh);
      if (this.closed || this.epoch !== epoch || !this.entries.size) return;
      const socketOptions = {
        params: { project_id: this.options.projectId },
        authToken: () => token,
        timeout: this.options.timeoutMs ?? 10_000,
        ...(this.options.WebSocket ? { transport: this.options.WebSocket } : {}),
      };
      const socket = new Socket(`${this.endpoint}/socket`, socketOptions);
      this.socket = socket;
      socket.onError(() => this.transportFailed(socket));
      socket.onClose(() => this.transportFailed(socket));
      for (const entry of this.entries.values()) {
        if (entry.state.status !== "error") this.attach(entry, socket, epoch);
      }
      socket.connect();
    })();
    this.connecting = flight;
    void flight.finally(() => { if (this.connecting === flight) this.connecting = undefined; }).catch(() => {});
    return flight;
  }

  private attach(entry: Entry, socket: Socket, epoch: number): void {
    const channel = socket.channel(`subscription:${entry.id}`, { protocol_version: 1, name: entry.name, params: entry.params });
    entry.channel = channel;
    const current = () => !this.closed && this.epoch === epoch && entry.channel === channel && this.entries.has(entry.id);
    channel.on("snapshot", (payload: Snapshot) => { if (current()) this.apply(entry, channel, payload, false); });
    channel.on("status", (payload: unknown) => {
      if (!current()) return;
      const error = channelError(payload);
      if (this.isAuthError(error) && error.code === "UNAUTHENTICATED") {
        for (const item of this.entries.values()) this.setState(item, { ...item.state, data: undefined });
        this.transportFailed(socket);
      } else this.fail(entry, error);
    });
    channel.onError(() => { if (current()) this.transportFailed(socket); });
    channel.onClose(() => {
      if (current()) this.fail(entry, new ApiError({ code: "SUBSCRIPTION_CLOSED", message: "The server closed the subscription" }));
    });
    channel.join(this.options.timeoutMs ?? 10_000)
      .receive("ok", (payload: Snapshot) => {
        if (!current()) return;
        this.retries = 0;
        this.apply(entry, channel, payload, true);
      })
      .receive("error", (payload: unknown) => {
        if (!current()) return;
        const error = channelError(payload);
        if (error.code === "UNAUTHENTICATED") this.transportFailed(socket);
        else this.fail(entry, error);
      })
      .receive("timeout", () => { if (current()) this.transportFailed(socket); });
  }

  private apply(entry: Entry, channel: Channel, snapshot: Snapshot, initial: boolean): void {
    if (!snapshot || snapshot.protocol_version !== 1 || snapshot.subscription_id !== entry.id ||
        snapshot.project_id !== this.identity?.project_id || snapshot.subject_id !== this.identity?.subject_id ||
        typeof snapshot.generation !== "string" || !Number.isSafeInteger(snapshot.seq) || snapshot.seq < 1 || !("data" in snapshot)) {
      this.fail(entry, new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid subscription snapshot" }));
      return;
    }
    if (!initial && snapshot.generation !== entry.state.generation) return;
    if (initial || snapshot.seq > entry.state.seq) {
      this.setState(entry, { status: "ready", data: snapshot.data, generation: snapshot.generation, seq: snapshot.seq, error: undefined });
    }
    if (entry.channel === channel) channel.push("ack", { generation: snapshot.generation, seq: snapshot.seq });
  }

  private transportFailed(socket: Socket): void {
    if (this.socket !== socket || this.closed) return;
    this.detach();
    this.recovering();
    this.scheduleRetry();
  }

  private connectionFailed(error: unknown): void {
    if (this.closed) return;
    const failure = asApiError(error);
    if (!failure.retryable) this.failAll(failure);
    else {
      this.recovering();
      this.scheduleRetry();
    }
  }

  private scheduleRetry(): void {
    if (this.closed || this.retryTimer || !this.entries.size) return;
    const attempt = ++this.retries;
    const delay = this.options.retryDelayMs?.(attempt) ?? Math.min(250 * 2 ** Math.min(attempt - 1, 7), 30_000);
    this.retryTimer = setTimeout(() => {
      this.retryTimer = undefined;
      this.start(true);
    }, delay);
  }

  private recovering(): void {
    for (const entry of this.entries.values()) {
      if (entry.state.status !== "error") this.setState(entry, { ...entry.state, status: "recovering", error: undefined });
    }
  }

  private failAll(error: ApiError): void {
    this.detach();
    this.token = undefined;
    for (const entry of this.entries.values()) this.fail(entry, error);
  }

  private fail(entry: Entry, error: ApiError): void {
    const channel = entry.channel;
    entry.channel = undefined;
    channel?.leave(0);
    this.setState(entry, { ...entry.state, status: "error", data: undefined, error });
  }

  private detach(): void {
    this.epoch++;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = undefined;
    this.connecting = undefined;
    const socket = this.socket;
    this.socket = undefined;
    for (const entry of this.entries.values()) {
      const channel = entry.channel;
      entry.channel = undefined;
      channel?.leave(0);
    }
    socket?.disconnect();
  }

  private setState(entry: Entry, state: SubscriptionState<unknown>): void {
    entry.state = Object.freeze(state);
    for (const listener of entry.listeners) this.notify(entry, listener);
  }

  private start(forceRefresh: boolean): void {
    const epoch = this.epoch;
    void this.connect(forceRefresh).catch((error: unknown) => {
      if (this.epoch === epoch) this.connectionFailed(error);
    });
  }

  private notify(entry: Entry, listener: (state: SubscriptionState<unknown>) => void): void {
    try { listener(entry.state); }
    catch (error) { this.options.onListenerError?.(error); }
  }

  private http<Data>(path: string, token: string, init: RequestInit): Promise<Data> {
    return request<Data>(this.fetcher, this.endpoint + path, {
      ...init,
      headers: { ...init.headers, authorization: `Bearer ${token}`, "x-project-id": this.options.projectId },
    });
  }

  private controller(signal?: AbortSignal): ManagedController {
    const controller = new AbortController() as ManagedController;
    const abortExternal = () => controller.abort(signal?.reason);
    const timer = setTimeout(() => controller.abort(new ApiError({ code: "TIMEOUT", message: "The request timed out", retryable: true })), this.options.timeoutMs ?? 10_000);
    controller.dispose = () => { clearTimeout(timer); signal?.removeEventListener("abort", abortExternal); };
    if (signal) {
      if (signal.aborted) controller.abort(signal.reason);
      else signal.addEventListener("abort", abortExternal, { once: true });
    }
    this.controllers.add(controller);
    return controller;
  }

  private awaitToken(promise: Promise<string>, signal: AbortSignal): Promise<string> {
    return new Promise((resolve, reject) => {
      const abort = () => reject(signal.reason);
      if (signal.aborted) { reject(signal.reason); return; }
      signal.addEventListener("abort", abort, { once: true });
      void promise.then(resolve, reject).finally(() => signal.removeEventListener("abort", abort));
    });
  }

  private isAuthError(error: unknown): error is ApiError {
    return error instanceof ApiError && ["UNAUTHENTICATED", "FORBIDDEN"].includes(error.code);
  }

  private assertOpen(): void {
    if (this.closed) throw new ApiError({ code: "CLIENT_CLOSED", message: "The client is closed" });
  }
}
