import { ApiError } from "./errors.js";

type ManagedController = AbortController & { dispose: () => void };

interface RequestSession {
  authorize(forceRefresh: boolean): Promise<string>;
  assertOpen(): void;
  fail(error: ApiError): void;
}

export function awaitAbortable<Value>(promise: Promise<Value>, signal: AbortSignal): Promise<Value> {
  return new Promise((resolve, reject) => {
    const cleanup = () => signal.removeEventListener("abort", abort);
    const abort = () => { cleanup(); reject(signal.reason); };
    void promise.then((value) => { cleanup(); resolve(value); }, (error: unknown) => { cleanup(); reject(error); });
    if (signal.aborted) abort();
    else signal.addEventListener("abort", abort, { once: true });
  });
}

export class RequestExecutor {
  private readonly controllers = new Set<ManagedController>();

  constructor(private readonly timeoutMs: number, private readonly session: RequestSession) {}

  async execute<Data>(
    signal: AbortSignal | undefined,
    perform: (token: string, signal: AbortSignal) => Promise<Data>,
    onRefresh?: () => void,
  ): Promise<Data> {
    this.session.assertOpen();
    const controller = this.controller(signal);
    let authorizing = true;
    try {
      const token = await awaitAbortable(this.session.authorize(false), controller.signal);
      authorizing = false;
      this.session.assertOpen();
      try {
        return await perform(token, controller.signal);
      } catch (error) {
        if (!(error instanceof ApiError) || (error.status !== 401 && error.code !== "UNAUTHENTICATED")) throw error;
        authorizing = true;
        const fresh = await awaitAbortable(this.session.authorize(true), controller.signal);
        authorizing = false;
        this.session.assertOpen();
        onRefresh?.();
        return await perform(fresh, controller.signal);
      }
    } catch (error) {
      if (error instanceof ApiError && (error.code === "UNAUTHENTICATED" || (authorizing && error.code === "FORBIDDEN"))) this.session.fail(error);
      throw error;
    } finally {
      this.release(controller);
    }
  }

  controller(signal?: AbortSignal, timeoutMs = this.timeoutMs): ManagedController {
    const controller = new AbortController() as ManagedController;
    const abortExternal = () => controller.abort(signal?.reason);
    const timer = setTimeout(() => controller.abort(new ApiError({ code: "TIMEOUT", message: "The request timed out", retryable: true })), timeoutMs);
    controller.dispose = () => { clearTimeout(timer); signal?.removeEventListener("abort", abortExternal); };
    if (signal) {
      if (signal.aborted) controller.abort(signal.reason);
      else signal.addEventListener("abort", abortExternal, { once: true });
    }
    this.controllers.add(controller);
    return controller;
  }

  release(controller: ManagedController): void {
    this.controllers.delete(controller);
    controller.dispose();
  }

  close(): void {
    for (const controller of this.controllers) { controller.abort(); controller.dispose(); }
    this.controllers.clear();
  }
}
