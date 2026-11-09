import { Socket } from "phoenix";
import type { Channel } from "phoenix";
import { ApiError, asApiError, channelError, OutcomeUnknownError } from "./errors.js";
import { MutationTask, operationReceipt, recoveryResult } from "./mutation.js";
import type { OperationReceipt } from "./mutation.js";
import { endpointURL, request } from "./http.js";
import { decodeFrames } from "./transport.js";
import { PROTOCOL_VERSION } from "./protocol.js";
import type { Identity } from "./protocol.js";
import { awaitAbortable, RequestExecutor } from "./requests.js";
import { queryKey, queryValue } from "./query.js";
import { retryOperation, retryPolicy } from "./retry.js";
import { SubscriptionEntry as Entry } from "./subscription.js";
import type { Overlay, SubscriptionEvent } from "./subscription.js";
import type {
  CallOptions, CancelReceipt, Client, ClientOptions, FyrletContract, PresenceRoster,
  PresenceSubscription, RequestOptions, RunSignal, RunSummary, RunView, SignalReceipt, StartedRun, Subscription,
  Mutation, RecoveryOptions, RecoveryResult, ViewConfirmation, SubscriptionState,
} from "./types.js";

/** Consecutive retryable join failures of one subscription before it is reported as failed. */
const MAX_JOIN_RETRIES = 10;

function normalizeCapabilities(value: ClientOptions["capabilities"]): Record<string, number> {
  if (value === undefined) return {};
  const entries = Array.isArray(value) ? value.map((name): [string, number] => [name, 1]) : Object.entries(value);
  const result: Record<string, number> = {};
  for (const [name, version] of entries) {
    if (typeof name !== "string" || !/^[a-z][a-z0-9_.-]*$/.test(name) || !Number.isSafeInteger(version) || version < 1) {
      throw new TypeError("capabilities must be names (or name -> positive integer version)");
    }
    result[name] = version;
  }
  return result;
}

function capabilityHeader(capabilities: Record<string, number>): string {
  return Object.entries(capabilities).map(([name, version]) => `${name}=${version}`).join(", ");
}

export function createClient<Contract extends FyrletContract>(options: ClientOptions): Client<Contract> {
  return new FyrletClient(options) as unknown as Client<Contract>;
}

class FyrletClient implements Client<FyrletContract> {
  private readonly endpoint: string;
  private readonly fetcher: typeof globalThis.fetch;
  private readonly createId: () => string;
  private readonly entries = new Map<string, Entry>();
  private readonly handles = new WeakMap<object, Entry>();
  private readonly handleConfirmations = new WeakMap<object, Set<AbortController>>();
  private readonly sharedQueries = new Map<string, Entry>();
  private readonly queryKeys = new Map<Entry, string>();
  private readonly references = new Map<Entry, number>();
  private readonly requests: RequestExecutor;
  private readonly retryControllers = new Set<AbortController>();
  private socket: Socket | undefined;
  private operationChannel: Channel | undefined;
  private operationJoin: Promise<Channel> | undefined;
  private readonly operationFailures = new Set<(error: ApiError) => void>();
  private identity: Identity | undefined;
  private token: string | undefined;
  private tokenFlight: Promise<string> | undefined;
  private tokenFlightForced = false;
  private connecting: Promise<void> | undefined;
  private retryTimer: ReturnType<typeof setTimeout> | undefined;
  private epoch = 0;
  private retries = 0;
  private closed = false;
  private readonly declared: Record<string, number>;

  constructor(private readonly options: ClientOptions) {
    this.endpoint = endpointURL(options.endpoint);
    this.fetcher = options.fetch ?? globalThis.fetch;
    this.createId = options.createId ?? (() => {
      if (!globalThis.crypto?.randomUUID) throw new TypeError("Provide createId on runtimes without crypto.randomUUID");
      return globalThis.crypto.randomUUID();
    });
    if (!options.projectId) throw new TypeError("projectId is required");
    if (options.maxSharedSubscriptions !== undefined && (!Number.isSafeInteger(options.maxSharedSubscriptions) || options.maxSharedSubscriptions < 1)) {
      throw new TypeError("maxSharedSubscriptions must be a positive integer");
    }
    this.declared = normalizeCapabilities(options.capabilities);
    this.requests = new RequestExecutor(options.timeoutMs ?? 10_000, {
      authorize: (forceRefresh) => this.authorize(forceRefresh),
      assertOpen: () => this.assertOpen(),
      fail: (error) => this.failAll(error),
    });
  }

