import test from "node:test";
import assert from "node:assert/strict";
import { createClient, ApiError } from "../dist/index.js";
import { createSessionService } from "../dist/server.js";
import { generate } from "../scripts/generate.mjs";
import { readFile } from "node:fs/promises";
import { TestWebSocket, until, response } from "./helpers.mjs";
import { applyDelta, immutable } from "../dist/delta.js";
import { decodeFrames } from "../dist/transport.js";

const identity = { project_id: "project", subject_id: "alice" };
const unauthorized = { code: "UNAUTHENTICATED", message: "Expired", retryable: false };

test("transport batches validate every frame before dispatch and preserve order", () => {
  const first = ["1", null, "subscription:a", "delta", { s: 2 }];
  const second = ["2", null, "subscription:b", "snapshot", { seq: 2 }];
  const messages = [];
  decodeFrames(JSON.stringify({ batch: [first, second] }), (message) => messages.push(message));
  assert.deepEqual(messages.map((message) => message.topic), ["subscription:a", "subscription:b"]);
  decodeFrames(JSON.stringify(first), (message) => assert.equal(message.payload.s, 2));
  for (const invalid of [{ batch: [] }, { batch: Array(65).fill(first) }, { batch: [first, []] },
    { batch: [first], extra: true }, [null, null, "topic", "event", null]]) {
    let dispatched = false;
    assert.throws(() => decodeFrames(JSON.stringify(invalid), () => { dispatched = true; }), TypeError);
    assert.equal(dispatched, false);
  }
});

test("retryable observer failures reconnect and malformed batches fail explicitly", async (context) => {
  const instance = client(context);
  const subscription = instance.subscribe("inbox.recent", {});
  await until(() => subscription.getState().status === "ready");
  const old = subscription.getState().generation;
  const socket = TestWebSocket.instances.at(-1);
  const [topic, { joinRef }] = [...socket.joins][0];
  socket.emit([joinRef, null, topic, "status", { error: { code: "INTERNAL_ERROR", message: "Observer failed", retryable: true } }]);
  await until(() => subscription.getState().status === "ready" && subscription.getState().generation !== old);
  TestWebSocket.instances.at(-1).emit({ batch: [[]] });
  assert.equal(subscription.getState().status, "error");
  assert.equal(subscription.getState().error.code, "PROTOCOL_ERROR");
});

test("deltas apply field changes, nulls, removals and ordering without mutating earlier views", () => {
  const initial = immutable([{ id: "a", text: "old", optional: true }, { id: "b" }]);
  const updated = applyDelta(initial, { c: [["a", { text: null }, ["optional"]]],
    r: ["b"], a: [{ id: "c", text: "new" }], o: ["c", "a"] });
  assert.deepEqual(updated, [{ id: "c", text: "new" }, { id: "a", text: null }]);
  assert.equal(initial[0].text, "old");
  assert.ok(Object.isFrozen(updated) && Object.isFrozen(updated[1]));
  const malicious = JSON.parse('{"c":[["a",{"__proto__":{"polluted":true}}]]}');
  const safe = applyDelta(initial, malicious);
  assert.equal(Object.getPrototypeOf(safe[0]), Object.prototype);
  assert.equal({}.polluted, undefined);
  assert.ok(Object.hasOwn(safe[0], "__proto__"));
});

test("malformed deltas reject ambiguous IDs, missing bases and incomplete orderings", () => {
  for (const patch of [{ c: [["missing", {}]] }, { c: [["a", { id: "other" }]] },
    { a: [{ id: "a" }] }, { r: ["missing"] }, { o: [] }, { o: ["a", "a"] },
    { c: [["a", { text: "x" }, ["text"]]] }, { r: "a" }, { unknown: [] }]) {
    assert.throws(() => applyDelta([{ id: "a" }], patch), TypeError);
  }
});

