import { ApiError, OutcomeUnknownError } from "./errors.js";
import type { OperationReceipt } from "./mutation.js";
import type { OperationKind, RecoveryResult, RetryOptions, RetryProgress } from "./types.js";

export function retryPolicy(options: RetryOptions): Required<RetryOptions> {
  const policy = { maxAttempts: 3, maxElapsedMs: 15_000, baseDelayMs: 250, maxDelayMs: 5_000, ...options };
  for (const [name, value] of Object.entries(policy)) {
    const minimum = name === "baseDelayMs" || name === "maxDelayMs" ? 0 : 1;
    const maximum = name === "maxAttempts" ? 10 : 60_000;
    if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new TypeError(`${name} must be an integer between ${minimum} and ${maximum}`);
  }
  if (policy.maxDelayMs < policy.baseDelayMs) throw new TypeError("maxDelayMs must be at least baseDelayMs");
  return policy;
}

function transient(error: unknown): boolean {
  const cause = error instanceof OutcomeUnknownError ? error.cause : error;
  return cause instanceof ApiError && cause.retryable &&
    (["NETWORK_ERROR", "TIMEOUT"].includes(cause.code) ||
      (cause.code === "LIMIT_EXCEEDED" && (cause.status === 429 || cause.status === 503)) ||
      (["UNAVAILABLE", "INTERNAL_ERROR"].includes(cause.code) && cause.status === 503));
}

function wait(delay: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const finish = () => { signal.removeEventListener("abort", abort); resolve(); };
    const timer = setTimeout(finish, delay);
    const abort = () => { clearTimeout(timer); signal.removeEventListener("abort", abort); reject(signal.reason); };
    if (signal.aborted) abort();
    else signal.addEventListener("abort", abort, { once: true });
  });
}

export async function retryOperation<Data>(
  kind: OperationKind,
  policy: Required<RetryOptions>,
  signal: AbortSignal,
  perform: () => Promise<OperationReceipt<Data>>,
  recover: () => Promise<RecoveryResult<Data>>,
  report: (progress: RetryProgress) => void,
): Promise<OperationReceipt<Data>> {
  let unknown: OutcomeUnknownError | undefined;
  let failure: unknown;
  let recovering = false;
  for (let attempt = 1; attempt <= policy.maxAttempts; attempt++) {
    try {
      signal.throwIfAborted();
      report({ attempt, phase: recovering ? "recover" : "call" });
      if (!recovering) return await perform();
      const receipt = await recover();
      if (receipt.status !== "unknown") return { outcome: receipt.status, data: receipt.data };
    } catch (error) {
      failure = error;
      if (error instanceof OutcomeUnknownError) {
        unknown ??= error;
        if (kind !== "read") recovering = true;
      }
      if (signal.aborted || !transient(error)) throw unknown ?? error;
    }
    if (attempt === policy.maxAttempts) break;
    const error = failure instanceof OutcomeUnknownError ? failure.cause : failure;
    const after = error instanceof ApiError ? error.details.retry_after_ms : 0;
    const jitter = Math.random() * Math.min(policy.maxDelayMs, policy.baseDelayMs * 2 ** (attempt - 1));
    const delay = Math.max(jitter, typeof after === "number" && Number.isFinite(after) && after > 0 ? after : 0);
    report({ attempt, phase: recovering ? "recover" : "call", nextRetryAt: Date.now() + delay });
    try { await wait(Math.min(delay, 60_001), signal); }
    catch (error) { throw unknown ?? error; }
  }
  throw unknown ?? failure;
}