  // ---- runs (capability "runs") ----

  async startRun(name: string, input: unknown, options: CallOptions = {}): Promise<StartedRun> {
    this.requireCapability("runs");
    // `call` generates the mandatory idempotency key when the caller gives none.
    return await this.call(name, input, options) as StartedRun;
  }

  async getRun(runId: string, options: RequestOptions = {}): Promise<RunView> {
    this.requireCapability("runs");
    return this.authorized<RunView>(`/api/v1/runs/${encodeURIComponent(runId)}`, { method: "GET" }, options.signal);
  }

  async signalRun(runId: string, signal: RunSignal, options: RequestOptions = {}): Promise<SignalReceipt> {
    this.requireCapability("runs");
    const body = { ...signal, idempotency_key: signal.idempotency_key ?? this.createId() };
    return this.authorized<SignalReceipt>(`/api/v1/runs/${encodeURIComponent(runId)}/signals`, {
      method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
    }, options.signal);
  }

  async cancelRun(runId: string, options: RequestOptions = {}): Promise<CancelReceipt> {
    this.requireCapability("runs");
    return this.authorized<CancelReceipt>(`/api/v1/runs/${encodeURIComponent(runId)}/cancel`, {
      method: "POST", headers: { "content-type": "application/json" }, body: "{}",
    }, options.signal);
  }

  subscribeRun(runId: string): Subscription<RunView> {
    this.requireCapability("runs");
    return this.subscribe("fyrlet.run", { run_id: runId }) as Subscription<RunView>;
  }

  subscribeRecentRuns(limit?: number): Subscription<RunSummary[]> {
    this.requireCapability("runs");
    return this.subscribe("fyrlet.runs.recent", limit === undefined ? {} : { limit }) as Subscription<RunSummary[]>;
  }

  private requireCapability(name: string): void {
    this.assertOpen();
    if (!(name in this.declared)) {
      throw new ApiError({
        code: "UNSUPPORTED_CAPABILITY",
        message: `Declare the "${name}" capability in createClient({ capabilities }) to use this API`,
      });
    }
  }

  private authorized<Data>(path: string, init: RequestInit, signal?: AbortSignal): Promise<Data> {
    return this.requests.execute(signal, (token, requestSignal) => this.http<Data>(path, token, { ...init, signal: requestSignal }));
  }

  async call(name: string, input: unknown, options: CallOptions = {}): Promise<unknown> {
    return this.mutate(name, input, options).result;
  }

  mutate(name: string, input: unknown, options: CallOptions = {}): Mutation<unknown> {
    this.assertOpen();
    const policy = options.retry ? retryPolicy(options.retry) : undefined;
    const kind = this.options.operationMetadata?.[name]?.kind;
    if (policy && (!kind || !["read", "write", "run"].includes(kind))) throw new TypeError("Automatic retry requires explicit read, write or run operation metadata");
    const body = JSON.stringify({ input });
    const key = options.idempotencyKey ?? this.createId();
    const targets = [...new Set([...(options.confirm ?? []), ...(options.optimistic ?? []).map((item) => item.subscription)])].map((subscription) => {
      const entry = this.handles.get(subscription);
      if (!entry || !this.entries.has(entry.id)) throw new TypeError("confirm requires an open subscription created by this client");
      return { subscription, entry };
    });
    const predicted = this.predict(options.optimistic);
    return new MutationTask(key, async (report) => {
      try {
        let receipt: OperationReceipt<unknown>;
        if (policy && kind) {
          const controller = this.requests.controller(options.signal, policy.maxElapsedMs);
          this.retryControllers.add(controller);
          try {
            receipt = await retryOperation(kind, policy, controller.signal,
              () => this.execute(name, input, body, key, controller.signal),
              () => this.lookup(name, input, body, key, controller.signal), report);
          } finally {
            this.retryControllers.delete(controller);
            this.requests.release(controller);
          }
        } else receipt = await this.execute(name, input, body, key, options.signal);
        for (const { entry, overlay } of predicted) entry.settle(overlay);
        return receipt;
      } catch (error) {
        for (const { entry, overlay } of predicted) {
          if (error instanceof OutcomeUnknownError) entry.settle(overlay);
          else entry.removeOverlay(overlay, true);
        }
        throw error;
      }
    }, (recoveryOptions) => this.lookup(name, input, body, key, recoveryOptions.signal), this.options.onListenerError,
    async (error) => Promise.all(targets.filter(({ entry }) => !entry.presence).map(async ({ subscription, entry }): Promise<ViewConfirmation> => {
      if (error !== undefined) return { subscription, status: "unconfirmed", error };
      try {
        await this.confirmHandle(subscription, entry, predicted.filter((item) => item.entry === entry).map((item) => item.overlay), options.signal);
        return { subscription, status: "confirmed" };
      } catch (error) { return { subscription, status: "unconfirmed", error }; }
    })));
  }

