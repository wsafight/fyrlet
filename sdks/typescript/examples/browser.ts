import { createClient, ApiError } from "../src/index.js";
import type { AppContract } from "../src/generated/app.js";

export function openInbox(endpoint: string, projectId: string) {
  const client = createClient<AppContract>({
    endpoint,
    projectId,
    getToken: async ({ forceRefresh }) => {
      const response = await fetch("/api/fyrlet-session", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ forceRefresh }),
      });
      if (!response.ok) throw new ApiError({ code: "UNAUTHENTICATED", message: "Sign in to continue" });
      const session: { token: string } = await response.json();
      return session.token;
    },
  });
  const recent = client.subscribe("inbox.recent", { limit: 20 });
  return { client, recent, dispose: () => client.close() };
}
