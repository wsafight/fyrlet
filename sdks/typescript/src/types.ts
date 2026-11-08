export interface FyrletContract {
  operations: Record<string, { input: unknown; output: unknown }>;
  subscriptions: Record<string, { input: unknown; output: unknown }>;
}

export interface ErrorDetails {
  code: string;
  message: string;
  details: Record<string, unknown>;
  retryable: boolean;
}

export type SubscriptionStatus = "connecting" | "recovering" | "ready" | "error" | "closed";

export interface SubscriptionState<Data> {
  readonly status: SubscriptionStatus;
  readonly data: Data | undefined;
  readonly error: import("./errors.js").ApiError | undefined;
  readonly generation: string | undefined;
  readonly seq: number;
  /** Append subscriptions only: the opaque stream position the data ends at. Compare it, never parse it. */
  readonly cursor?: string;
  /** How many local predictions (see `CallOptions.optimistic`) are currently applied on top of the server's data. */
  readonly pending?: number;
}

export interface Subscription<Data> {
  getState(): SubscriptionState<Data>;
  onChange(listener: (state: SubscriptionState<Data>) => void): () => void;
  refresh(): Promise<void>;
  confirm(options?: RequestOptions): Promise<void>;
  unsubscribe(): void;
}

/** One device's entry for a member of a presence room. `ref` is unique to the entry. */
export interface PresenceMeta {
  readonly ref: string;
  /** What the member published (validated against the room's `meta` schema). */
  readonly data: Readonly<Record<string, unknown>>;
  readonly joined_at: string | null;
}

/** Members of a presence room by `subject_id`; a person on two devices has two entries. */
export type PresenceRoster = Readonly<Record<string, readonly PresenceMeta[]>>;

export interface PresenceSubscription extends Subscription<PresenceRoster> {
  /**
   * Replaces this client's own `meta` in the room (for example `{ typing: true }`). It is kept
   * and sent again if the connection has to be re-established. Rejects with `LIMIT_EXCEEDED`
   * (retryable) when called too often and `VALIDATION_FAILED` when the room's schema refuses it.
   */
  update(meta: Record<string, unknown>): Promise<void>;
  /** The caller's own `subject_id`, known once the room has been joined. */
  self(): string | undefined;
}

export interface ClientOptions {
  endpoint: string;
  projectId: string;
  getToken(context: { forceRefresh: boolean }): string | Promise<string>;
  fetch?: typeof globalThis.fetch;
  WebSocket?: typeof globalThis.WebSocket;
  createId?: () => string;
  timeoutMs?: number;
  retryDelayMs?: (attempt: number) => number;
  onListenerError?: (error: unknown) => void;
  delta?: boolean;
  /** Display TTL for successful or unknown predictions; expiry never confirms a view or operation. Default 5000. */
  optimisticTtlMs?: number;
  operationTransport?: "http" | "socket";
  shareSubscriptions?: boolean;
  maxSharedSubscriptions?: number;
  /**
   * Optional server capabilities this client understands, e.g. `["runs"]` or `{ runs: 1 }`.
   * Run, append and Presence require declaration and server support; otherwise their APIs throw
   * UNSUPPORTED_CAPABILITY. Snapshot and append channels automatically request view_confirmation.
   */
  capabilities?: string[] | Record<string, number>;
}

/**
 * A local prediction of what a write does to one subscription's data, shown immediately and
 * replaced by the server's data. `update` must be idempotent, as in "set the record with this id"
 * rather than "append this record": the server's own copy of the change may already be in
 * `current` when it runs. It must return a new value; the data it receives is frozen.
 */
// `any`: one call may predict several subscriptions whose data types differ.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export interface OptimisticUpdate<Data = any> {
  subscription: Subscription<Data>;
  update(current: Data): Data;
}

export interface CallOptions {
  idempotencyKey?: string;
  signal?: AbortSignal;
  confirm?: readonly Subscription<any>[];
  /**
   * Predictions apply immediately and roll back on definite failure. Successful snapshot/append predictions wait
   * for correlated confirmation or TTL; unknown predictions wait for TTL. Presence retains roster-update/TTL
   * behavior. Only subscriptions with data that were created by this client can be predicted.
   */
  optimistic?: OptimisticUpdate[];
}

export type OperationOutcome = "completed" | "committed" | "accepted";

export type RecoveryResult<Data> =
  | { readonly status: "committed" | "accepted"; readonly data: Data }
  | { readonly status: "unknown" };

export type MutationState<Data> =
  | { readonly status: "pending" }
  | { readonly status: OperationOutcome; readonly data: Data }
  | { readonly status: "failed"; readonly error: unknown }
  | { readonly status: "unknown"; readonly error: import("./errors.js").OutcomeUnknownError };

export interface RecoveryOptions extends RequestOptions {
  idempotencyKey: string;
}