  async recover(name: string, input: unknown, options: RecoveryOptions): Promise<RecoveryResult<unknown>> {
    return this.lookup(name, input, JSON.stringify({ input }), options.idempotencyKey, options.signal);
  }

  private async execute(name: string, input: unknown, body: string, key: string, external?: AbortSignal): Promise<OperationReceipt<unknown>> {
    let sent = false;
    try {
      const payload = await this.operation(name, input, body, key, "call", external, () => { sent = true; }, () => { sent = false; });
      return operationReceipt(payload);
    } catch (error) {
      if (sent) throw new OutcomeUnknownError(name, key, error);
      throw error;
    }
  }

  private async lookup(name: string, input: unknown, body: string, key: string, signal?: AbortSignal): Promise<RecoveryResult<unknown>> {
    const payload = await this.operation(name, input, body, key, "recover", signal);
    return recoveryResult(payload);
  }

  private operation(
    name: string, input: unknown, body: string, key: string, event: "call" | "recover", external?: AbortSignal,
    onSend: () => void = () => {}, onReject: () => void = () => {},
  ): Promise<unknown> {
    return this.requests.execute(external, async (token, signal) => {
      signal.throwIfAborted();
      try {
        if (this.options.operationTransport === "socket") return await this.socketCall(name, input, key, signal, event, onSend);
        onSend();
        return await this.http<unknown>(`/api/v1/operations/${encodeURIComponent(name)}${event === "recover" ? "/recover" : ""}`, token, {
          method: "POST", headers: { "content-type": "application/json", "idempotency-key": key }, body, signal,
        }, (payload) => payload);
      } catch (error) {
        if (error instanceof ApiError && error.status >= 400 && error.status < 500 &&
            !["PROTOCOL_ERROR", "HTTP_ERROR"].includes(error.code)) onReject();
        throw error;
      }
    }, () => {
        if (this.options.operationTransport === "socket") { this.detach(); this.recovering(); }
      });
  }

  subscribe(name: string, params: unknown): Subscription<unknown> {
    return this.subscribeEntry(name, params, false);
  }

  subscribeAppend(name: string, params: unknown): Subscription<unknown> {
    this.requireCapability("append");
    return this.subscribeEntry(name, params, true);
  }

  subscribePresence(name: string, params: unknown, meta: Record<string, unknown> = {}): PresenceSubscription<any> {
    this.requireCapability("presence");
    const presence = { meta, self: undefined as string | undefined };
    const subscription = this.subscribeEntry(name, params, false, presence);
    const entry = this.handles.get(subscription)!;
    return Object.assign(subscription as Subscription<PresenceRoster>, {
      self: () => presence.self,
      update: (next: Record<string, unknown>) => this.push(entry, "update", { meta: next }, () => { presence.meta = next; }),
    });
  }

  private subscribeEntry(name: string, params: unknown, append: boolean, presence?: Entry["presence"]): Subscription<unknown> {
    this.assertOpen();
    let key: string | undefined;
    let parameterKey: string | undefined;
    if (this.options.shareSubscriptions && !presence) {
      parameterKey = queryKey(params);
      key = JSON.stringify([this.options.projectId, name, append, parameterKey]);
    }
    let entry = key === undefined ? undefined : this.sharedQueries.get(key);
    if (!entry) {
      if (key !== undefined && this.sharedQueries.size >= (this.options.maxSharedSubscriptions ?? 100)) {
        throw new ApiError({ code: "LIMIT_EXCEEDED", message: "Too many shared queries" });
      }
      const id = this.createId();
      if (this.entries.has(id)) throw new TypeError("createId returned a duplicate subscription ID");
      if (parameterKey !== undefined) params = queryValue(parameterKey);
      entry = new Entry(id, name, params, this.options, append, presence);
      this.entries.set(id, entry);
      if (key !== undefined) {
        this.sharedQueries.set(key, entry);
        this.queryKeys.set(entry, key);
      }
      if (this.socket) this.attach(entry, this.socket, this.epoch);
      else this.start(false);
    }
    return this.subscriptionHandle(entry);
  }