test("indexed replacements share unchanged records without mutating earlier immutable views", () => {
  const initial = immutable([{ id: "a", text: "before", optional: true }, { id: "b", text: "same" }]);
  const first = applyDelta(initial, { c: [["a", { text: null }, ["optional"]]] });
  const second = applyDelta(first, { c: [["a", { text: "after" }], ["b", { text: "changed" }]] });
  assert.equal(first[1], initial[1]);
  assert.equal(initial[0].text, "before");
  assert.equal(first[0].text, null);
  assert.equal(second[0].text, "after");
  assert.ok(Object.isFrozen(second) && second.every(Object.isFrozen));
  for (const patch of [{ c: [["a", {}], ["a", {}]] }, { c: [["missing", {}]] },
    { c: [["a", {}, ["id"]]] }, { c: [["a", {}, ["text", "text"]]] }]) {
    assert.throws(() => applyDelta(second, patch), TypeError);
  }
  const reordered = applyDelta(second, { o: ["b", "a"] });
  assert.equal(applyDelta(reordered, { c: [["b", { text: "indexed after reorder" }]] })[0].text, "indexed after reorder");
});

test("mutable records and accessor IDs never reuse immutable view indexes", () => {
  const mutable = { id: "a", text: "before" };
  const previous = applyDelta(Object.freeze([mutable]), {});
  mutable.id = "b";
  assert.throws(() => applyDelta(previous, { c: [["a", {}]] }), TypeError);
  assert.equal(applyDelta(previous, { c: [["b", { text: "after" }]] })[0].text, "after");
  let identifier = "a";
  const accessor = Object.freeze({ get id() { return identifier; } });
  const accessorView = applyDelta(Object.freeze([accessor]), {});
  identifier = "b";
  assert.throws(() => applyDelta(accessorView, { c: [["a", {}]] }), TypeError);
  assert.throws(() => applyDelta(immutable([{ id: "a" }, { id: "a" }]), {}), TypeError);
});

test("negotiated deltas are acknowledged, stale generations ignored and gaps recover by rejoining", async (context) => {
  const instance = client(context);
  const subscription = instance.subscribe("inbox.recent", {});
  await until(() => subscription.getState().status === "ready");
  const socket = TestWebSocket.instances.at(-1);
  socket.snapshot([{ id: "a", text: "old" }], { seq: 2 });
  const [topic, joined] = [...socket.joins][0];
  const send = (payload) => socket.emit([joined.joinRef, null, topic, "delta", { g: joined.snapshot.generation, ...payload }]);
  send({ s: 3, b: 2, p: { c: [["a", { text: "new" }]] } });
  assert.deepEqual(subscription.getState().data, [{ id: "a", text: "new" }]);
  send({ s: 3, b: 2, p: { c: [["a", { text: "stale" }]] } });
  send({ g: "old", s: 4, b: 3, p: {} });
  assert.equal(subscription.getState().seq, 3);
  assert.equal(socket.messages.at(-1).event, "ack");
  await Promise.resolve();
  send({ s: 5, b: 4, p: {} });
  assert.equal(subscription.getState().status, "recovering");
  await until(() => subscription.getState().status === "ready" && subscription.getState().generation !== joined.snapshot.generation);
  assert.deepEqual(subscription.getState().data, ["initial"]);
});

function client(context, options = {}) {
  const instance = createClient({
    endpoint: "http://localhost:4000", projectId: "project", getToken: () => "rts_test",
    fetch: async () => response(identity), WebSocket: TestWebSocket, retryDelayMs: () => 10, ...options,
  });
  context.after(() => instance.close());
  return instance;
}

