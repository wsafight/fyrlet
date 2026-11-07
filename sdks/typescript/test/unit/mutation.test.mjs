import test from "node:test";
import assert from "node:assert/strict";
import { createClient, OutcomeUnknownError } from "../../dist/index.js";
import { response, TestWebSocket, until } from "../helpers.mjs";

const identity = { project_id: "project", subject_id: "alice" };

for (const [label, receipt] of [
  ["a completed read", { outcome: "completed", data: "read result" }],
  ["an unknown outcome with data", { outcome: "unknown", data: { id: "one" } }],
  ["a receipt without an outcome", { data: { id: "one" } }],
  ["a receipt without data", { outcome: "committed" }],
]) {
  test(`recovery rejects ${label}, preserves uncertainty and allows a later valid lookup`, async (context) => {
    let lookups = 0;
    let writes = 0;
    const keys = [];
    const instance = client(context, {
      fetch: async (url, init) => {
        if (url.endsWith("/identity")) return response(identity);
        keys.push(init.headers["idempotency-key"]);
        if (!url.endsWith("/recover")) { writes++; throw new Error("response lost"); }
        return ++lookups === 1 ? new Response(JSON.stringify(receipt)) : response({ id: "one" });
      },
    });
    const mutation = instance.mutate("records.add", {}, { idempotencyKey: "durable-key" });
    await assert.rejects(mutation.result, OutcomeUnknownError);
    const unknown = mutation.getState();
    await assert.rejects(mutation.recover(), { code: "PROTOCOL_ERROR" });
    assert.equal(mutation.getState(), unknown);
    assert.deepEqual(await mutation.recover(), { status: "committed", data: { id: "one" } });
    assert.equal(writes, 1);
    assert.equal(lookups, 2);
    assert.deepEqual(keys, ["durable-key", "durable-key", "durable-key"]);
  });
}

test("recovery of an accepted run publishes the original run identifier without another write", async (context) => {
  let writes = 0;
  const instance = client(context, {
    fetch: async (url) => {
      if (url.endsWith("/identity")) return response(identity);
      if (!url.endsWith("/recover")) { writes++; throw new Error("accepted response lost"); }
      return response({ run_id: "accepted-run" }, 200, "accepted");
    },
  });
  const mutation = instance.mutate("runs.start", {});
  await assert.rejects(mutation.result, OutcomeUnknownError);
  const recovered = await mutation.recover();
  assert.deepEqual(recovered, { status: "accepted", data: { run_id: "accepted-run" } });
  assert.equal(mutation.getState(), recovered);
  assert.equal(await mutation.recover(), recovered);
  assert.equal(writes, 1);
});

function client(context, options = {}) {
  const instance = createClient({
    endpoint: "http://localhost:4000", projectId: "project", getToken: () => "rts_test",
    fetch: async (url) => response(url.endsWith("/identity") ? identity : "saved"),
    WebSocket: TestWebSocket, ...options,
  });
  context.after(() => instance.close());
  return instance;
}

for (const outcome of ["completed", "committed", "accepted"]) {
  test(`mutation publishes pending then ${outcome} and preserves the business result`, async (context) => {
    const instance = client(context, {
      fetch: async (url) => url.endsWith("/identity") ? response(identity) : response({ id: "one" }, 200, outcome),
    });
    const mutation = instance.mutate("records.add", {});
    const states = [];
    const stop = mutation.onChange((state) => states.push(state));
    assert.equal(mutation.getState(), states[0]);
    assert.deepEqual(await mutation.result, { id: "one" });
    assert.deepEqual(states.map((state) => state.status), ["pending", outcome]);
    assert.equal(mutation.getState(), states[1]);
    assert.ok(Object.isFrozen(states[1]));
    assert.equal(await mutation.recover(), states[1]);
    stop();
    assert.deepEqual(await instance.call("records.add", {}), { id: "one" });
  });
}

test("failure before dispatch preserves the cause and sends no operation", async (context) => {
  const token = Promise.withResolvers();
  let writes = 0;
  const instance = client(context, {
    getToken: () => token.promise,
    fetch: async (url) => { if (!url.endsWith("/identity")) writes++; return response(identity); },
  });
  const abort = new AbortController();
  const mutation = instance.mutate("records.add", {}, { signal: abort.signal });
  const reason = new Error("cancel before dispatch");
  abort.abort(reason);
  await assert.rejects(mutation.result, (error) => error === reason);
  assert.equal(mutation.getState().status, "failed");
  assert.equal(await mutation.recover(), mutation.getState());
  token.resolve("rts_test");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(writes, 0);
});

