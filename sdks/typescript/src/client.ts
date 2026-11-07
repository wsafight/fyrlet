import { Socket } from "phoenix";
import type { Channel } from "phoenix";
import { ApiError, asApiError, channelError } from "./errors.js";
import { endpointURL, request } from "./http.js";
import { applyDelta, immutable } from "./delta.js";
import { decodeFrames } from "./transport.js";
import type {
  CallOptions, CancelReceipt, Client, ClientOptions, FyrletContract, OptimisticUpdate, PresenceMeta, PresenceRoster,
  PresenceSubscription, RequestOptions, RunSignal, RunSummary, RunView, SignalReceipt, StartedRun, Subscription,
  SubscriptionState,
} from "./types.js";

interface Identity { project_id: string; subject_id: string }
type ManagedController = AbortController & { dispose: () => void };
interface Snapshot extends Identity {
  protocol_version: number;
  subscription_id: string;
  generation: string;
  seq: number;
  data: unknown;
  delivery?: string;
}

/** A local prediction shown on top of a subscription's server data. */
interface Overlay {
  update: (data: unknown) => unknown;
  /** The write succeeded; the overlay ends when the server next sends data, or when `timer` fires. */
  settled: boolean;
  timer: ReturnType<typeof setTimeout> | undefined;
}

interface Entry {
  id: string;
  name: string;
  params: unknown;
  state: SubscriptionState<unknown>;
  listeners: Set<(state: SubscriptionState<unknown>) => void>;
  channel: Channel | undefined;
  delta: boolean;
  /** Present for append subscriptions. */
  append?: { cursor: string | undefined; maxItems: number; desynced: boolean };
  /** Present for presence rooms: the meta to join with (the latest one set through `update`). */
  presence?: { meta: Record<string, unknown>; self: string | undefined };
  /** Retryable join errors in a row; the channel itself is rejoined by Phoenix. */
  joinFailures: number;
  overlays: Overlay[];
  /** Bumped whenever `overlays` changes, to know when `shown` is stale. */
  overlayVersion: number;
  shown?: { base: SubscriptionState<unknown>; version: number; value: SubscriptionState<unknown> };
}

interface AppendSnapshot extends Identity {
  protocol_version: number;
  subscription_id: string;
  generation: string;
  seq: number;
  cursor: string;
  mode: string;
  max_items: number;
  data: unknown;
}

interface AppendBatch { g: unknown; s: unknown; base_cursor: unknown; cursor: unknown; items: unknown }

/** The one protocol version this client speaks; a server that answers with another is refused. */
const PROTOCOL_VERSION = 1;
const MAX_APPEND_ITEMS = 1_000;
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

function checkRoster(value: unknown): Record<string, PresenceMeta[]> | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  for (const metas of Object.values(value)) {
    if (!Array.isArray(metas)) return undefined;
    for (const meta of metas) {
      if (!meta || typeof meta !== "object" || typeof meta.ref !== "string" ||
          !meta.data || typeof meta.data !== "object" || Array.isArray(meta.data)) return undefined;
    }
  }
  return value as Record<string, PresenceMeta[]>;
}

export function createClient<Contract extends FyrletContract>(options: ClientOptions): Client<Contract> {
  return new FyrletClient(options) as Client<Contract>;
}

class FyrletClient implements Client<FyrletContract> {
  private readonly endpoint: string;
  private readonly fetcher: typeof globalThis.fetch;
  private readonly createId: () => string;
  private readonly entries = new Map<string, Entry>();
  private readonly handles = new WeakMap<object, Entry>();
  private readonly controllers = new Set<ManagedController>();
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
    this.declared = normalizeCapabilities(options.capabilities);
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

  /** One authenticated HTTP request with the same refresh-once-on-401 behavior as `call`. */
  private async authorized<Data>(path: string, init: RequestInit, signal?: AbortSignal): Promise<Data> {
    this.assertOpen();
    const controller = this.controller(signal);
    try {
      const token = await this.awaitAbortable(this.authorize(false), controller.signal);
      this.assertOpen();
      try {
        return await this.http<Data>(path, token, { ...init, signal: controller.signal });
      } catch (error) {
        if (!(error instanceof ApiError) || (error.status !== 401 && error.code !== "UNAUTHENTICATED")) throw error;
        const fresh = await this.awaitAbortable(this.authorize(true), controller.signal);
        this.assertOpen();
        return await this.http<Data>(path, fresh, { ...init, signal: controller.signal });
      }
    } catch (error) {
      if (this.isAuthError(error)) this.failAll(error as ApiError);
      throw error;
    } finally {
      this.controllers.delete(controller);
      controller.dispose();
    }
  }