test("acknowledgements are unreferenced notifications without reply timers", async (context) => {
  const instance = client(context);
  const subscription = instance.subscribe("inbox.recent", {});
  await until(() => subscription.getState().status === "ready");
  const socket = TestWebSocket.instances.at(-1);
  const originalTimeout = globalThis.setTimeout;
  let timers = 0;
  context.mock.method(globalThis, "setTimeout", (...parameters) => {
    timers += 1;
    return originalTimeout(...parameters);
  });
  for (let sequence = 2; sequence <= 51; sequence += 1) socket.snapshot([sequence], { seq: sequence });
  const acknowledgements = socket.messages.filter((message) => message.event === "ack");
  assert.equal(acknowledgements.length, 51);
  assert.ok(acknowledgements.every((message) => message.ref === null && message.joinRef === null));
  assert.deepEqual(acknowledgements.at(-1).payload, { g: subscription.getState().generation, s: 51 });
  assert.equal(timers, 0);
  assert.equal(subscription.getState().seq, 51);
});

test("compact patches preserve nulls, clearing, membership and ordering and reject malformed tuples", () => {
  const initial = [{ id: "a", text: "before", optional: true }, { id: "b" }];
  const patch = { c: [["a", { text: null }, ["optional"]]], r: ["b"],
    a: [{ id: "c", text: "更新\n\"\\" }], o: ["c", "a"] };
  assert.deepEqual(applyDelta(initial, patch), [{ id: "c", text: "更新\n\"\\" }, { id: "a", text: null }]);
  for (const invalid of [null, [], { unknown: [] }, { c: [["a"]] }, { c: [["a", {}, null]] },
    { c: [["a", {}, [], "extra"]] }, { c: [null] }, { c: {} }, { r: "a" }]) {
    assert.throws(() => applyDelta(initial, invalid), TypeError);
  }
});

test("socket operations share one connection and preserve generated idempotency keys", async (context) => {
  const urls = [];
  const instance = client(context, { operationTransport: "socket", fetch: async (url) => { urls.push(url); return response(identity); } });
  const results = await Promise.all(Array.from({ length: 4 }, (_, index) => instance.call("inbox.add", { text: `item ${index}` })));
  assert.equal(new Set(results.map((result) => result.idempotency_key)).size, 4);
  assert.deepEqual(results.map((result) => result.input.text), ["item 0", "item 1", "item 2", "item 3"]);
  const socket = TestWebSocket.instances.at(-1);
  assert.equal(socket.messages.filter((entry) => entry.event === "phx_join" && entry.topic === "operations").length, 1);
  assert.equal(urls.length, 1);
  assert.ok(urls[0].endsWith("/identity"));
});

test("socket authentication refresh retries once with the same idempotency key", async (context) => {
  const calls = [];
  class RefreshSocket extends TestWebSocket {
    send(raw) {
      const [joinRef, ref, topic, event, payload] = JSON.parse(raw);
      if (event !== "call") return super.send(raw);
      calls.push(payload);
      queueMicrotask(() => this.emit([joinRef, ref, topic, "phx_reply", calls.length === 1
        ? { status: "error", response: { error: unauthorized, status: 401 } }
        : { status: "ok", response: { data: "saved" } }]));
    }
  }
  const instance = client(context, { operationTransport: "socket", WebSocket: RefreshSocket,
    getToken: ({ forceRefresh }) => forceRefresh ? "rts_new" : "rts_old" });
  assert.equal(await instance.call("inbox.add", { text: "value" }), "saved");
  assert.equal(calls.length, 2);
  assert.equal(calls[0].idempotency_key, calls[1].idempotency_key);
});

test("interrupted socket writes reject promptly and are never automatically replayed", async (context) => {
  let calls = 0;
  class InterruptedSocket extends TestWebSocket {
    send(raw) { if (JSON.parse(raw)[3] === "call") { calls++; return; } super.send(raw); }
  }
  const instance = client(context, { operationTransport: "socket", WebSocket: InterruptedSocket, timeoutMs: 50 });
  const pending = instance.call("inbox.add", { text: "unknown result" });
  const rejected = assert.rejects(pending, { code: "NETWORK_ERROR" });
  await until(() => calls === 1);
  TestWebSocket.instances.at(-1).interrupt();
  await rejected;
  await until(() => TestWebSocket.instances.at(-1).readyState === 1);
  assert.equal(calls, 1);
});

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
