import { endpointURL, request } from "./http.js";
export { ApiError } from "./errors.js";

export interface UserSession {
  token: string;
  project_id: string;
  subject_id: string;
  session_id: string;
  expires_at: string;
}

export function createSessionService(options: {
  endpoint: string;
  serviceKey: string;
  fetch?: typeof globalThis.fetch;
}) {
  if (!options.serviceKey.startsWith("rtk_")) throw new TypeError("Expected a backend service key");
  const endpoint = endpointURL(options.endpoint);
  const fetcher = options.fetch ?? globalThis.fetch;
  const headers = { authorization: `Bearer ${options.serviceKey}`, "content-type": "application/json" };

  return {
    issueSession(input: { external_subject: string; issuer?: string; ttl_seconds?: number }, signal?: AbortSignal) {
      return request<UserSession>(fetcher, `${endpoint}/api/v1/sessions`, {
        method: "POST", headers, body: JSON.stringify(input), ...(signal ? { signal } : {}),
      });
    },
    revokeSession(sessionId: string, signal?: AbortSignal) {
      return request<{ revoked: boolean }>(fetcher, `${endpoint}/api/v1/sessions/${encodeURIComponent(sessionId)}`, {
        method: "DELETE", headers, ...(signal ? { signal } : {}),
      });
    },
  };
}
