import test from "node:test";
import assert from "node:assert/strict";
import { createClient, ApiError, OutcomeUnknownError } from "../../dist/index.js";
import { response, TestWebSocket, until } from "../helpers.mjs";
import { awaitAbortable } from "../../dist/requests.js";
import { getEventListeners } from "node:events";

const identity = { project_id: "project", subject_id: "alice" };
const unauthorized = { code: "UNAUTHENTICATED", message: "Expired", retryable: false };

function client(context, options = {}) {
  const instance = createClient({
    endpoint: "http://localhost:4000", projectId: "project", getToken: () => "rts_test",
    fetch: async () => response(identity), WebSocket: TestWebSocket, ...options,
  });
  context.after(() => instance.close());
  return instance;
}

function deferred() {
  return Promise.withResolvers();
}

for (const transport of ["http", "socket"]) {
  test(`a forbidden ${transport} operation leaves authorized subscriptions usable`, async (context) => {
    const forbidden = { code: "FORBIDDEN", message: "This operation is forbidden" };
    class ForbiddenSocket extends TestWebSocket {
      send(raw) {
        const [joinRef, ref, topic, event] = JSON.parse(raw);
        if (event !== "call") return super.send(raw);
        queueMicrotask(() => this.emit([joinRef, ref, topic, "phx_reply", {
          status: "error", response: { status: 403, error: forbidden },
        }]));
      }
    }
    const instance = client(context, {
      operationTransport: transport, WebSocket: ForbiddenSocket,
      fetch: async (url) => url.endsWith("/identity") ? response(identity) : response(forbidden, 403),
    });
    const first = instance.subscribe("records.recent", {});
    const second = instance.subscribe("records.other", {});
    await until(() => first.getState().status === "ready" && second.getState().status === "ready");
    await assert.rejects(instance.call("admin.only", {}), { code: "FORBIDDEN" });
    assert.equal(first.getState().status, "ready");
    assert.equal(second.getState().status, "ready");
    TestWebSocket.instances.at(-1).snapshot(["still authorized"]);
    assert.deepEqual(first.getState().data, ["still authorized"]);
  });
}

test("a refreshed identity mismatch still clears every subscription", async (context) => {
  let changed = false;
  const instance = client(context, {
    fetch: async (url) => url.endsWith("/identity")
      ? response(changed ? { ...identity, subject_id: "bob" } : identity)
      : response(unauthorized, 401),
  });
  const subscription = instance.subscribe("records.recent", {});
  await until(() => subscription.getState().status === "ready");
  changed = true;
  await assert.rejects(instance.call("records.add", {}), { code: "FORBIDDEN" });
  assert.equal(subscription.getState().status, "error");
  assert.equal(subscription.getState().data, undefined);
});

test("an already aborted wait consumes a later rejection without an unhandled promise", async () => {
  const pending = deferred();
  const reason = new Error("cancelled");
  await assert.rejects(awaitAbortable(pending.promise, AbortSignal.abort(reason)), (error) => error === reason);
  pending.reject(new Error("late failure"));
  await new Promise((resolve) => setImmediate(resolve));
});

test("cancelling an unresolved wait releases its abort listener immediately", async () => {
  const controller = new AbortController();
  const pending = awaitAbortable(new Promise(() => {}), controller.signal);
  assert.equal(getEventListeners(controller.signal, "abort").length, 1);
  controller.abort();
  await assert.rejects(pending, { name: "AbortError" });
  assert.equal(getEventListeners(controller.signal, "abort").length, 0);
});

test("aborting one request leaves its sibling's shared authorization usable", async (context) => {
  const token = deferred();
  const started = deferred();
  const calls = [];
  let tokens = 0;
  const instance = client(context, {
    getToken: () => { tokens++; started.resolve(); return token.promise; },
    fetch: async (url, init) => {
      if (url.endsWith("/identity")) return response(identity);
      calls.push(JSON.parse(init.body).input);
      return response("saved");
    },
  });
  const controller = new AbortController();
  const aborted = instance.call("records.add", { text: "aborted" }, { signal: controller.signal });
  const sibling = instance.call("records.add", { text: "saved" });
  const rejected = assert.rejects(aborted, { name: "AbortError" });
  await started.promise;
  controller.abort();
  await rejected;
  token.resolve("rts_test");
  assert.equal(await sibling, "saved");
  assert.equal(tokens, 1);
  assert.deepEqual(calls, [{ text: "saved" }]);
});

