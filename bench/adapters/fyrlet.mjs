import { createClient } from "../../sdks/typescript/dist/index.js";

export const capabilities = {
  transport: "Phoenix Channels v2 + HTTP", database: "PostgreSQL", synchronization: "bounded full snapshots",
  idempotency: "transactional, retained 24h", notification: "post-commit broadcast + deduplicated transactional Oban fallback + reconciliation",
  client: "Fyrlet TypeScript SDK", authorization: "session revalidated on operations and snapshots",
};

export async function connect({ endpoint, fixture, user, network, timeoutMs, observe = true }) {
  let offline;
  let release;
  const client = createClient({
    endpoint, projectId: fixture.project_id, WebSocket: network.WebSocket, fetch: network.fetch, timeoutMs,
    getToken: async () => { if (offline) await offline; return user.token; },
    retryDelayMs: () => 50,
  });
  const subscription = observe ? client.subscribe("inbox.recent", { limit: fixture.rows }) : undefined;
  if (!observe) {
    try { await client.call("inbox.history", { limit: 1 }); }
    catch (error) { client.close(); throw error; }
  }
  return {
    getState: () => subscription?.getState(),
    onChange: (listener) => subscription?.onChange(listener),
    update: (item, text) => client.call("inbox.update", { id: item.id, text, expected_version: item.version }, { idempotencyKey: crypto.randomUUID() }),
    offline: async () => { offline = new Promise((resolve) => { release = resolve; }); network.disconnect(); },
    online: async () => { offline = undefined; release?.(); await client.reconnect(); },
    close: () => { offline = undefined; release?.(); subscription?.unsubscribe(); client.close(); },
  };
}