for (const [status, code] of [[401, "UNAUTHENTICATED"], [403, "FORBIDDEN"], [409, "CONFLICT"], [422, "VALIDATION_FAILED"], [429, "LIMIT_EXCEEDED"]]) {
  test(`a structured ${status} rejection is a definite failure`, async (context) => {
    const instance = client(context, {
      fetch: async (url) => url.endsWith("/identity") ? response(identity) : response({ code, message: "rejected" }, status),
    });
    const mutation = instance.mutate("records.add", {});
    await assert.rejects(mutation.result, (error) => error.code === code && !(error instanceof OutcomeUnknownError));
    assert.equal(mutation.getState().status, "failed");
  });
}

for (const [label, perform] of [
  ["network loss", () => { throw new TypeError("connection lost"); }],
  ["internal error", () => response({ code: "INTERNAL_ERROR", message: "failed" }, 500)],
  ["malformed JSON", () => new Response("{", { status: 200 })],
  ["missing outcome", () => new Response(JSON.stringify({ data: "saved" }))],
  ["invalid outcome", () => response("saved", 200, "done")],
  ["malformed error", () => new Response(JSON.stringify({ error: { code: 1 } }), { status: 403 })],
  ["unstructured HTTP error", () => new Response("{}", { status: 408 })],
]) {
  test(`${label} after dispatch preserves an unknown outcome and its key`, async (context) => {
    let writes = 0;
    const instance = client(context, {
      createId: () => "stable-key",
      fetch: async (url) => { if (url.endsWith("/identity")) return response(identity); writes++; return perform(); },
    });
    const mutation = instance.mutate("records.add", {});
    await assert.rejects(mutation.result, (error) => error instanceof OutcomeUnknownError &&
      error.idempotencyKey === "stable-key" && error.operation === "records.add" && !error.retryable);
    assert.equal(mutation.idempotencyKey, "stable-key");
    assert.equal(mutation.getState().status, "unknown");
    assert.equal(writes, 1);
  });
}

test("cancellation after dispatch stays unknown even if the fetch implementation ignores abort", async (context) => {
  const sent = Promise.withResolvers();
  const instance = client(context, {
    fetch: async (url) => {
      if (url.endsWith("/identity")) return response(identity);
      sent.resolve();
      return new Promise(() => {});
    },
  });
  const abort = new AbortController();
  const mutation = instance.mutate("records.add", {}, { signal: abort.signal });
  await sent.promise;
  const reason = new Error("stop waiting");
  abort.abort(reason);
  await assert.rejects(mutation.result, (error) => error instanceof OutcomeUnknownError && error.cause === reason);
  assert.equal(mutation.getState().status, "unknown");
});

test("the deadline includes reading a stalled response body", async (context) => {
  const instance = client(context, {
    timeoutMs: 30,
    fetch: async (url) => url.endsWith("/identity") ? response(identity) : {
      ok: true, status: 200, json: () => new Promise(() => {}),
    },
  });
  const mutation = instance.mutate("records.add", {});
  await assert.rejects(mutation.result, (error) => error instanceof OutcomeUnknownError && error.code === "TIMEOUT");
  assert.equal(mutation.getState().status, "unknown");
});

test("recovery freezes the original input, retains the key, and never replays a write", async (context) => {
  const token = Promise.withResolvers();
  const requests = [];
  const controller = new AbortController();
  const instance = client(context, {
    getToken: () => token.promise,
    fetch: async (url, init) => {
      if (url.endsWith("/identity")) return response(identity);
      requests.push({ url, input: JSON.parse(init.body).input, key: init.headers["idempotency-key"] });
      if (!url.endsWith("/recover")) throw new Error("lost response after commit");
      return response({ id: "one", text: "original" });
    },
  });
  const input = { text: "original" };
  const mutation = instance.mutate("records.add", input, { idempotencyKey: "mine", signal: controller.signal });
  input.text = "changed";
  token.resolve("rts_test");
  await assert.rejects(mutation.result, OutcomeUnknownError);
  controller.abort();
  const recovered = await mutation.recover();
  assert.deepEqual(recovered, { status: "committed", data: { id: "one", text: "original" } });
  assert.deepEqual(requests.map(({ input, key }) => ({ input, key })), Array(2).fill({ input: { text: "original" }, key: "mine" }));
  assert.ok(requests[1].url.endsWith("/recover"));
  assert.equal(await mutation.recover(), recovered);
  assert.equal(requests.length, 2);
});

