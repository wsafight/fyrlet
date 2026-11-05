import { ApiError, asApiError } from "./errors.js";

export function endpointURL(endpoint: string): string {
  const url = new URL(endpoint);
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
    throw new TypeError("endpoint must be an HTTP(S) base URL without credentials, query or fragment");
  }
  return url.toString().replace(/\/$/, "");
}

export async function request<Data>(
  fetcher: typeof globalThis.fetch,
  url: string,
  init: RequestInit,
): Promise<Data> {
  let response: Response;
  try {
    response = await fetcher(url, { ...init, cache: "no-store", credentials: "omit" });
  } catch (error) {
    if (init.signal?.aborted) throw init.signal.reason ?? error;
    throw asApiError(error);
  }
  let body: { data?: Data; request_id?: string; error?: { code: string; message: string; details?: Record<string, unknown>; retryable?: boolean } };
  try {
    body = await response.json();
  } catch {
    throw new ApiError({ code: "PROTOCOL_ERROR", message: "Expected a JSON response" }, response.status);
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new ApiError({ code: "PROTOCOL_ERROR", message: "Expected a response envelope" }, response.status);
  }
  if (!response.ok || body.error) {
    throw new ApiError(body.error ?? { code: "HTTP_ERROR", message: "The request was rejected" }, response.status, body.request_id);
  }
  if (!("data" in body)) throw new ApiError({ code: "PROTOCOL_ERROR", message: "Missing response data" }, response.status);
  return body.data as Data;
}
