import test from "node:test";
import assert from "node:assert/strict";
import { createClient, ApiError } from "../dist/index.js";
import { createSessionService } from "../dist/server.js";
import { generate } from "../scripts/generate.mjs";
import { readFile } from "node:fs/promises";
import { TestWebSocket, until, response } from "./helpers.mjs";

const identity = { project_id: "project", subject_id: "alice" };
const unauthorized = { code: "UNAUTHENTICATED", message: "Expired", retryable: false };

function client(context, options = {}) {
  const instance = createClient({
    endpoint: "http://localhost:4000", projectId: "project", getToken: () => "rts_test",
    fetch: async () => response(identity), WebSocket: TestWebSocket, retryDelayMs: () => 10, ...options,
  });
  context.after(() => instance.close());
  return instance;
}

test("HTTP refresh retries once and preserves the generated idempotency key", async (context) => {
  const calls = [];
  const refreshes = [];
  const instance = client(context, {
    getToken: ({ forceRefresh }) => { refreshes.push(forceRefresh); return forceRefresh ? "rts_fresh" : "rts_old"; },
    fetch: async (url, init) => {
      if (url.endsWith("/identity")) return response(identity);
      calls.push(init);
      return init.headers.authorization === "Bearer rts_old" ? response(unauthorized, 401) : response({ id: "saved" });
    },
  });
  assert.deepEqual(await instance.call("inbox.add", { text: "hello" }), { id: "saved" });
  assert.equal(calls.length, 2);
  assert.equal(calls[0].headers["idempotency-key"], calls[1].headers["idempotency-key"]);
  assert.deepEqual(refreshes, [false, true]);
});

test("an expired initial credential can refresh during identity validation", async (context) => {
  const instance = client(context, {
    getToken: ({ forceRefresh }) => forceRefresh ? "rts_fresh" : "rts_old",
    fetch: async (url, init) => init.headers.authorization === "Bearer rts_old" ? response(unauthorized, 401) : response(url.endsWith("/identity") ? identity : []),
  });
  assert.deepEqual(await instance.call("inbox.history", {}), []);
});

test("a second 401 stops retrying and exposes structured errors", async (context) => {
  let count = 0;
  const instance = client(context, {
    fetch: async (url) => { if (url.endsWith("/identity")) return response(identity); count++; return response(unauthorized, 401); },
  });
  await assert.rejects(instance.call("inbox.add", { text: "hello" }), (error) => error instanceof ApiError && error.code === "UNAUTHENTICATED" && error.requestId === "test-request");
  assert.equal(count, 2);
});

test("snapshots ignore old generations and sequence numbers and are acknowledged", async (context) => {
  const instance = client(context);
  const subscription = instance.subscribe("inbox.recent", {});
  await until(() => subscription.getState().status === "ready");
  const socket = TestWebSocket.instances.at(-1);
  assert.ok(socket.protocols[1].startsWith("base64url.bearer.phx."));
  assert.ok(!socket.url.includes("rts_test"));
  socket.snapshot(["new"], { seq: 3 });
  assert.deepEqual(subscription.getState().data, ["new"]);
  socket.snapshot(["old"], { seq: 2 });
  socket.snapshot(["other generation"], { generation: "stale", seq: 100 });
  assert.deepEqual(subscription.getState().data, ["new"]);
  assert.equal(subscription.getState().seq, 3);
  assert.equal(socket.messages.filter((message) => message.event === "ack").length, 3);
  await subscription.refresh();
});

test("transport recovery preserves data, rejoins with a new generation and closes cleanly", async (context) => {
  const instance = client(context);
  const subscription = instance.subscribe("inbox.recent", {});
  await until(() => subscription.getState().status === "ready");
  const first = subscription.getState().generation;
  const oldSocket = TestWebSocket.instances.at(-1);
  oldSocket.interrupt();
  assert.equal(subscription.getState().status, "recovering");
  assert.deepEqual(subscription.getState().data, ["initial"]);
  await until(() => subscription.getState().status === "ready" && subscription.getState().generation !== first);
  oldSocket.snapshot(["late"], { seq: 100 });
  assert.deepEqual(subscription.getState().data, ["initial"]);
  instance.close();
  assert.equal(subscription.getState().status, "closed");
  assert.equal(subscription.getState().data, undefined);
  await assert.rejects(instance.call("inbox.history", {}), { code: "CLIENT_CLOSED" });
});

test("a revoked credential clears subscriptions rather than retaining cached data", async (context) => {
  let revoked = false;
  const instance = client(context, { fetch: async () => revoked ? response(unauthorized, 401) : response(identity) });
  const subscription = instance.subscribe("inbox.recent", {});
  await until(() => subscription.getState().status === "ready");
  revoked = true;
  TestWebSocket.instances.at(-1).interrupt();
  await until(() => subscription.getState().status === "error");
  assert.equal(subscription.getState().data, undefined);
  assert.equal(subscription.getState().error.code, "UNAUTHENTICATED");
});