  private subscriptionHandle(entry: Entry): Subscription<unknown> {
    this.references.set(entry, (this.references.get(entry) ?? 0) + 1);
    let closed: SubscriptionState<unknown> | undefined;
    const listeners = new Set<(state: SubscriptionState<unknown>) => void>();
    const subscription: Subscription<unknown> = {
      getState: () => closed ?? entry.view(),
      onChange: (listener) => {
        const wrapped = (state: SubscriptionState<unknown>) => listener(closed ?? state);
        if (!closed && entry.state.status !== "closed") {
          listeners.add(wrapped);
          entry.listeners.add(wrapped);
        }
        entry.notify(wrapped);
        return () => { entry.listeners.delete(wrapped); listeners.delete(wrapped); };
      },
      refresh: () => closed ? Promise.reject(new ApiError({ code: "SUBSCRIPTION_CLOSED", message: "The subscription is closed" })) : this.push(entry, "refresh", {}),
      confirm: (options = {}) => this.confirmHandle(subscription, entry, [], options.signal),
      unsubscribe: () => {
        if (closed) return;
        closed = Object.freeze({ ...entry.state, status: "closed", data: undefined, error: undefined });
        this.handles.delete(subscription);
        for (const controller of this.handleConfirmations.get(subscription) ?? []) {
          controller.abort(new ApiError({ code: "SUBSCRIPTION_CLOSED", message: "The subscription is closed" }));
        }
        this.handleConfirmations.delete(subscription);
        for (const listener of listeners) {
          entry.listeners.delete(listener);
          entry.notify(listener);
        }
        listeners.clear();
        const remaining = (this.references.get(entry) ?? 1) - 1;
        if (remaining > 0) { this.references.set(entry, remaining); return; }
        this.references.delete(entry);
        this.removeShared(entry);
        if (!this.entries.delete(entry.id)) return;
        const channel = entry.channel;
        entry.channel = undefined;
        channel?.leave(0);
        entry.clearOverlays();
        entry.setState({ ...entry.state, status: "closed", data: undefined, error: undefined });
        entry.listeners.clear();
        if (!this.needsSocket()) this.detach();
      },
    };
    this.handles.set(subscription, entry);
    return subscription;
  }

  private removeShared(entry: Entry): void {
    const key = this.queryKeys.get(entry);
    if (key !== undefined) this.sharedQueries.delete(key);
    this.queryKeys.delete(entry);
  }

  private push(entry: Entry, event: "refresh" | "update", payload: object, onSuccess?: () => void): Promise<void> {
    return new Promise((resolve, reject) => {
      if (entry.state.status !== "ready" || !entry.channel) {
        reject(new ApiError({ code: "NOT_READY", message: "The subscription is not ready" }));
        return;
      }
      entry.channel.push(event, payload, this.options.timeoutMs ?? 10_000)
        .receive("ok", () => { onSuccess?.(); resolve(); })
        .receive("error", (reply: unknown) => reject(channelError(reply)))
        .receive("timeout", () => reject(new ApiError({ code: "TIMEOUT", message: `${event} was not acknowledged`, retryable: true })));
    });
  }

  private async confirmHandle(subscription: Subscription<unknown>, entry: Entry, overlays: readonly Overlay[], signal?: AbortSignal): Promise<void> {
    this.assertOpen();
    if (this.handles.get(subscription) !== entry || !this.entries.has(entry.id)) {
      throw new ApiError({ code: "SUBSCRIPTION_CLOSED", message: "The subscription is closed" });
    }
    const controller = new AbortController();
    const controllers = this.handleConfirmations.get(subscription) ?? new Set<AbortController>();
    controllers.add(controller);
    this.handleConfirmations.set(subscription, controllers);
    try {
      const identifier = this.createId();
      if (entry.hasConfirmation(identifier)) {
        throw new ApiError({ code: "LIMIT_EXCEEDED", message: "Duplicate confirmation ID" });
      }
      const pending = entry.confirm(identifier, overlays, signal ? AbortSignal.any([signal, controller.signal]) : controller.signal);
      if (entry.hasConfirmation(identifier)) {
        void this.push(entry, "refresh", { confirmation_id: identifier }).catch((error: unknown) => entry.rejectConfirmation(identifier, error));
      }
      await pending;
    } finally {
      controllers.delete(controller);
      if (controllers.size === 0) this.handleConfirmations.delete(subscription);
    }
  }

