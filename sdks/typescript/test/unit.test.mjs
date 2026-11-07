import test from "node:test";
import assert from "node:assert/strict";
import { createClient, ApiError } from "../dist/index.js";
import { createSessionService } from "../dist/server.js";
import { generate } from "../scripts/generate.mjs";
import { readFile } from "node:fs/promises";
import { TestWebSocket, until, response } from "./helpers.mjs";
import { setTimeout as delay } from "node:timers/promises";
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
  const generated = generate({ protocol_version: 1, schema_dialect: "fyrlet-subset", subscriptions: {}, operations: {
    "example.call": { input: { type: "object", additionalProperties: false, required: ["limit"], properties: { limit: { type: "integer", default: 50 } } }, output: { anyOf: [{ type: "string" }, { type: "null" }] } },
  } });
  assert.ok(generated.includes('"limit"?: number'));
  assert.ok(generated.includes("output: string | null"));
});

test("the generator reads the committed contract and refuses another protocol version", async () => {
  const exported = JSON.parse(await readFile(new URL("../../../priv/contract.json", import.meta.url), "utf8"));
  assert.equal(exported.protocol_version, 1);
  assert.equal(exported.schema_dialect, "fyrlet-subset");
  assert.deepEqual(exported.capabilities, {});
  const generated = generate(exported);
  assert.ok(generated.includes('"inbox.add"'));
  assert.throws(() => generate({ ...exported, protocol_version: 2 }), /Unsupported contract protocol/);
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

// ---- Run API (capability "runs") ----

function recorder(handlers = {}) {
  const calls = [];
  const fetch = async (url, init) => {
    const path = new URL(url).pathname;
    calls.push({ path, init, headers: init.headers ?? {} });
    if (path === "/api/v1/identity") return response(identity);
    return (handlers[`${init.method ?? "GET"} ${path}`] ?? (() => response({})))(init);
  };
  return { calls, fetch };
}

test("clients that declare no capabilities stay on v1 and refuse the Run API", async (context) => {
  const { calls, fetch } = recorder();
  const instance = client(context, { fetch });
  await instance.call("inbox.history", {});
  assert.ok(calls.every((entry) => !("x-fyrlet-capabilities" in entry.headers)));
  const subscription = instance.subscribe("inbox.recent", {});
  await until(() => subscription.getState().status === "ready");
  const join = TestWebSocket.instances.at(-1).messages.find((message) => message.event === "phx_join");
  assert.equal(join.payload.protocol_version, 1);
  assert.equal("capabilities" in join.payload, false);
  for (const attempt of [() => instance.getRun("r"), () => instance.cancelRun("r"),
    () => instance.signalRun("r", { wait_id: "w", name: "n" }), () => instance.startRun("x", {})]) {
    await assert.rejects(attempt(), { code: "UNSUPPORTED_CAPABILITY" });
  }
  assert.throws(() => instance.subscribeRun("r"), { code: "UNSUPPORTED_CAPABILITY" });
  assert.throws(() => instance.subscribeRecentRuns(), { code: "UNSUPPORTED_CAPABILITY" });
  assert.equal(calls.filter((entry) => entry.path.startsWith("/api/v1/runs")).length, 0);
});

test("capability declarations are validated and sent as a header and in joins", async (context) => {
  assert.throws(() => createClient({ endpoint: "http://localhost:4000", projectId: "p", getToken: () => "", capabilities: ["Bad Name"] }), TypeError);
  assert.throws(() => createClient({ endpoint: "http://localhost:4000", projectId: "p", getToken: () => "", capabilities: { runs: 0 } }), TypeError);
  const { calls, fetch } = recorder({ "GET /api/v1/runs/r1": () => response({ id: "r1", status: "waiting" }) });
  const instance = client(context, { fetch, capabilities: { runs: 1 } });
  assert.deepEqual(await instance.getRun("r1"), { id: "r1", status: "waiting" });
  const run = calls.find((entry) => entry.path === "/api/v1/runs/r1");
  assert.equal(run.headers["x-fyrlet-capabilities"], "runs=1");
  assert.equal(run.headers["x-project-id"], "project");
  const subscription = instance.subscribeRun("r1");
  await until(() => subscription.getState().status === "ready");
  const socket = TestWebSocket.instances.at(-1);
  const join = socket.messages.find((message) => message.event === "phx_join");
  assert.deepEqual([join.payload.protocol_version, join.payload.capabilities, join.payload.name, join.payload.params],
    [1, { runs: 1 }, "fyrlet.run", { run_id: "r1" }]);
});

test("startRun sends an idempotency key and signal/cancel use the run endpoints", async (context) => {
  const { calls, fetch } = recorder({
    "POST /api/v1/operations/flow.start": () => response({ run_id: "r1", status: "pending", existing: false }),
    "POST /api/v1/runs/r1/signals": () => response({ status: "accepted" }),
    "POST /api/v1/runs/r1/cancel": () => response({ status: "cancelling", cancel_deadline: "2026-01-01T00:00:00Z" }),
  });
  const instance = client(context, { fetch, capabilities: ["runs"], createId: () => "generated-key" });
  assert.deepEqual(await instance.startRun("flow.start", { a: 1 }), { run_id: "r1", status: "pending", existing: false });
  const start = calls.find((entry) => entry.path === "/api/v1/operations/flow.start");
  assert.equal(start.headers["idempotency-key"], "generated-key");
  assert.equal(start.headers["x-fyrlet-capabilities"], "runs=1");

  assert.deepEqual(await instance.signalRun("r1", { wait_id: "w1", name: "approve", payload: { ok: true } }), { status: "accepted" });
  const signal = calls.find((entry) => entry.path === "/api/v1/runs/r1/signals");
  assert.deepEqual(JSON.parse(signal.init.body), { wait_id: "w1", name: "approve", payload: { ok: true }, idempotency_key: "generated-key" });

  await instance.signalRun("r1", { wait_id: "w1", name: "approve", idempotency_key: "mine" });
  assert.equal(JSON.parse(calls.filter((entry) => entry.path === "/api/v1/runs/r1/signals").at(-1).init.body).idempotency_key, "mine");

  const cancelled = await instance.cancelRun("r1");
  assert.equal(cancelled.status, "cancelling");
  assert.equal(cancelled.cancel_deadline, "2026-01-01T00:00:00Z");
});

test("run API errors surface as ApiError and an expired token is refreshed once", async (context) => {
  let tokens = 0;
  let first = true;
  const { fetch } = recorder({
    "GET /api/v1/runs/r1": () => {
      if (first) { first = false; return response(unauthorized, 401); }
      return response({ id: "r1", status: "completed" });
    },
    "POST /api/v1/runs/r2/cancel": () => response({ code: "NOT_FOUND", message: "No such run", retryable: false }, 404),
  });
  const instance = client(context, { fetch, capabilities: ["runs"], getToken: () => `rts_${++tokens}` });
  assert.equal((await instance.getRun("r1")).status, "completed");
  assert.ok(tokens >= 2);
  await assert.rejects(instance.cancelRun("r2"), { code: "NOT_FOUND", status: 404 });
});

test("run ids are path-encoded and aborted requests reject with the abort reason", async (context) => {
  const { calls, fetch } = recorder();
  const instance = client(context, { fetch, capabilities: ["runs"] });
  await instance.getRun("a/b c");
  assert.ok(calls.some((entry) => entry.path === "/api/v1/runs/a%2Fb%20c"));
  const controller = new AbortController();
  controller.abort(new Error("stop"));
  await assert.rejects(instance.getRun("r1", { signal: controller.signal }), { message: "stop" });
});

// ---- append subscriptions (capability "append") ----

const acks = (socket) => socket.messages.filter((message) => message.event === "ack").map((message) => message.payload);
const refreshes = (socket) => socket.messages.filter((message) => message.event === "refresh");

async function appendSubscription(context, options = {}) {
  const instance = client(context, { capabilities: ["append"], ...options });
  const subscription = instance.subscribeAppend("feed.recent", { room: "r" });
  await until(() => subscription.getState().status === "ready");
  const socket = TestWebSocket.instances.at(-1);
  const state = subscription.getState();
  return { instance, subscription, socket, state, batch: (seq, base, cursor, items, generation = state.generation) =>
    ({ g: generation, s: seq, base_cursor: base, cursor, items }) };
}

test("append subscriptions need the capability and join the append channel", async (context) => {
  assert.throws(() => client(context).subscribeAppend("feed.recent", {}), { code: "UNSUPPORTED_CAPABILITY" });
  const { socket, state } = await appendSubscription(context);
  const join = socket.messages.find((message) => message.event === "phx_join");
  assert.ok(join.topic.startsWith("append:"));
  assert.deepEqual([join.payload.protocol_version, join.payload.capabilities, join.payload.name, "delivery" in join.payload],
    [1, { append: 1 }, "feed.recent", false]);
  assert.deepEqual([state.data, state.seq, state.cursor], [[], 1, "e:0"]);
  assert.deepEqual(acks(socket), [{ g: state.generation, s: 1, c: "e:0" }]);
});

test("batches that continue at the cursor are appended, evict beyond max_items and are acknowledged", async (context) => {
  const { subscription, socket, state, batch } = await appendSubscription(context);
  socket.append(batch(2, "e:0", "e:2", [{ text: "a" }, { text: "b" }]));
  socket.append(batch(3, "e:2", "e:4", [{ text: "c" }, { text: "d" }]));
  const after = subscription.getState();
  assert.deepEqual(after.data.map((item) => item.text), ["b", "c", "d"]);
  assert.deepEqual([after.seq, after.cursor, after.status], [3, "e:4", "ready"]);
  assert.ok(Object.isFrozen(after.data) && Object.isFrozen(after.data[0]));
  assert.deepEqual(acks(socket).slice(1), [{ g: state.generation, s: 2, c: "e:2" }, { g: state.generation, s: 3, c: "e:4" }]);
});

test("a repeated batch is never applied twice", async (context) => {
  const { subscription, socket, batch } = await appendSubscription(context);
  const first = batch(2, "e:0", "e:1", [{ text: "a" }]);
  socket.append(first);
  socket.append(first);
  assert.deepEqual(subscription.getState().data, [{ text: "a" }]);
  assert.equal(acks(socket).length, 2);
  assert.equal(refreshes(socket).length, 0);
});

test("a batch that does not continue at the cursor stops merging and asks for a snapshot", async (context) => {
  const { subscription, socket, state, batch } = await appendSubscription(context);
  socket.append(batch(2, "e:0", "e:1", [{ text: "a" }]));
  // Wrong base cursor (a batch was missed), then a well-formed one that must now be ignored.
  socket.append(batch(3, "e:5", "e:6", [{ text: "x" }]));
  socket.append(batch(4, "e:6", "e:7", [{ text: "y" }]));
  assert.deepEqual(subscription.getState().data, [{ text: "a" }]);
  assert.equal(subscription.getState().cursor, "e:1");
  assert.equal(refreshes(socket).length, 1);

  // The snapshot (same generation, higher seq) replaces the view and resumes merging.
  socket.snapshot([{ text: "fresh" }], { seq: 5, cursor: "e:9", mode: "append", max_items: 3 });
  assert.deepEqual([subscription.getState().data, subscription.getState().cursor, subscription.getState().seq],
    [[{ text: "fresh" }], "e:9", 5]);
  assert.deepEqual(acks(socket).at(-1), { g: state.generation, s: 5, c: "e:9" });
  socket.append(batch(6, "e:9", "e:10", [{ text: "next" }]));
  assert.deepEqual(subscription.getState().data.map((item) => item.text), ["fresh", "next"]);
  assert.equal(refreshes(socket).length, 1);
});

test("a skipped sequence number is a gap even when the cursors happen to line up", async (context) => {
  const { subscription, socket, batch } = await appendSubscription(context);
  socket.append(batch(3, "e:0", "e:1", [{ text: "a" }]));
  assert.deepEqual(subscription.getState().data, []);
  assert.equal(refreshes(socket).length, 1);
});

test("other generations are ignored, stale snapshots are dropped and malformed batches fail loudly", async (context) => {
  const { subscription, socket, batch } = await appendSubscription(context);
  socket.append(batch(2, "e:0", "e:1", [{ text: "a" }], "another-generation"));
  assert.deepEqual(subscription.getState().data, []);
  socket.snapshot([{ text: "old" }], { seq: 1, cursor: "e:0", mode: "append", max_items: 3 });
  assert.deepEqual(subscription.getState().data, []);
  socket.append({ g: subscription.getState().generation, s: 2, base_cursor: 5, cursor: "e:1", items: [] });
  assert.equal(subscription.getState().status, "error");
  assert.equal(subscription.getState().error.code, "PROTOCOL_ERROR");
});

test("invalid append snapshots are protocol errors", async (context) => {
  const { subscription, socket } = await appendSubscription(context);
  socket.snapshot("not an array", { seq: 2, cursor: "e:1", mode: "append", max_items: 3 });
  assert.equal(subscription.getState().error.code, "PROTOCOL_ERROR");
});

test("after a reconnect the subscription starts again from the server's snapshot", async (context) => {
  const { subscription, socket, batch } = await appendSubscription(context);
  socket.append(batch(2, "e:0", "e:1", [{ text: "a" }]));
  socket.interrupt();
  await until(() => TestWebSocket.instances.at(-1) !== socket && subscription.getState().status === "ready");
  assert.deepEqual([subscription.getState().data, subscription.getState().seq, subscription.getState().cursor], [[], 1, "e:0"]);
  const next = TestWebSocket.instances.at(-1);
  next.append({ g: subscription.getState().generation, s: 2, base_cursor: "e:0", cursor: "e:1", items: [{ text: "b" }] });
  assert.deepEqual(subscription.getState().data, [{ text: "b" }]);
});

test("refresh on an append subscription asks the server for a snapshot", async (context) => {
  const { subscription, socket } = await appendSubscription(context);
  await subscription.refresh();
  assert.equal(refreshes(socket).length, 1);
});

// ---- presence rooms (capability "presence") ----

const metaOf = (ref, data = {}) => ({ ref, data, joined_at: "2026-11-07T00:00:00Z" });
const presenceMessages = (socket, event) => socket.messages.filter((message) => message.event === event);

async function presenceRoom(context, meta, options = {}) {
  const instance = client(context, { capabilities: ["presence"], ...options });
  const room = instance.subscribePresence("room.presence", { room: "r" }, meta);
  await until(() => room.getState().status === "ready");
  return { instance, room, socket: TestWebSocket.instances.at(-1) };
}

test("presence needs the capability, joins presence:<id> with its meta and exposes the roster", async (context) => {
  assert.throws(() => client(context).subscribePresence("room.presence", {}), { code: "UNSUPPORTED_CAPABILITY" });
  const { room, socket } = await presenceRoom(context, { typing: false });
  const join = presenceMessages(socket, "phx_join")[0];
  assert.ok(join.topic.startsWith("presence:"));
  assert.deepEqual([join.payload.protocol_version, join.payload.capabilities, join.payload.name, join.payload.params, join.payload.meta, "delivery" in join.payload],
    [1, { presence: 1 }, "room.presence", { room: "r" }, { typing: false }, false]);
  assert.deepEqual(Object.keys(room.getState().data), ["alice"]);
  assert.equal(room.self(), "alice");
  assert.equal(Object.isFrozen(room.getState().data), true);
});

test("diffs are applied by ref: joins add, leaves remove, repeats change nothing, empty keys disappear", async (context) => {
  const { room, socket } = await presenceRoom(context, {});
  const changes = [];
  room.onChange((state) => changes.push(state.seq));
  const first = room.getState().data.alice[0];

  socket.presenceDiff({ joins: { bob: [metaOf("b1", { typing: true })] }, leaves: {} });
  assert.deepEqual(room.getState().data.bob, [metaOf("b1", { typing: true })]);

  socket.presenceDiff({ joins: { bob: [metaOf("b1", { typing: true })] }, leaves: {} });
  assert.equal(room.getState().data.bob.length, 1);

  // A second device of the same person is a second entry under the same key.
  socket.presenceDiff({ joins: { bob: [metaOf("b2")] }, leaves: {} });
  assert.deepEqual(room.getState().data.bob.map((meta) => meta.ref), ["b1", "b2"]);

  // An update arrives as the old ref leaving and a new one joining.
  socket.presenceDiff({ joins: { bob: [metaOf("b3", { typing: false })] }, leaves: { bob: [metaOf("b1")] } });
  assert.deepEqual(room.getState().data.bob.map((meta) => meta.ref), ["b2", "b3"]);

  socket.presenceDiff({ joins: {}, leaves: { bob: [metaOf("b2"), metaOf("b3")] } });
  assert.equal("bob" in room.getState().data, false);
  assert.deepEqual(room.getState().data.alice, [first]);
  assert.ok(changes.length >= 4);
});

test("update sends the new meta, is refused before the room is ready, and surfaces server errors", async (context) => {
  const instance = client(context, { capabilities: ["presence"] });
  const room = instance.subscribePresence("room.presence", { room: "r" });
  await assert.rejects(room.update({ typing: true }), { code: "NOT_READY" });
  await until(() => room.getState().status === "ready");
  const socket = TestWebSocket.instances.at(-1);

  await room.update({ typing: true });
  assert.deepEqual(presenceMessages(socket, "update").at(-1).payload, { meta: { typing: true } });

  const send = socket.send.bind(socket);
  socket.send = (raw) => {
    const [joinRef, ref, topic, event] = JSON.parse(raw);
    if (event !== "update") return send(raw);
    queueMicrotask(() => socket.emit([joinRef, ref, topic, "phx_reply",
      { status: "error", response: { error: { code: "LIMIT_EXCEEDED", message: "too frequent", details: {}, retryable: true } } }]));
  };
  await assert.rejects(room.update({ typing: false }), { code: "LIMIT_EXCEEDED", retryable: true });
});

test("after a reconnect the room is joined again with the latest meta and the roster is replaced", async (context) => {
  const { room, socket } = await presenceRoom(context, { typing: false });
  socket.presenceDiff({ joins: { ghost: [metaOf("g1")] }, leaves: {} });
  assert.ok("ghost" in room.getState().data);
  await room.update({ typing: true });

  socket.interrupt();
  await until(() => TestWebSocket.instances.length > 1 && room.getState().status === "ready" && !("ghost" in room.getState().data));
  const rejoin = presenceMessages(TestWebSocket.instances.at(-1), "phx_join").find((message) => message.topic.startsWith("presence:"));
  assert.deepEqual(rejoin.payload.meta, { typing: true });
  assert.deepEqual(room.getState().data.alice[0].data, { typing: true });
});

test("malformed presence payloads fail the subscription instead of corrupting the roster", async (context) => {
  for (const bad of [{ joins: "x", leaves: {} }, { joins: { bob: "x" }, leaves: {} }, { joins: { bob: [{ data: {} }] }, leaves: {} }, { leaves: {} }]) {
    const { room, socket } = await presenceRoom(context, {});
    socket.presenceDiff(bad);
    assert.equal(room.getState().status, "error");
    assert.equal(room.getState().error.code, "PROTOCOL_ERROR");
  }
});

test("unsubscribing leaves the presence channel", async (context) => {
  const { room, socket } = await presenceRoom(context, {});
  room.unsubscribe();
  await until(() => presenceMessages(socket, "phx_leave").length === 1);
  assert.equal(room.getState().status, "closed");
});

// ---- optimistic writes (CallOptions.optimistic) ----

// Writes that stay in flight until the test completes them, so each moment can be inspected.
function heldWrites(context, options = {}) {
  const writes = [];
  const fetch = async (url) => {
    if (url.endsWith("/identity")) return response(identity);
    return await new Promise((resolve) => writes.push(resolve));
  };
  const instance = client(context, { fetch, ...options });
  return {
    instance,
    // The request is sent after the token resolves, so wait for it to be in flight.
    succeed: async (index = 0, data = { id: "saved" }) => { await until(() => writes[index]); writes[index](response(data)); },
    fail: async (index = 0) => { await until(() => writes[index]); writes[index](response({ code: "CONFLICT", message: "no", details: {}, retryable: false }, 409)); },
  };
}

async function readySubscription(instance, name = "inbox.recent") {
  const subscription = instance.subscribe(name, {});
  await until(() => subscription.getState().status === "ready");
  return { subscription, socket: TestWebSocket.instances.at(-1) };
}

// Idempotent: the same call run on data that already holds the record changes nothing.
const addX = (items) => (items.includes("x") ? items : [...items, "x"]);

test("a prediction is shown at once, kept after success, and replaced when the server next sends data", async (context) => {
  const { instance, succeed } = heldWrites(context);
  const { subscription, socket } = await readySubscription(instance);
  const seen = [];
  subscription.onChange((state) => seen.push([state.data, state.pending]));

  const call = instance.call("inbox.add", { text: "x" }, { optimistic: [{ subscription, update: addX }] });
  assert.deepEqual([subscription.getState().data, subscription.getState().pending], [["initial", "x"], 1]);
  assert.equal(Object.isFrozen(subscription.getState().data), true);

  await succeed();
  await call;
  // Settled but not yet confirmed: still shown, until the server speaks.
  assert.deepEqual(subscription.getState().data, ["initial", "x"]);

  socket.snapshot(["initial", "x", "from-server"]);
  assert.deepEqual([subscription.getState().data, subscription.getState().pending], [["initial", "x", "from-server"], undefined]);
  assert.deepEqual(seen.at(0), [["initial"], undefined]); // the replayed current state
  assert.deepEqual(seen.at(1), [["initial", "x"], 1]);
  assert.deepEqual(seen.at(-1), [["initial", "x", "from-server"], undefined]);
});

test("a failed write undoes its prediction immediately and still rejects with the server's error", async (context) => {
  const { instance, fail } = heldWrites(context);
  const { subscription } = await readySubscription(instance);
  const call = instance.call("inbox.add", { text: "x" }, { optimistic: [{ subscription, update: addX }] });
  assert.deepEqual(subscription.getState().data, ["initial", "x"]);
  await fail();
  await assert.rejects(call, { code: "CONFLICT" });
  assert.deepEqual([subscription.getState().data, subscription.getState().pending], [["initial"], undefined]);
});

test("server data arriving while the write is in flight keeps the prediction on top of the new base", async (context) => {
  const { instance, succeed } = heldWrites(context);
  const { subscription, socket } = await readySubscription(instance);
  const call = instance.call("inbox.add", { text: "x" }, { optimistic: [{ subscription, update: addX }] });

  socket.snapshot(["initial", "other"]);
  assert.deepEqual(subscription.getState().data, ["initial", "other", "x"]);

  // The server's copy of the write arrived first: applying the idempotent prediction again changes nothing.
  socket.snapshot(["initial", "other", "x"], { seq: 3 });
  assert.deepEqual(subscription.getState().data, ["initial", "other", "x"]);

  await succeed();
  await call;
  socket.snapshot(["initial", "other", "x", "later"], { seq: 4 });
  assert.deepEqual([subscription.getState().data, subscription.getState().pending], [["initial", "other", "x", "later"], undefined]);
});

test("a settled prediction ends by itself after optimisticTtlMs when the server sends nothing", async (context) => {
  const { instance, succeed } = heldWrites(context, { optimisticTtlMs: 40 });
  const { subscription } = await readySubscription(instance);
  const call = instance.call("inbox.add", { text: "x" }, { optimistic: [{ subscription, update: addX }] });
  await succeed();
  await call;
  assert.deepEqual(subscription.getState().data, ["initial", "x"]);
  await until(() => subscription.getState().pending === undefined);
  assert.deepEqual(subscription.getState().data, ["initial"]);
});

test("one call can predict several subscriptions, and predictions are applied in order", async (context) => {
  const { instance, succeed } = heldWrites(context);
  const { subscription: first } = await readySubscription(instance, "inbox.recent");
  const { subscription: second } = await readySubscription(instance, "inbox.history");
  const call = instance.call("inbox.add", {}, { optimistic: [
    { subscription: first, update: (items) => [...items, "a"] },
    { subscription: second, update: (items) => [...items, "b"] },
    { subscription: first, update: (items) => items.map((item) => item.toUpperCase()) },
  ] });
  assert.deepEqual([first.getState().data, first.getState().pending], [["INITIAL", "A"], 2]);
  assert.deepEqual(second.getState().data, ["initial", "b"]);
  await succeed();
  await call;
});

test("only open subscriptions with data from this client can be predicted, and nothing is applied if one is not", async (context) => {
  const { instance } = heldWrites(context);
  const { subscription } = await readySubscription(instance);
  const stranger = createClient({ endpoint: "http://localhost:4000", projectId: "project", getToken: () => "rts_test",
    fetch: async () => response(identity), WebSocket: TestWebSocket });
  context.after(() => stranger.close());
  const foreign = stranger.subscribe("inbox.recent", {});

  await assert.rejects(instance.call("inbox.add", {}, { optimistic: [{ subscription, update: addX }, { subscription: foreign, update: addX }] }), TypeError);
  assert.equal(subscription.getState().pending, undefined);

  // A subscription that has no data yet is simply not predicted.
  const waiting = instance.subscribe("inbox.recent", {});
  assert.equal(waiting.getState().data, undefined);
  subscription.unsubscribe();
  await assert.rejects(instance.call("inbox.add", {}, { optimistic: [{ subscription, update: addX }] }), TypeError);
});

test("a prediction that throws is dropped and reported, and the call still completes", async (context) => {
  const errors = [];
  const { instance, succeed } = heldWrites(context, { onListenerError: (error) => errors.push(error) });
  const { subscription } = await readySubscription(instance);
  const call = instance.call("inbox.add", {}, { optimistic: [{ subscription, update: () => { throw new Error("bad prediction"); } }] });
  assert.deepEqual([subscription.getState().data, subscription.getState().pending], [["initial"], undefined]);
  assert.equal(errors.length >= 1 && errors[0].message, "bad prediction");
  await succeed();
  assert.deepEqual(await call, { id: "saved" });
});

test("unsubscribing while a prediction is pending leaves nothing behind", async (context) => {
  const { instance, succeed } = heldWrites(context, { optimisticTtlMs: 20 });
  const { subscription } = await readySubscription(instance);
  const call = instance.call("inbox.add", {}, { optimistic: [{ subscription, update: addX }] });
  subscription.unsubscribe();
  assert.equal(subscription.getState().status, "closed");
  assert.equal(subscription.getState().data, undefined);
  await succeed();
  await call;
  await delay(60);
  assert.equal(subscription.getState().pending, undefined);
});

test("calls without optimistic updates are unchanged", async (context) => {
  const { instance, succeed } = heldWrites(context);
  const { subscription } = await readySubscription(instance);
  const call = instance.call("inbox.add", {});
  assert.equal(subscription.getState().pending, undefined);
  await succeed();
  assert.deepEqual(await call, { id: "saved" });
});

// ---- join errors ----

const unavailable = { code: "INTERNAL_ERROR", message: "The observer is unavailable", details: {}, retryable: true };

// Answers the first `failures` joins of subscription topics with `error`, then behaves normally.
function failingJoins(failures, error) {
  return class extends TestWebSocket {
    static joinAttempts = 0;
    send(raw) {
      const [joinRef, ref, topic, event] = JSON.parse(raw);
      if (event === "phx_join" && topic.startsWith("subscription:") && this.constructor.joinAttempts++ < failures) {
        queueMicrotask(() => this.emit([joinRef, ref, topic, "phx_reply", { status: "error", response: { error } }]));
        return;
      }
      super.send(raw);
    }
  };
}

test("a retryable join error recovers on its own instead of failing the subscription", async (context) => {
  const Socket = failingJoins(2, unavailable);
  const before = TestWebSocket.instances.length;
  const instance = client(context, { WebSocket: Socket });
  const subscription = instance.subscribe("inbox.recent", {});
  const statuses = [];
  subscription.onChange((state) => statuses.push(state.status));

  await until(() => subscription.getState().status === "ready");
  assert.equal(Socket.joinAttempts, 3); // two refused, the third accepted
  // One connection throughout: the retries did not tear the socket down.
  assert.equal(TestWebSocket.instances.length - before, 1);
  assert.equal(statuses.includes("error"), false);
  assert.ok(statuses.includes("recovering"));
  assert.deepEqual(subscription.getState().data, ["initial"]);
  assert.equal(subscription.getState().error, undefined);
});

test("a join error that is not retryable still fails the subscription at once", async (context) => {
  const Socket = failingJoins(5, { code: "FORBIDDEN", message: "No", details: {}, retryable: false });
  const instance = client(context, { WebSocket: Socket });
  const subscription = instance.subscribe("inbox.recent", {});
  await until(() => subscription.getState().status === "error");
  assert.equal(subscription.getState().error.code, "FORBIDDEN");
  assert.equal(Socket.joinAttempts, 1);
});

test("a join error that stays retryable is reported after a bounded number of attempts", async (context) => {
  const Socket = failingJoins(1_000, unavailable);
  const instance = client(context, { WebSocket: Socket });
  const subscription = instance.subscribe("inbox.recent", {});
  await until(() => subscription.getState().status === "error", 10_000);
  assert.equal(subscription.getState().error.code, "INTERNAL_ERROR");
  assert.equal(Socket.joinAttempts, 11); // the first try and ten retries
});

test("other subscriptions on the connection are not disturbed by one that is retrying its join", async (context) => {
  const Socket = failingJoins(1, unavailable);
  const instance = client(context, { WebSocket: Socket });
  const flaky = instance.subscribe("inbox.recent", {});
  await until(() => flaky.getState().status === "ready");
  const steady = instance.subscribe("inbox.history", {});
  await until(() => steady.getState().status === "ready");
  assert.equal(steady.getState().seq, 1);
  assert.equal(flaky.getState().status, "ready");
});
