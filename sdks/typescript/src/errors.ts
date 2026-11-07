import type { ErrorDetails } from "./types.js";

export class ApiError extends Error {
  readonly code: string;
  readonly details: Record<string, unknown>;
  readonly retryable: boolean;
  readonly status: number;
  readonly requestId: string | undefined;

  constructor(error: Partial<ErrorDetails> & { code: string; message: string }, status = 0, requestId?: string) {
    super(error.message);
    this.name = "ApiError";
    this.code = error.code;
    this.details = error.details ?? {};
    this.retryable = error.retryable ?? false;
    this.status = status;
    this.requestId = requestId;
  }
}

export function asApiError(error: unknown): ApiError {
  if (error instanceof ApiError) return error;
  return new ApiError({ code: "NETWORK_ERROR", message: "The service could not be reached", retryable: true });
}

export function channelError(payload: unknown): ApiError {
  if (payload && typeof payload === "object" && "error" in payload) {
    const error = payload.error;
    if (error && typeof error === "object" && "code" in error && "message" in error) {
      return new ApiError(error as ErrorDetails, "status" in payload && typeof payload.status === "number" ? payload.status : 0);
    }
  }
  return new ApiError({ code: "PROTOCOL_ERROR", message: "The server returned an invalid channel response" });
}