test("preaborted calls preserve the abort reason and never send a write", async (context) => {
  let writes = 0;
  const instance = client(context, {
    fetch: async (url) => {
      if (!url.endsWith("/identity")) writes++;
      return response(identity);
    },
  });
  const reason = new Error("cancelled by caller");
  await assert.rejects(instance.call("records.add", {}, { signal: AbortSignal.abort(reason) }), (error) => error === reason);
  assert.equal(writes, 0);
});

test("closing a client aborts every active HTTP request with no replay", async (context) => {
  const started = deferred();
  const signals = [];
  const instance = client(context, {
    fetch: async (url, init) => {
      if (url.endsWith("/identity")) return response(identity);
      signals.push(init.signal);
      if (signals.length === 3) started.resolve();
      return new Promise((resolve, reject) => {
        init.signal.addEventListener("abort", () => reject(init.signal.reason), { once: true });
      });
    },
  });
  const pending = Array.from({ length: 3 }, () => instance.call("records.add", {}));
  const rejected = pending.map((promise) => assert.rejects(promise,
    (error) => error instanceof OutcomeUnknownError && error.cause.name === "AbortError"));
  await started.promise;
  instance.close();
  await Promise.all(rejected);
  assert.equal(signals.length, 3);
  assert.ok(signals.every((signal) => signal.aborted));
  await assert.rejects(instance.call("records.add", {}), { code: "CLIENT_CLOSED" });
});

test("abort during a forced token refresh prevents replay while a sibling can finish", async (context) => {
  const refresh = deferred();
  const refreshing = deferred();
  const writes = [];
  let refreshes = 0;
  const instance = client(context, {
    getToken: ({ forceRefresh }) => {
      if (!forceRefresh) return "rts_old";
      refreshes++;
      refreshing.resolve();
      return refresh.promise;
    },
    fetch: async (url, init) => {
      if (url.endsWith("/identity")) return response(identity);
      const input = JSON.parse(init.body).input;
      writes.push([input.text, init.headers.authorization]);
      return init.headers.authorization === "Bearer rts_old" ? response(unauthorized, 401) : response(input.text);
    },
  });
  const controller = new AbortController();
  const aborted = instance.call("records.add", { text: "abort" }, { signal: controller.signal });
  const sibling = instance.call("records.add", { text: "keep" });
  const rejected = assert.rejects(aborted, { name: "AbortError" });
  await refreshing.promise;
  controller.abort();
  await rejected;
  refresh.resolve("rts_fresh");
  assert.equal(await sibling, "keep");
  assert.equal(refreshes, 1);
  assert.deepEqual(writes, [["abort", "Bearer rts_old"], ["keep", "Bearer rts_old"], ["keep", "Bearer rts_fresh"]]);
});

test("one deadline covers the initial attempt and token refresh", async (context) => {
  context.mock.timers.enable({ apis: ["setTimeout"] });
  const attempted = deferred();
  const first = deferred();
  const refreshing = deferred();
  const refresh = deferred();
  let writes = 0;
  const instance = client(context, {
    timeoutMs: 100,
    getToken: ({ forceRefresh }) => {
      if (!forceRefresh) return "rts_old";
      refreshing.resolve();
      return refresh.promise;
    },
    fetch: async (url) => {
      if (url.endsWith("/identity")) return response(identity);
      writes++;
      attempted.resolve();
      return writes === 1 ? first.promise : response("saved");
    },
  });
  const pending = instance.call("records.add", {});
  const rejected = assert.rejects(pending, (error) => error instanceof ApiError && error.code === "TIMEOUT" && error.retryable);
  await attempted.promise;
  context.mock.timers.tick(60);
  first.resolve(response(unauthorized, 401));
  await refreshing.promise;
  context.mock.timers.tick(40);
  await rejected;
  refresh.resolve("rts_fresh");
  assert.equal(await instance.call("records.list", {}), "saved");
  assert.equal(writes, 2);
});