  async reconnect(): Promise<void> {
    this.assertOpen();
    this.detach();
    for (const entry of this.entries.values()) entry.setState({ ...entry.state, status: "recovering", error: undefined });
    if (this.needsSocket()) {
      try { await this.connect(true); }
      catch (error) { this.connectionFailed(error); throw error; }
    }
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.detach();
    this.requests.close();
    for (const entry of this.entries.values()) {
      entry.clearOverlays();
      entry.setState({ ...entry.state, status: "closed", data: undefined, error: undefined });
      entry.listeners.clear();
    }
    this.entries.clear();
    this.sharedQueries.clear();
    this.queryKeys.clear();
    this.references.clear();
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
      const controller = this.requests.controller();
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
        this.requests.release(controller);
      }
    })();
    this.tokenFlight = flight;
    this.tokenFlightForced = forceRefresh;
    void flight.finally(() => { if (this.tokenFlight === flight) this.tokenFlight = undefined; }).catch(() => {});
    return flight;
  }

  private connect(forceRefresh: boolean): Promise<void> {
    if (this.connecting) return this.connecting;
    if (this.socket || this.closed || !this.needsSocket()) return Promise.resolve();
    const epoch = this.epoch;
    const flight = (async () => {
      const token = await this.authorize(forceRefresh);
      if (this.closed || this.epoch !== epoch || !this.needsSocket()) return;
      const socketOptions = {
        decode: (raw: string, callback: Parameters<typeof decodeFrames>[1]) => {
          try { decodeFrames(raw, callback); }
          catch {
            if (this.epoch === epoch) this.connectionFailed(new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid transport frame" }));
          }
        },
        params: { project_id: this.options.projectId },
        ...(this.options.retryDelayMs ? { rejoinAfterMs: (tries: number) => this.options.retryDelayMs!(tries) } : {}),
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

  private needsSocket(): boolean { return this.entries.size > 0 || this.options.operationTransport === "socket"; }

  private async operations(): Promise<Channel> {
    await this.connect(false);
    this.assertOpen();
    if (this.operationJoin) return this.operationJoin;
    const socket = this.socket;
    if (!socket) throw new ApiError({ code: "NETWORK_ERROR", message: "The socket is unavailable", retryable: true });
    const channel = socket.channel("operations", this.joinOptions());
    this.operationChannel = channel;
    const flight = new Promise<Channel>((resolve, reject) => {
      const fail = (error: ApiError) => { this.operationFailures.delete(fail); reject(error); };
      this.operationFailures.add(fail);
      channel.onError(() => { if (this.operationChannel === channel) this.transportFailed(socket); });
      channel.onClose(() => { if (this.operationChannel === channel) this.transportFailed(socket); });
      channel.join(this.options.timeoutMs ?? 10_000)
        .receive("ok", (payload: { protocol_version?: unknown }) => {
          if (this.operationChannel !== channel) return;
          this.operationFailures.delete(fail);
          if (payload?.protocol_version === PROTOCOL_VERSION) resolve(channel);
          else reject(new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid operation channel" }));
        })
        .receive("error", (payload: unknown) => fail(channelError(payload)))
        .receive("timeout", () => fail(new ApiError({ code: "TIMEOUT", message: "Operation channel join timed out", retryable: true })));
    });
    this.operationJoin = flight;
    void flight.catch(() => {
      if (this.operationJoin === flight) { this.operationJoin = undefined; this.operationChannel = undefined; channel.leave(0); }
    });
    return flight;
  }

  private async socketCall(
    name: string, input: unknown, key: string, signal: AbortSignal, event: "call" | "recover", onSend: () => void,
  ): Promise<unknown> {
    const channel = await awaitAbortable(this.operations(), signal);
    if (signal.aborted) throw signal.reason;
    if (channel !== this.operationChannel || channel.state !== "joined" || !this.socket?.isConnected()) {
      throw new ApiError({ code: "NETWORK_ERROR", message: "The socket is unavailable", retryable: true });
    }
    return new Promise((resolve, reject) => {
      const cleanup = () => { signal.removeEventListener("abort", abort); this.operationFailures.delete(fail); };
      const fail = (error: unknown) => { cleanup(); reject(error); };
      const abort = () => fail(signal.reason);
      this.operationFailures.add(fail);
      signal.addEventListener("abort", abort, { once: true });
      onSend();
      channel.push(event, { name, input, idempotency_key: key }, this.options.timeoutMs ?? 10_000)
        .receive("ok", (payload: unknown) => {
          cleanup();
          resolve(payload);
        })
        .receive("error", (payload: unknown) => fail(channelError(payload)))
        .receive("timeout", () => fail(new ApiError({ code: "TIMEOUT", message: "Operation timed out", retryable: true })));
    });
  }

  private attach(entry: Entry, socket: Socket, epoch: number): void {
    const append = entry.appendMode;
    const presence = entry.presence;
    // A function, so that a rejoin by Phoenix (after a retryable join error) sends the current meta.
    const channel = socket.channel(
      presence ? `presence:${entry.id}` : append ? `append:${entry.id}` : `subscription:${entry.id}`,
      () => ({ ...this.joinOptions(!presence), name: entry.name, params: entry.params,
        ...(presence ? { meta: presence.meta } : {}),
        ...(append || presence || this.options.delta === false ? {} : { delivery: "delta-v1" }) }));
    entry.channel = channel;
    const current = () => !this.closed && this.epoch === epoch && entry.channel === channel && this.entries.has(entry.id);
    if (presence) {
      channel.on("diff", (payload: unknown) => { if (current()) this.receive(entry, channel, "presence_diff", payload); });
    } else if (append) {
      channel.on("snapshot", (payload: unknown) => { if (current()) this.receive(entry, channel, "snapshot", payload); });
      channel.on("append", (payload: unknown) => { if (current()) this.receive(entry, channel, "append", payload); });
    } else {
      channel.on("snapshot", (payload: unknown) => { if (current()) this.receive(entry, channel, "snapshot", payload); });
      channel.on("delta", (payload: unknown) => { if (current()) this.receive(entry, channel, "delta", payload); });
    }
    channel.on("status", (payload: unknown) => {
      if (!current()) return;
      const error = channelError(payload);
      if (this.isAuthError(error) && error.code === "UNAUTHENTICATED") {
        for (const item of this.entries.values()) item.setState({ ...item.state, data: undefined });
        this.transportFailed(socket);
      } else if (error.retryable) this.transportFailed(socket);
      else this.fail(entry, error);
    });
    channel.onError(() => { if (current()) this.transportFailed(socket); });
    channel.onClose(() => {
      if (current()) this.fail(entry, new ApiError({ code: "SUBSCRIPTION_CLOSED", message: "The server closed the subscription" }));
    });
    channel.join(this.options.timeoutMs ?? 10_000)
      .receive("ok", (payload: unknown) => {
        if (!current()) return;
        this.retries = 0;
        entry.joinFailures = 0;
        this.receive(entry, channel, presence ? "presence_state" : "snapshot", payload, true);
      })
      .receive("error", (payload: unknown) => {
        if (!current()) return;
        const error = channelError(payload);
        if (error.code === "UNAUTHENTICATED") this.transportFailed(socket);
        else if (error.retryable && ++entry.joinFailures <= MAX_JOIN_RETRIES) {
          // For example the observer was briefly unavailable. Phoenix rejoins this channel by itself
          // after a backoff and the callbacks above run again, so leave it open and wait.
          entry.setState({ ...entry.state, status: "recovering", error: undefined });
        } else this.fail(entry, error);
      })
      .receive("timeout", () => { if (current()) this.transportFailed(socket); });
  }

  private receive(entry: Entry, channel: Channel, event: SubscriptionEvent, payload: unknown, initial = false): void {
    try {
      const delivery = entry.receive(event, payload, this.identity, initial);
      if (delivery === "refresh") channel.push("refresh", {});
      else if (delivery === "reconnect") { if (this.socket) this.transportFailed(this.socket); }
      else if (delivery) this.acknowledge(entry, channel, delivery.generation, delivery.sequence, delivery.cursor);
    } catch (error) {
      if (error instanceof ApiError) this.fail(entry, error);
      else throw error;
    }
  }

  private acknowledge(entry: Entry, channel: Channel, generation: unknown, sequence: unknown, cursor?: string): void {
    if (entry.channel !== channel || !this.socket?.isConnected()) return;
    this.socket.push({
      topic: channel.topic, event: "ack", payload: { g: generation, s: sequence, ...(cursor === undefined ? {} : { c: cursor }) },
      ref: null, join_ref: null,
    });
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
    if (this.closed || this.retryTimer || !this.needsSocket()) return;
    const attempt = ++this.retries;
    const delay = this.options.retryDelayMs?.(attempt) ?? Math.min(250 * 2 ** Math.min(attempt - 1, 7), 30_000);
    this.retryTimer = setTimeout(() => {
      this.retryTimer = undefined;
      this.start(true);
    }, delay);
  }

  private recovering(): void {
    for (const entry of this.entries.values()) {
      if (entry.state.status !== "error") entry.setState({ ...entry.state, status: "recovering", error: undefined });
    }
  }

  private failAll(error: ApiError): void {
    for (const controller of this.retryControllers) controller.abort(error);
    this.detach();
    this.token = undefined;
    for (const entry of this.entries.values()) this.fail(entry, error);
  }

  private fail(entry: Entry, error: ApiError): void {
    this.removeShared(entry);
    const channel = entry.channel;
    entry.channel = undefined;
    channel?.leave(0);
    entry.setState({ ...entry.state, status: "error", data: undefined, error });
  }

  private detach(): void {
    this.epoch++;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = undefined;
    this.connecting = undefined;
    const socket = this.socket;
    this.socket = undefined;
    const operations = this.operationChannel;
    this.operationChannel = undefined;
    this.operationJoin = undefined;
    const failure = new ApiError({ code: this.closed ? "CLIENT_CLOSED" : "NETWORK_ERROR",
      message: this.closed ? "The client is closed" : "The connection was interrupted", retryable: !this.closed });
    for (const fail of [...this.operationFailures]) fail(failure);
    operations?.leave(0);
    for (const entry of this.entries.values()) {
      const channel = entry.channel;
      entry.channel = undefined;
      channel?.leave(0);
    }
    socket?.disconnect();
  }

  private predict(updates: CallOptions["optimistic"]): Array<{ entry: Entry; overlay: Overlay }> {
    if (!updates || updates.length === 0) return [];
    const targets = updates.map((item) => {
      const entry = item && typeof item.update === "function" ? this.handles.get(item.subscription) : undefined;
      if (!entry || !this.entries.has(entry.id)) {
        throw new TypeError("optimistic.subscription must be an open subscription created by this client");
      }
      return { entry, update: item.update as (data: unknown) => unknown };
    });
    const applied: Array<{ entry: Entry; overlay: Overlay }> = [];
    for (const { entry, update } of targets) {
      const overlay = entry.predict(update);
      if (overlay) applied.push({ entry, overlay });
    }
    return applied;
  }

  private start(forceRefresh: boolean): void {
    const epoch = this.epoch;
    void this.connect(forceRefresh).catch((error: unknown) => {
      if (this.epoch === epoch) this.connectionFailed(error);
    });
  }

  private http<Data>(path: string, token: string, init: RequestInit, decode?: (body: Record<string, unknown>) => Data): Promise<Data> {
    return request<Data>(this.fetcher, this.endpoint + path, {
      ...init,
      headers: {
        ...init.headers, authorization: `Bearer ${token}`, "x-project-id": this.options.projectId,
        ...(Object.keys(this.declared).length > 0 ? { "x-fyrlet-capabilities": capabilityHeader(this.declared) } : {}),
      },
    }, decode);
  }

  private joinOptions(confirm = false): { protocol_version: typeof PROTOCOL_VERSION; capabilities?: Record<string, number> } {
    const capabilities = confirm ? { ...this.declared, view_confirmation: 1 } : this.declared;
    return Object.keys(capabilities).length > 0
      ? { protocol_version: PROTOCOL_VERSION, capabilities }
      : { protocol_version: PROTOCOL_VERSION };
  }

  private isAuthError(error: unknown): error is ApiError {
    return error instanceof ApiError && ["UNAUTHENTICATED", "FORBIDDEN"].includes(error.code);
  }

  private assertOpen(): void {
    if (this.closed) throw new ApiError({ code: "CLIENT_CLOSED", message: "The client is closed" });
  }
}