  async call(name: string, input: unknown, options: CallOptions = {}): Promise<unknown> {
    this.assertOpen();
    const predicted = this.predict(options.optimistic);
    try {
      const result = await this.execute(name, input, options);
      this.settle(predicted);
      return result;
    } catch (error) {
      this.rollback(predicted);
      throw error;
    }
  }

  private async execute(name: string, input: unknown, options: CallOptions): Promise<unknown> {
    const idempotencyKey = options.idempotencyKey ?? this.createId();
    const controller = this.controller(options.signal);
    const perform = async (token: string) => this.options.operationTransport === "socket"
      ? this.socketCall(name, input, idempotencyKey, controller.signal)
      : this.http<unknown>(`/api/v1/operations/${encodeURIComponent(name)}`, token, {
      method: "POST",
      headers: { "content-type": "application/json", "idempotency-key": idempotencyKey },
      body: JSON.stringify({ input }),
      signal: controller.signal,
    });

    try {
      const token = await this.awaitAbortable(this.authorize(false), controller.signal);
      this.assertOpen();
      try {
        return await perform(token);
      } catch (error) {
        if (!(error instanceof ApiError) || (error.status !== 401 && error.code !== "UNAUTHENTICATED")) throw error;
        const fresh = await this.awaitAbortable(this.authorize(true), controller.signal);
        this.assertOpen();
        if (this.options.operationTransport === "socket") { this.detach(); this.recovering(); }
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
    return this.subscribeEntry(name, params, false);
  }

  subscribeAppend(name: string, params: unknown): Subscription<unknown> {
    this.requireCapability("append");
    return this.subscribeEntry(name, params, true);
  }

  subscribePresence(name: string, params: unknown, meta: Record<string, unknown> = {}): PresenceSubscription {
    this.requireCapability("presence");
    const presence = { meta, self: undefined as string | undefined };
    const subscription = this.subscribeEntry(name, params, false, presence);
    // The entry is the one carrying this exact `presence` object.
    const entry = [...this.entries.values()].find((item) => item.presence === presence)!;
    return {
      ...(subscription as Subscription<PresenceRoster>),
      self: () => presence.self,
      update: (next) => new Promise<void>((resolve, reject) => {
        if (entry.state.status !== "ready" || !entry.channel) {
          reject(new ApiError({ code: "NOT_READY", message: "The presence room is not joined" }));
          return;
        }
        entry.channel.push("update", { meta: next }, this.options.timeoutMs ?? 10_000)
          .receive("ok", () => { presence.meta = next; resolve(); })
          .receive("error", (payload: unknown) => reject(channelError(payload)))
          .receive("timeout", () => reject(new ApiError({ code: "TIMEOUT", message: "Presence update was not acknowledged", retryable: true })));
      }),
    };
  }

  private subscribeEntry(name: string, params: unknown, append: boolean, presence?: Entry["presence"]): Subscription<unknown> {
    this.assertOpen();
    const id = this.createId();
    if (this.entries.has(id)) throw new TypeError("createId returned a duplicate subscription ID");
    const entry: Entry = {
      id, name, params, listeners: new Set(), channel: undefined, delta: false, joinFailures: 0, overlays: [], overlayVersion: 0,
      ...(append ? { append: { cursor: undefined, maxItems: 0, desynced: false } } : {}),
      ...(presence ? { presence } : {}),
      state: { status: "connecting", data: undefined, error: undefined, generation: undefined, seq: 0 },
    };
    this.entries.set(id, entry);
    if (this.socket) this.attach(entry, this.socket, this.epoch);
    else this.start(false);

    const subscription: Subscription<unknown> = {
      getState: () => this.view(entry),
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
        this.clearOverlays(entry);
        this.setState(entry, { ...entry.state, status: "closed", data: undefined, error: undefined });
        entry.listeners.clear();
        if (!this.needsSocket()) this.detach();
      },
    };
    this.handles.set(subscription, entry);
    return subscription;
  }

  async reconnect(): Promise<void> {
    this.assertOpen();
    this.detach();
    for (const entry of this.entries.values()) this.setState(entry, { ...entry.state, status: "recovering", error: undefined });
    if (this.needsSocket()) {
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
      this.clearOverlays(entry);
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

  private async socketCall(name: string, input: unknown, key: string, signal: AbortSignal): Promise<unknown> {
    const channel = await this.awaitAbortable(this.operations(), signal);
    if (signal.aborted) throw signal.reason;
    return new Promise((resolve, reject) => {
      const cleanup = () => { signal.removeEventListener("abort", abort); this.operationFailures.delete(fail); };
      const fail = (error: unknown) => { cleanup(); reject(error); };
      const abort = () => fail(signal.reason);
      this.operationFailures.add(fail);
      signal.addEventListener("abort", abort, { once: true });
      channel.push("call", { name, input, idempotency_key: key }, this.options.timeoutMs ?? 10_000)
        .receive("ok", (payload: unknown) => {
          cleanup();
          if (payload && typeof payload === "object" && "data" in payload) resolve(payload.data);
          else reject(new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid operation response" }));
        })
        .receive("error", (payload: unknown) => fail(channelError(payload)))
        .receive("timeout", () => fail(new ApiError({ code: "TIMEOUT", message: "Operation timed out", retryable: true })));
    });
  }

  private attach(entry: Entry, socket: Socket, epoch: number): void {
    const append = entry.append !== undefined;
    const presence = entry.presence;
    // A function, so that a rejoin by Phoenix (after a retryable join error) sends the current meta.
    const channel = socket.channel(
      presence ? `presence:${entry.id}` : append ? `append:${entry.id}` : `subscription:${entry.id}`,
      () => ({ ...this.joinOptions(), name: entry.name, params: entry.params,
        ...(presence ? { meta: presence.meta } : {}),
        ...(append || presence || this.options.delta === false ? {} : { delivery: "delta-v1" }) }));
    entry.channel = channel;
    const current = () => !this.closed && this.epoch === epoch && entry.channel === channel && this.entries.has(entry.id);
    if (presence) {
      channel.on("diff", (payload: unknown) => { if (current()) this.applyPresenceDiff(entry, payload); });
    } else if (append) {
      channel.on("snapshot", (payload: AppendSnapshot) => { if (current()) this.applyAppendSnapshot(entry, channel, payload, false); });
      channel.on("append", (payload: AppendBatch) => { if (current()) this.applyAppend(entry, channel, payload); });
    } else {
      channel.on("snapshot", (payload: Snapshot) => { if (current()) this.apply(entry, channel, payload, false); });
      channel.on("delta", (payload: unknown) => { if (current()) this.applyPatch(entry, channel, payload); });
    }
    channel.on("status", (payload: unknown) => {
      if (!current()) return;
      const error = channelError(payload);
      if (this.isAuthError(error) && error.code === "UNAUTHENTICATED") {
        for (const item of this.entries.values()) this.setState(item, { ...item.state, data: undefined });
        this.transportFailed(socket);
      } else if (error.retryable) this.transportFailed(socket);
      else this.fail(entry, error);
    });
    channel.onError(() => { if (current()) this.transportFailed(socket); });
    channel.onClose(() => {
      if (current()) this.fail(entry, new ApiError({ code: "SUBSCRIPTION_CLOSED", message: "The server closed the subscription" }));
    });
    channel.join(this.options.timeoutMs ?? 10_000)
      .receive("ok", (payload: Snapshot & AppendSnapshot) => {
        if (!current()) return;
        this.retries = 0;
        entry.joinFailures = 0;
        if (presence) this.applyPresenceState(entry, payload);
        else if (append) this.applyAppendSnapshot(entry, channel, payload, true);
        else this.apply(entry, channel, payload, true);
      })
      .receive("error", (payload: unknown) => {
        if (!current()) return;
        const error = channelError(payload);
        if (error.code === "UNAUTHENTICATED") this.transportFailed(socket);
        else if (error.retryable && ++entry.joinFailures <= MAX_JOIN_RETRIES) {
          // For example the observer was briefly unavailable. Phoenix rejoins this channel by itself
          // after a backoff and the callbacks above run again, so leave it open and wait.
          this.setState(entry, { ...entry.state, status: "recovering", error: undefined });
        } else this.fail(entry, error);
      })
      .receive("timeout", () => { if (current()) this.transportFailed(socket); });
  }

  // The join reply replaces the whole roster (also after a reconnect, so nothing stale survives).
  private applyPresenceState(entry: Entry, reply: unknown): void {
    const body = reply as { protocol_version?: unknown; self?: unknown; state?: unknown } | undefined;
    const roster = body && body.protocol_version === PROTOCOL_VERSION && typeof body.self === "string" ? checkRoster(body.state) : undefined;
    if (!roster || !entry.presence) {
      this.fail(entry, new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid presence state" }));
      return;
    }
    entry.presence.self = body!.self as string;
    this.setState(entry, { status: "ready", data: immutable(roster), generation: undefined, seq: entry.state.seq + 1, error: undefined });
  }

  // Applied by `ref`, so a diff that arrives twice (the server echoes a member's own join) changes nothing.
  private applyPresenceDiff(entry: Entry, payload: unknown): void {
    const diff = payload as { joins?: unknown; leaves?: unknown } | undefined;
    const joins = diff ? checkRoster(diff.joins) : undefined;
    const leaves = diff ? checkRoster(diff.leaves) : undefined;
    if (!joins || !leaves) {
      this.fail(entry, new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid presence diff" }));
      return;
    }
    const next = new Map<string, PresenceMeta[]>(
      Object.entries((entry.state.data as PresenceRoster | undefined) ?? {}).map(([key, metas]) => [key, [...metas]]));
    for (const [key, metas] of Object.entries(leaves)) {
      const gone = new Set(metas.map((meta) => meta.ref));
      const kept = (next.get(key) ?? []).filter((meta) => !gone.has(meta.ref));
      if (kept.length > 0) next.set(key, kept); else next.delete(key);
    }
    for (const [key, metas] of Object.entries(joins)) {
      const present = next.get(key) ?? [];
      const known = new Set(present.map((meta) => meta.ref));
      const added = metas.filter((meta) => !known.has(meta.ref));
      if (added.length > 0) next.set(key, [...present, ...added]);
    }
    this.setState(entry, { status: "ready", data: immutable(Object.fromEntries(next)), generation: undefined, seq: entry.state.seq + 1, error: undefined });
  }

  private apply(entry: Entry, channel: Channel, snapshot: Snapshot, initial: boolean): void {
    if (!snapshot || snapshot.protocol_version !== PROTOCOL_VERSION || snapshot.subscription_id !== entry.id ||
        snapshot.project_id !== this.identity?.project_id || snapshot.subject_id !== this.identity?.subject_id ||
        typeof snapshot.generation !== "string" || !Number.isSafeInteger(snapshot.seq) || snapshot.seq < 1 || !("data" in snapshot)) {
      this.fail(entry, new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid subscription snapshot" }));
      return;
    }
    if (!initial && snapshot.generation !== entry.state.generation) return;
    if (initial) entry.delta = snapshot.delivery === "delta-v1";
    if (initial || snapshot.seq > entry.state.seq) {
      this.setState(entry, { status: "ready", data: immutable(snapshot.data), generation: snapshot.generation, seq: snapshot.seq, error: undefined });
    }
    this.acknowledge(entry, channel, snapshot.generation, snapshot.seq);
  }

  private acknowledge(entry: Entry, channel: Channel, generation: unknown, sequence: unknown, cursor?: string): void {
    if (entry.channel !== channel || !this.socket?.isConnected()) return;
    this.socket.push({
      topic: channel.topic, event: "ack", payload: { g: generation, s: sequence, ...(cursor === undefined ? {} : { c: cursor }) },
      ref: null, join_ref: null,
    });
  }

  private applyAppendSnapshot(entry: Entry, channel: Channel, snapshot: AppendSnapshot, initial: boolean): void {
    const append = entry.append;
    if (!append || !snapshot || snapshot.protocol_version !== PROTOCOL_VERSION || snapshot.mode !== "append" ||
        snapshot.subscription_id !== entry.id || snapshot.project_id !== this.identity?.project_id ||
        snapshot.subject_id !== this.identity?.subject_id || typeof snapshot.generation !== "string" ||
        !Number.isSafeInteger(snapshot.seq) || snapshot.seq < 1 || typeof snapshot.cursor !== "string" ||
        !Number.isSafeInteger(snapshot.max_items) || snapshot.max_items < 1 || !Array.isArray(snapshot.data) ||
        snapshot.data.length > snapshot.max_items) {
      this.fail(entry, new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid append snapshot" }));
      return;
    }
    // A reset keeps the generation and raises seq; anything older is a stale duplicate.
    if (!initial && (snapshot.generation !== entry.state.generation || snapshot.seq <= entry.state.seq)) return;
    append.cursor = snapshot.cursor;
    append.maxItems = snapshot.max_items;
    append.desynced = false;
    this.setState(entry, {
      status: "ready", data: immutable(snapshot.data), generation: snapshot.generation, seq: snapshot.seq,
      cursor: snapshot.cursor, error: undefined,
    });
    this.acknowledge(entry, channel, snapshot.generation, snapshot.seq, snapshot.cursor);
  }

  // A batch is applied only if it continues exactly at the cursor held. Anything else means a
  // batch was missed or reordered: stop merging and ask for a snapshot rather than guess.
  private applyAppend(entry: Entry, channel: Channel, batch: AppendBatch): void {
    const append = entry.append;
    if (!append || !batch || typeof batch !== "object") {
      this.fail(entry, new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid append batch" }));
      return;
    }
    if (batch.g !== entry.state.generation || append.desynced) return;
    if (!Number.isSafeInteger(batch.s) || typeof batch.base_cursor !== "string" || typeof batch.cursor !== "string" ||
        !Array.isArray(batch.items) || batch.items.length > MAX_APPEND_ITEMS) {
      this.fail(entry, new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid append batch" }));
      return;
    }
    const sequence = batch.s as number;
    if (sequence <= entry.state.seq) return; // a repeat is never applied twice
    if (sequence !== entry.state.seq + 1 || batch.base_cursor !== append.cursor) {
      append.desynced = true;
      channel.push("refresh", {});
      return;
    }
    const data = [...(entry.state.data as unknown[]), ...batch.items].slice(-append.maxItems);
    append.cursor = batch.cursor;
    this.setState(entry, {
      status: "ready", data: immutable(data), generation: entry.state.generation, seq: sequence, cursor: batch.cursor, error: undefined,
    });
    this.acknowledge(entry, channel, batch.g, sequence, batch.cursor);
  }

  private applyPatch(entry: Entry, channel: Channel, payload: unknown): void {
    if (!payload || typeof payload !== "object") {
      this.fail(entry, new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid subscription delta" }));
      return;
    }
    const delta = payload as { g?: unknown; s?: unknown; b?: unknown; p?: unknown };
    if (delta.g !== entry.state.generation) return;
    if (!entry.delta || !Number.isSafeInteger(delta.s) || !Number.isSafeInteger(delta.b) ||
        (delta.s as number) < 2 || (delta.b as number) < 1 || delta.s !== (delta.b as number) + 1) {
      this.fail(entry, new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid subscription delta sequence" }));
      return;
    }
    if ((delta.s as number) <= entry.state.seq) {
      this.acknowledge(entry, channel, delta.g, delta.s);
      return;
    }
    if (delta.b !== entry.state.seq) {
      if (this.socket) this.transportFailed(this.socket);
      return;
    }
    try {
      const data = applyDelta(entry.state.data, delta.p);
      this.setState(entry, { status: "ready", data, generation: entry.state.generation, seq: delta.s as number, error: undefined });
      this.acknowledge(entry, channel, delta.g, delta.s);
    } catch {
      this.fail(entry, new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid subscription delta" }));
    }
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

  private setState(entry: Entry, state: SubscriptionState<unknown>): void {
    const previous = entry.state;
    entry.state = Object.freeze(state);
    // New data from the server replaces the predictions of writes that already succeeded.
    if (entry.overlays.length > 0 && (state.seq !== previous.seq || state.data !== previous.data)) this.dropSettled(entry);
    this.emit(entry);
  }

  private emit(entry: Entry): void {
    for (const listener of entry.listeners) this.notify(entry, listener);
  }

  // ---- optimistic predictions ----
  // `entry.state` always holds what the server sent (deltas are applied to it); what callers see
  // is derived from it by folding the predictions over its data.

  private view(entry: Entry): SubscriptionState<unknown> {
    if (entry.overlays.length === 0 || entry.state.data === undefined) return entry.state;
    if (entry.shown && entry.shown.base === entry.state && entry.shown.version === entry.overlayVersion) return entry.shown.value;
    let data: unknown = entry.state.data;
    for (const overlay of [...entry.overlays]) {
      try { data = immutable(overlay.update(data)); }
      catch (error) {
        // A prediction that cannot run is dropped, never shown half-applied.
        this.removeOverlay(entry, overlay, false);
        this.options.onListenerError?.(error);
      }
    }
    const value = entry.overlays.length === 0 ? entry.state
      : Object.freeze({ ...entry.state, data, pending: entry.overlays.length });
    entry.shown = { base: entry.state, version: entry.overlayVersion, value };
    return value;
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
      if (entry.state.data === undefined) continue; // nothing to predict on yet
      const overlay: Overlay = { update, settled: false, timer: undefined };
      entry.overlays.push(overlay);
      entry.overlayVersion++;
      applied.push({ entry, overlay });
      this.emit(entry);
    }
    return applied;
  }

  private settle(applied: Array<{ entry: Entry; overlay: Overlay }>): void {
    const ttl = this.options.optimisticTtlMs ?? 5_000;
    for (const { entry, overlay } of applied) {
      if (!entry.overlays.includes(overlay)) continue;
      overlay.settled = true;
      overlay.timer = setTimeout(() => this.removeOverlay(entry, overlay, true), ttl);
      (overlay.timer as { unref?: () => void }).unref?.();
    }
  }

  private rollback(applied: Array<{ entry: Entry; overlay: Overlay }>): void {
    for (const { entry, overlay } of applied) this.removeOverlay(entry, overlay, true);
  }

  private removeOverlay(entry: Entry, overlay: Overlay, notify: boolean): void {
    const index = entry.overlays.indexOf(overlay);
    if (index < 0) return;
    entry.overlays.splice(index, 1);
    entry.overlayVersion++;
    if (overlay.timer) clearTimeout(overlay.timer);
    if (notify && this.entries.has(entry.id)) this.emit(entry);
  }

  private dropSettled(entry: Entry): void {
    for (const overlay of [...entry.overlays]) if (overlay.settled) this.removeOverlay(entry, overlay, false);
  }

  private clearOverlays(entry: Entry): void {
    for (const overlay of entry.overlays) if (overlay.timer) clearTimeout(overlay.timer);
    entry.overlays = [];
    entry.overlayVersion++;
  }

  private start(forceRefresh: boolean): void {
    const epoch = this.epoch;
    void this.connect(forceRefresh).catch((error: unknown) => {
      if (this.epoch === epoch) this.connectionFailed(error);
    });
  }

  private notify(entry: Entry, listener: (state: SubscriptionState<unknown>) => void): void {
    try { listener(this.view(entry)); }
    catch (error) { this.options.onListenerError?.(error); }
  }

  private http<Data>(path: string, token: string, init: RequestInit): Promise<Data> {
    return request<Data>(this.fetcher, this.endpoint + path, {
      ...init,
      headers: {
        ...init.headers, authorization: `Bearer ${token}`, "x-project-id": this.options.projectId,
        ...(Object.keys(this.declared).length > 0 ? { "x-fyrlet-capabilities": capabilityHeader(this.declared) } : {}),
      },
    });
  }

  private joinOptions(): { protocol_version: typeof PROTOCOL_VERSION; capabilities?: Record<string, number> } {
    return Object.keys(this.declared).length > 0
      ? { protocol_version: PROTOCOL_VERSION, capabilities: this.declared }
      : { protocol_version: PROTOCOL_VERSION };
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

  private awaitAbortable<Value>(promise: Promise<Value>, signal: AbortSignal): Promise<Value> {
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
