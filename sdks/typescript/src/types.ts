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
}

export interface Subscription<Data> {
  getState(): SubscriptionState<Data>;
  onChange(listener: (state: SubscriptionState<Data>) => void): () => void;
  refresh(): Promise<void>;
  unsubscribe(): void;
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
  operationTransport?: "http" | "socket";
}

export interface CallOptions {
  idempotencyKey?: string;
  signal?: AbortSignal;
}

export interface Client<Contract extends FyrletContract> {
  call<Name extends keyof Contract["operations"] & string>(
    name: Name,
    input: Contract["operations"][Name]["input"],
    options?: CallOptions,
  ): Promise<Contract["operations"][Name]["output"]>;
  subscribe<Name extends keyof Contract["subscriptions"] & string>(
    name: Name,
    params: Contract["subscriptions"][Name]["input"],
  ): Subscription<Contract["subscriptions"][Name]["output"]>;
  reconnect(): Promise<void>;
  close(): void;
}
