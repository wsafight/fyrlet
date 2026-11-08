import { ApiError, OutcomeUnknownError } from "./errors.js";
import type { Mutation, MutationState, OperationOutcome, RecoveryResult, RequestOptions, ViewConfirmation } from "./types.js";

export interface OperationReceipt<Data> { outcome: OperationOutcome; data: Data }

export function operationReceipt<Data>(payload: unknown): OperationReceipt<Data> {
  if (!payload || typeof payload !== "object" || Array.isArray(payload) || !("data" in payload) || !("outcome" in payload) ||
      !["completed", "committed", "accepted"].includes(payload.outcome as string)) {
    throw new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid operation outcome" });
  }
  return payload as OperationReceipt<Data>;
}

export function recoveryResult<Data>(payload: unknown): RecoveryResult<Data> {
  if (payload && typeof payload === "object" && !Array.isArray(payload) &&
      "outcome" in payload && payload.outcome === "unknown" && "data" in payload && payload.data === null) {
    return { status: "unknown" };
  }
  const receipt = operationReceipt<Data>(payload);
  if (receipt.outcome === "completed") {
    throw new ApiError({ code: "PROTOCOL_ERROR", message: "A read outcome cannot be recovered" });
  }
  return { status: receipt.outcome, data: receipt.data };
}

export class MutationTask<Data> implements Mutation<Data> {
  readonly result: Promise<Data>;
  readonly views: Promise<readonly ViewConfirmation[]>;
  private state: MutationState<Data> = Object.freeze({ status: "pending" });
  private readonly listeners = new Set<(state: MutationState<Data>) => void>();
  private recovery: Promise<MutationState<Data>> | undefined;

  constructor(
    readonly idempotencyKey: string,
    perform: () => Promise<OperationReceipt<Data>>,
    private readonly lookup: (options: RequestOptions) => Promise<RecoveryResult<Data>>,
    private readonly onListenerError: ((error: unknown) => void) | undefined,
    confirmViews: (error?: unknown) => Promise<readonly ViewConfirmation[]>,
  ) {
    this.result = perform().then((receipt) => {
      this.setState({ status: receipt.outcome, data: receipt.data });
      return receipt.data;
    }, (error: unknown) => {
      this.setState(error instanceof OutcomeUnknownError ? { status: "unknown", error } : { status: "failed", error });
      throw error;
    });
    void this.result.catch(() => {});
    this.views = this.result.then(() => confirmViews(), (error: unknown) => confirmViews(error));
    void this.views.catch(() => {});
  }

  getState(): MutationState<Data> { return this.state; }

  onChange(listener: (state: MutationState<Data>) => void): () => void {
    this.listeners.add(listener);
    this.notify(listener);
    return () => { this.listeners.delete(listener); };
  }

  recover(options: RequestOptions = {}): Promise<MutationState<Data>> {
    if (this.recovery) return this.recovery;
    if (this.state.status !== "unknown") return Promise.resolve(this.state);
    const flight = this.lookup(options).then((result) => {
      if (result.status !== "unknown") this.setState(result);
      return this.state;
    });
    this.recovery = flight;
    void flight.finally(() => { if (this.recovery === flight) this.recovery = undefined; }).catch(() => {});
    return flight;
  }

  private setState(state: MutationState<Data>): void {
    this.state = Object.freeze(state);
    for (const listener of this.listeners) this.notify(listener);
  }

  private notify(listener: (state: MutationState<Data>) => void): void {
    try { listener(this.state); }
    catch (error) {
      try { this.onListenerError?.(error); } catch {}
    }
  }
}
