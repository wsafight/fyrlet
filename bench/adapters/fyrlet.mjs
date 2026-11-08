import { createClient } from "../../sdks/typescript/dist/index.js";

export const capabilities = {
  transport: "Phoenix Channels v2 + bounded same-turn frame batches + unreferenced ACK + operation RPC", database: "PostgreSQL", synchronization: "session-isolated shared observers; normalized ID views; incremental windows + bounded reserve; compact deltas + immutable SDK view indexes",
  idempotency: "transactional, retained 24h", notification: "post-commit broadcast + deduplicated transactional Oban fallback + reconciliation",
  client: "Fyrlet TypeScript SDK", authorization: "operations revalidated; shared refresh checks session before and after computation, with independent join checks and expiry enforcement",
};

export async function connect({ endpoint, fixture, user, network, timeoutMs, observe = true }) {
  let offline;
  let release;
  const client = createClient({
    endpoint, projectId: fixture.project_id, WebSocket: network.WebSocket, fetch: network.fetch, timeoutMs,
    getToken: async () => { if (offline) await offline; return user.token; },
    retryDelayMs: () => 50,
    operationTransport: "socket",
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
    add: (text) => client.call("inbox.add", { text }, { idempotencyKey: crypto.randomUUID() }),
    archive: (item, archived) => client.call("inbox.archive", { id: item.id, expected_version: item.version, archived }, { idempotencyKey: crypto.randomUUID() }),
    remove: (item) => client.call("inbox.delete", { id: item.id, expected_version: item.version }, { idempotencyKey: crypto.randomUUID() }),
    history: (cursor) => client.call("inbox.history", { limit: 100, include_archived: true, ...(cursor ? { cursor } : {}) }),
    confirm: () => subscription.confirm(),
    offline: async () => { offline = new Promise((resolve) => { release = resolve; }); network.disconnect(); },
    online: async () => { offline = undefined; release?.(); await client.reconnect(); },
    close: () => { offline = undefined; release?.(); subscription?.unsubscribe(); client.close(); },
  };
}