test("one client cannot refresh into a different subject", async (context) => {
  let changed = false;
  const instance = client(context, { fetch: async () => response({ ...identity, subject_id: changed ? "bob" : "alice" }) });
  const subscription = instance.subscribe("inbox.recent", {});
  await until(() => subscription.getState().status === "ready");
  changed = true;
  await assert.rejects(instance.reconnect(), { code: "FORBIDDEN" });
  assert.equal(subscription.getState().data, undefined);
});

test("closing before token resolution prevents connection and timers", async (context) => {
  let release;
  const pending = new Promise((resolve) => { release = resolve; });
  const instance = client(context, { getToken: () => pending });
  const count = TestWebSocket.instances.length;
  const subscription = instance.subscribe("inbox.recent", {});
  instance.close();
  release("rts_test");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(TestWebSocket.instances.length, count);
  assert.equal(subscription.getState().status, "closed");
});

test("unsubscribe during authentication does not create an unused connection", async (context) => {
  let release;
  const pending = new Promise((resolve) => { release = resolve; });
  const instance = client(context, { getToken: () => pending });
  const count = TestWebSocket.instances.length;
  const subscription = instance.subscribe("inbox.recent", {});
  subscription.unsubscribe();
  release("rts_test");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(TestWebSocket.instances.length, count);
});

test("external abort signals cancel writes without retry", async (context) => {
  const instance = client(context, {
    fetch: async (url, init) => {
      if (url.endsWith("/identity")) return response(identity);
      init.signal.throwIfAborted();
      return new Promise((_resolve, reject) => init.signal.addEventListener("abort", () => reject(init.signal.reason), { once: true }));
    },
  });
  const controller = new AbortController();
  const operation = instance.call("inbox.add", { text: "cancelled" }, { signal: controller.signal });
  controller.abort();
  await assert.rejects(operation, { name: "AbortError" });
});

test("server credentials use a separate API and preserve the service error", async () => {
  const service = createSessionService({ endpoint: "http://localhost:4000", serviceKey: "rtk_backend", fetch: async (_url, init) => {
    assert.equal(init.headers.authorization, "Bearer rtk_backend");
    return response({ code: "NOT_FOUND", message: "Missing" }, 404);
  } });
  await assert.rejects(service.revokeSession("foreign"), { code: "NOT_FOUND", status: 404 });
});

test("contract generation rejects unsupported dialects and models defaults and nulls", () => {
  assert.throws(() => generate({ protocol_version: 2 }));
  const generated = generate({ protocol_version: 1, schema_dialect: "realtime-subset-v1", subscriptions: {}, operations: {
    "example.call": { input: { type: "object", additionalProperties: false, required: ["limit"], properties: { limit: { type: "integer", default: 50 } } }, output: { anyOf: [{ type: "string" }, { type: "null" }] } },
  } });
  assert.ok(generated.includes('"limit"?: number'));
  assert.ok(generated.includes("output: string | null"));
});

test("concurrent 401 responses share one forced token refresh", async (context) => {
  const refreshes = [];
  const instance = client(context, {
    getToken: async ({ forceRefresh }) => {
      refreshes.push(forceRefresh);
      await new Promise((resolve) => setTimeout(resolve, 5));
      return forceRefresh ? "rts_fresh" : "rts_old";
    },
    fetch: async (url, init) => url.endsWith("/identity") ? response(identity) : init.headers.authorization === "Bearer rts_old" ? response(unauthorized, 401) : response([]),
  });
  await Promise.all(Array.from({ length: 10 }, () => instance.call("inbox.history", {})));
  assert.deepEqual(refreshes, [false, true]);
});

test("HTTP timeouts cover the wait for a host token without issuing a write", async (context) => {
  let release;
  const pending = new Promise((resolve) => { release = resolve; });
  const instance = client(context, { timeoutMs: 20, getToken: () => pending });
  await assert.rejects(instance.call("inbox.history", {}), { code: "TIMEOUT" });
  instance.close();
  release("rts_test");
});

test("consumer listener exceptions do not prevent snapshot acknowledgement", async (context) => {
  const errors = [];
  const instance = client(context, { onListenerError: (error) => errors.push(error) });
  const subscription = instance.subscribe("inbox.recent", {});
  subscription.onChange(() => { throw new Error("consumer failure"); });
  await until(() => subscription.getState().status === "ready");
  assert.equal(errors.length, 2);
  assert.equal(TestWebSocket.instances.at(-1).messages.filter((message) => message.event === "ack").length, 1);
});

test("network and malformed-response failures have stable SDK codes", async (context) => {
  const offline = client(context, { fetch: async () => { throw new TypeError("offline"); } });
  await assert.rejects(offline.call("inbox.history", {}), { code: "NETWORK_ERROR", retryable: true });
  const invalid = client(context, { fetch: async () => new Response("null", { status: 200 }) });
  await assert.rejects(invalid.call("inbox.history", {}), { code: "PROTOCOL_ERROR" });
});

test("the checked-in generated types match the exported contract", async () => {
  const contract = JSON.parse(await readFile(new URL("../../../priv/contract.json", import.meta.url), "utf8"));
  const types = await readFile(new URL("../src/generated/app.ts", import.meta.url), "utf8");
  assert.equal(types, generate(contract));
});
