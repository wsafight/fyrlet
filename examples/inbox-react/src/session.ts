import { ApiError, createClient } from "@fyrlet/client";
import { operationMetadata } from "@fyrlet/client/example-contract";
import type { AppContract } from "@fyrlet/client/example-contract";

export interface HostConfig {
  user: { name: string; issuer: string; revision: string } | null;
  endpoint: string;
  projectId: string;
  providers: Array<{ name: string; label: string }>;
}

export async function hostConfig(signal?: AbortSignal): Promise<HostConfig> {
  const response = await fetch("/auth/me", { cache: "no-store", ...(signal ? { signal } : {}) });
  if (!response.ok) throw new Error("无法读取登录状态，请刷新页面");
  return response.json() as Promise<HostConfig>;
}

export function connect(config: HostConfig, expired: () => void) {
  const controller = new AbortController();
  let cached: { token: string; expires_at: string } | undefined;
  let flight: Promise<string> | undefined;
  const client = createClient<AppContract>({
    endpoint: config.endpoint, projectId: config.projectId, shareSubscriptions: true, operationMetadata,
    getToken: ({ forceRefresh }) => {
      if (!forceRefresh && cached && Date.parse(cached.expires_at) > Date.now() + 30_000) return cached.token;
      if (flight) return flight;
      flight = (async () => {
        const response = await fetch("/api/fyrlet/session", { method: "POST", signal: controller.signal, cache: "no-store",
          headers: forceRefresh ? { "x-fyrlet-refresh": "1" } : {} });
        if (response.status === 401) {
          close();
          expired();
          throw new ApiError({ code: "UNAUTHENTICATED", message: "登录已到期，请重新登录" });
        }
        if (!response.ok) throw new ApiError({ code: "NETWORK_ERROR", message: "暂时无法连接，请稍后重试", retryable: true });
        const next = await response.json();
        if (typeof next.token !== "string" || !next.token.startsWith("rts_") || next.project_id !== config.projectId ||
            typeof next.expires_at !== "string" || !Number.isFinite(Date.parse(next.expires_at))) throw new ApiError({ code: "PROTOCOL_ERROR", message: "登录响应无效，请重新登录" });
        controller.signal.throwIfAborted();
        cached = next;
        return next.token as string;
      })();
      void flight.finally(() => { flight = undefined; }).catch(() => {});
      return flight;
    },
  });
  function close() { controller.abort(); cached = undefined; client.close(); }
  return { client, close };
}

export type Connection = ReturnType<typeof connect>;