export interface Mutation<Data> {
  readonly idempotencyKey: string;
  readonly result: Promise<Data>;
  readonly views: Promise<readonly ViewConfirmation[]>;
  getState(): MutationState<Data>;
  onChange(listener: (state: MutationState<Data>) => void): () => void;
  recover(options?: RequestOptions): Promise<MutationState<Data>>;
}

export interface ViewConfirmation {
  readonly subscription: Subscription<any>;
  readonly status: "confirmed" | "unconfirmed";
  readonly error?: unknown;
}

export interface Client<Contract extends FyrletContract> {
  call<Name extends keyof Contract["operations"] & string>(
    name: Name,
    input: Contract["operations"][Name]["input"],
    options?: CallOptions,
  ): Promise<Contract["operations"][Name]["output"]>;
  mutate<Name extends keyof Contract["operations"] & string>(
    name: Name,
    input: Contract["operations"][Name]["input"],
    options?: CallOptions,
  ): Mutation<Contract["operations"][Name]["output"]>;
  recover<Name extends keyof Contract["operations"] & string>(
    name: Name,
    input: Contract["operations"][Name]["input"],
    options: RecoveryOptions,
  ): Promise<RecoveryResult<Contract["operations"][Name]["output"]>>;
  subscribe<Name extends keyof Contract["subscriptions"] & string>(
    name: Name,
    params: Contract["subscriptions"][Name]["input"],
  ): Subscription<Contract["subscriptions"][Name]["output"]>;
  /**
   * Subscribes to an append-mode subscription (needs the "append" capability). `data` is the
   * newest `max_items` items; new items are appended and the oldest evicted. It is a window,
   * not the full history: after a reset it holds only what the server's snapshot contains.
   */
  subscribeAppend<Name extends keyof Contract["subscriptions"] & string>(
    name: Name,
    params: Contract["subscriptions"][Name]["input"],
  ): Subscription<Contract["subscriptions"][Name]["output"]>;
  /**
   * Joins a presence room (needs the "presence" capability). `data` is the roster. Presence
   * names come from the contract's `presence` section, which the generated types do not cover.
   */
  subscribePresence(name: string, params: unknown, meta?: Record<string, unknown>): PresenceSubscription;
  /** Starts a durable run through a `run` operation. Accepted is not completed: observe it with `subscribeRun`. */
  startRun<Name extends keyof Contract["operations"] & string>(
    name: Name,
    input: Contract["operations"][Name]["input"],
    options?: CallOptions,
  ): Promise<StartedRun>;
  getRun(runId: string, options?: RequestOptions): Promise<RunView>;
  signalRun(runId: string, signal: RunSignal, options?: RequestOptions): Promise<SignalReceipt>;
  cancelRun(runId: string, options?: RequestOptions): Promise<CancelReceipt>;
  subscribeRun(runId: string): Subscription<RunView>;
  subscribeRecentRuns(limit?: number): Subscription<RunSummary[]>;
  reconnect(): Promise<void>;
  close(): void;
}

export interface RequestOptions {
  signal?: AbortSignal;
}

export type RunStatus =
  | "pending" | "running" | "waiting" | "completed"
  | "failed" | "cancelling" | "cancelled" | "expired";

export interface StartedRun {
  run_id: string;
  status: RunStatus;
  existing?: boolean;
}

export interface RunSignal {
  wait_id: string;
  name: string;
  payload?: unknown;
  /** Reusing a key with the same signal returns the same receipt; a different payload conflicts. */
  idempotency_key?: string;
}

export interface SignalReceipt {
  /** `accepted`: stored, not consumed yet. `consumed`: the wait was satisfied. */
  status: "accepted" | "consumed";
  [key: string]: unknown;
}

export interface CancelReceipt {
  status: RunStatus;
  cancel_deadline?: string | null;
  /** `confirmed`: the executor stopped. `fenced_timeout`: it can no longer advance the run, but may still be running. */
  cancellation_outcome?: "confirmed" | "fenced_timeout" | null;
  [key: string]: unknown;
}

export interface RunSummary {
  id: string;
  status: RunStatus;
  operation?: string;
  [key: string]: unknown;
}

export interface RunView extends RunSummary {
  wait_reason?: string | null;
  cancel_deadline?: string | null;
  cancellation_outcome?: "confirmed" | "fenced_timeout" | null;
  error_code?: string | null;
  error_message?: string | null;
  /** The run output, JSON-encoded by the server. */
  output_json?: string | null;
  steps?: Array<{ name: string; status: string; [key: string]: unknown }>;
  effects?: Array<{ status: string; [key: string]: unknown }>;
  events?: Array<Record<string, unknown>>;
  /** True when older events were dropped from the bounded window; history is not complete. */
  events_truncated?: boolean;
}