test("an absent receipt stays unknown, concurrent recovery shares one request, and recovery errors preserve uncertainty", async (context) => {
  const answer = Promise.withResolvers();
  let reads = 0;
  const instance = client(context, {
    fetch: async (url) => {
      if (url.endsWith("/identity")) return response(identity);
      if (!url.endsWith("/recover")) throw new Error("lost response");
      reads++;
      return reads === 1 ? answer.promise : response({ code: "FORBIDDEN", message: "revoked" }, 403);
    },
  });
  const mutation = instance.mutate("records.add", {});
  await assert.rejects(mutation.result, OutcomeUnknownError);
  const unknown = mutation.getState();
  const first = mutation.recover();
  const second = mutation.recover();
  assert.equal(first, second);
  await until(() => reads === 1);
  answer.resolve(response(null, 200, "unknown"));
  assert.equal(await first, unknown);
  await assert.rejects(mutation.recover(), { code: "FORBIDDEN" });
  assert.equal(mutation.getState(), unknown);
  assert.equal(reads, 2);
});

test("call errors provide a key usable by a new client for read-only recovery", async (context) => {
  const first = client(context, {
    createId: () => "durable-key",
    fetch: async (url) => { if (url.endsWith("/identity")) return response(identity); throw new Error("lost"); },
  });
  const error = await first.call("flow.start", {}).catch((error) => error);
  first.close();
  const second = client(context, {
    fetch: async (url, init) => {
      if (url.endsWith("/identity")) return response(identity);
      assert.ok(url.endsWith("/operations/flow.start/recover"));
      assert.equal(init.headers["idempotency-key"], error.idempotencyKey);
      return response({ run_id: "one", status: "pending" }, 200, "accepted");
    },
  });
  assert.deepEqual(await second.recover("flow.start", {}, { idempotencyKey: error.idempotencyKey }),
    { status: "accepted", data: { run_id: "one", status: "pending" } });
});

test("listener failures never change a committed outcome or reject the result", async (context) => {
  const errors = [];
  const instance = client(context, { onListenerError: (error) => { errors.push(error); throw new Error("reporter failed"); } });
  const mutation = instance.mutate("records.add", {});
  const states = [];
  mutation.onChange(() => { throw new Error("listener failed"); });
  mutation.onChange((state) => states.push(state.status));
  assert.equal(await mutation.result, "saved");
  assert.deepEqual(states, ["pending", "committed"]);
  assert.equal(errors.length, 2);
});

test("unknown writes keep predictions until server data or TTL rather than rolling back as definite failures", async (context) => {
  const instance = client(context, {
    optimisticTtlMs: 30,
    fetch: async (url) => { if (url.endsWith("/identity")) return response(identity); throw new Error("lost"); },
  });
  const subscription = instance.subscribe("records.recent", {});
  await until(() => subscription.getState().status === "ready");
  const mutation = instance.mutate("records.add", {}, {
    optimistic: [{ subscription, update: () => ["predicted"] }],
  });
  await assert.rejects(mutation.result, OutcomeUnknownError);
  assert.deepEqual(subscription.getState().data, ["predicted"]);
  assert.equal(subscription.getState().pending, 1);
  await until(() => subscription.getState().pending === undefined);
  assert.deepEqual(subscription.getState().data, ["initial"]);
  assert.equal(mutation.getState().status, "unknown");
});

for (const failure of ["interrupt", "timeout", "abort", "malformed"]) {
  test(`socket ${failure} after dispatch is unknown and recovery sends only a recover event`, async (context) => {
    const sent = Promise.withResolvers();
    const events = [];
    class RecoverySocket extends TestWebSocket {
      send(raw) {
        const [joinRef, ref, topic, event, payload] = JSON.parse(raw);
        if (!["call", "recover"].includes(event)) return super.send(raw);
        events.push({ event, payload });
        sent.resolve();
        if (event === "call") {
          if (failure === "interrupt") queueMicrotask(() => this.interrupt());
          if (failure === "malformed") queueMicrotask(() => this.emit([joinRef, ref, topic, "phx_reply", { status: "ok", response: { data: "saved" } }]));
          return;
        }
        queueMicrotask(() => this.emit([joinRef, ref, topic, "phx_reply", { status: "ok", response: { outcome: "committed", data: "saved" } }]));
      }
    }
    const instance = client(context, {
      operationTransport: "socket", WebSocket: RecoverySocket, timeoutMs: 100, retryDelayMs: () => 1,
    });
    const abort = new AbortController();
    const mutation = instance.mutate("records.add", { text: "saved" }, { signal: abort.signal });
    await sent.promise;
    if (failure === "abort") abort.abort();
    await assert.rejects(mutation.result, OutcomeUnknownError);
    assert.equal(mutation.getState().status, "unknown");
    assert.deepEqual(await mutation.recover(), { status: "committed", data: "saved" });
    assert.deepEqual(events.map(({ event }) => event), ["call", "recover"]);
    assert.equal(events[0].payload.idempotency_key, events[1].payload.idempotency_key);
  });
}