test("successful calls dispose their deadlines and external abort listeners", async (context) => {
  context.mock.timers.enable({ apis: ["setTimeout"] });
  let signal;
  const instance = client(context, {
    timeoutMs: 100,
    fetch: async (url, init) => {
      if (url.endsWith("/identity")) return response(identity);
      signal = init.signal;
      return response("saved");
    },
  });
  const external = new AbortController();
  assert.equal(await instance.call("records.add", {}, { signal: external.signal }), "saved");
  external.abort();
  context.mock.timers.tick(1000);
  assert.equal(signal.aborted, false);
});

test("a rejected token provider does not poison a later authorization attempt", async (context) => {
  const failure = new Error("temporary token failure");
  let tokens = 0;
  let writes = 0;
  const instance = client(context, {
    getToken: () => { if (++tokens === 1) throw failure; return "rts_test"; },
    fetch: async (url) => {
      if (url.endsWith("/identity")) return response(identity);
      writes++;
      return response("saved");
    },
  });
  await assert.rejects(instance.call("records.add", {}), (error) => error === failure);
  assert.equal(await instance.call("records.add", {}), "saved");
  assert.equal(tokens, 2);
  assert.equal(writes, 1);
});

for (const [method, path, invoke, expectedBody] of [
  ["GET", "/api/v1/runs/run%2Fone", (instance) => instance.getRun("run/one"), undefined],
  ["POST", "/api/v1/runs/run%2Fone/signals", (instance) => instance.signalRun("run/one", { name: "approve", input: { ok: true } }), { name: "approve", input: { ok: true }, idempotency_key: "generated-key" }],
  ["POST", "/api/v1/runs/run%2Fone/cancel", (instance) => instance.cancelRun("run/one"), {}],
]) {
  test(`run ${method} ${path} refreshes once without changing the request`, async (context) => {
    const attempts = [];
    const refreshes = [];
    const instance = client(context, {
      capabilities: ["runs"], createId: () => "generated-key",
      getToken: ({ forceRefresh }) => { refreshes.push(forceRefresh); return forceRefresh ? "rts_fresh" : "rts_old"; },
      fetch: async (url, init) => {
        if (url.endsWith("/identity")) return response(identity);
        attempts.push({ path: new URL(url).pathname, method: init.method, body: init.body, token: init.headers.authorization });
        return attempts.length === 1 ? response(unauthorized, 401) : response({ accepted: true });
      },
    });
    assert.deepEqual(await invoke(instance), { accepted: true });
    assert.deepEqual(refreshes, [false, true]);
    assert.deepEqual(attempts.map(({ path, method, body }) => ({ path, method, body })),
      Array(2).fill({ path, method, body: expectedBody === undefined ? undefined : JSON.stringify(expectedBody) }));
    assert.deepEqual(attempts.map(({ token }) => token), ["Bearer rts_old", "Bearer rts_fresh"]);
  });
}

for (const [code, status] of [["CONFLICT", 409], ["VALIDATION_FAILED", 422], ["UNSUPPORTED_CAPABILITY", 400]]) {
  test(`${code} is not retried and does not disrupt live subscriptions`, async (context) => {
    const tokens = [];
    let writes = 0;
    const instance = client(context, {
      getToken: ({ forceRefresh }) => { tokens.push(forceRefresh); return "rts_test"; },
      fetch: async (url) => {
        if (url.endsWith("/identity")) return response(identity);
        writes++;
        return response({ code, message: "Rejected", retryable: false }, status);
      },
    });
    const subscription = instance.subscribe("records.recent", {});
    await until(() => subscription.getState().status === "ready");
    await assert.rejects(instance.call("records.add", {}), { code, status });
    assert.deepEqual(tokens, [false]);
    assert.equal(writes, 1);
    assert.equal(subscription.getState().status, "ready");
    TestWebSocket.instances.at(-1).snapshot(["still live"]);
    assert.deepEqual(subscription.getState().data, ["still live"]);
  });
}
