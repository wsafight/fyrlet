import test from "node:test";
import assert from "node:assert/strict";
import { setTimeout as delay } from "node:timers/promises";
import { createClient, ApiError, OutcomeUnknownError } from "../../dist/index.js";
import { response, TestWebSocket, until } from "../helpers.mjs";
import { request } from "../../dist/http.js";

const identity = { project_id: "project", subject_id: "alice" };
const policy = { maxAttempts: 3, maxElapsedMs: 200, baseDelayMs: 0, maxDelayMs: 0 };
function client(context, perform, extra = {}) {
  const calls = [];
  const instance = createClient({ endpoint: "http://localhost:4000", projectId: "project", getToken: () => "rts_token",
    createId: () => "fixed-key", operationMetadata: { "record.read": { kind: "read" }, "record.write": { kind: "write" }, "record.run": { kind: "run" } },
    fetch: async (url, init) => {
      if (url.endsWith("/identity")) return response(identity);
      calls.push({ url, init });
      return perform(url, init, calls.length);
    }, ...extra });
  context.after(() => instance.close());
  return { instance, calls };
}

test("retry remains disabled by default", async (context) => {
  const { instance, calls } = client(context, () => { throw new TypeError("offline"); });
  await assert.rejects(instance.call("record.read", {}), OutcomeUnknownError);
  assert.equal(calls.length, 1);
});

test("read retries freeze input and reuse the key", async (context) => {
  const input = { text: "original" };
  const { instance, calls } = client(context, (_url, _init, attempt) => {
    input.text = "changed";
    if (attempt < 3) throw new TypeError("offline");
    return response("done", 200, "completed");
  });
  const mutation = instance.mutate("record.read", input, { retry: policy });
  const progress = [];
  mutation.onChange((state) => { if (state.retry) progress.push(state.retry); });
  assert.equal(await mutation.result, "done");
  assert.equal(calls.length, 3);
  assert.ok(calls.every(({ init }) => init.headers["idempotency-key"] === "fixed-key" && JSON.parse(init.body).input.text === "original"));
  assert.ok(progress.some(({ attempt }) => attempt === 3));
  assert.equal(mutation.getState().status, "completed");
});

test("an uncertain write retries receipt lookup without replaying the business operation", async (context) => {
  const { instance, calls } = client(context, (url, _init, attempt) => {
    if (attempt === 1) throw new TypeError("response lost after commit");
    assert.ok(url.endsWith("/recover"));
    return response({ id: "committed" });
  });
  const mutation = instance.mutate("record.write", {}, { retry: policy });
  assert.deepEqual(await mutation.result, { id: "committed" });
  assert.equal(mutation.getState().status, "committed");
  assert.equal(calls.length, 2);
  assert.equal(calls[0].init.body, calls[1].init.body);
  assert.equal(calls[0].init.headers["idempotency-key"], calls[1].init.headers["idempotency-key"]);
});

test("missing or expired receipts stay unknown and never replay", async (context) => {
  const { instance, calls } = client(context, (_url, _init, attempt) => {
    if (attempt === 1) throw new TypeError("offline");
    return response(null, 200, "unknown");
  });
  const mutation = instance.mutate("record.write", {}, { retry: policy });
  await assert.rejects(mutation.result, OutcomeUnknownError);
  assert.equal(mutation.getState().status, "unknown");
  assert.equal(calls.length, 3);
  assert.ok(calls.slice(1).every(({ url }) => url.endsWith("/recover")));
});

for (const [code, status] of [["FORBIDDEN", 403], ["VALIDATION_FAILED", 422], ["CONFLICT", 409], ["PROTOCOL_ERROR", 502]]) {
  test(`${code} is not retried even if marked retryable`, async (context) => {
    const { instance, calls } = client(context, () => response({ code, message: "rejected", retryable: true }, status));
    await assert.rejects(instance.call("record.write", {}, { retry: policy }));
    assert.equal(calls.length, 1);
  });
}

test("definite rate limiting honours both retry-after forms", async (context) => {
  let rejectedAt;
  const { instance, calls } = client(context, (_url, _init, attempt) => {
    if (attempt > 1) { assert.ok(Date.now() - rejectedAt >= 25); return response("ok"); }
    rejectedAt = Date.now();
    return new Response(JSON.stringify({ error: { code: "LIMIT_EXCEEDED", message: "busy", retryable: true, details: { retry_after_ms: 20 } } }), {
      status: 429, headers: { "retry-after": "0.03" },
    });
  });
  assert.equal(await instance.call("record.write", {}, { retry: policy }), "ok");
  assert.equal(calls.length, 2);
  assert.ok(calls.every(({ url }) => !url.endsWith("/recover")));
});

for (const action of ["abort", "close", "timeout"]) {
  test(`${action} stops backoff and subsequent attempts`, async (context) => {
    const external = new AbortController();
    const { instance, calls } = client(context, () => response({ code: "LIMIT_EXCEEDED", message: "busy", retryable: true, details: { retry_after_ms: 1000 } }, 429));
    const mutation = instance.mutate("record.write", {}, { signal: external.signal, retry: { ...policy, maxElapsedMs: 30 } });
    if (action !== "timeout") setTimeout(() => action === "close" ? instance.close() : external.abort(), 10);
    await assert.rejects(mutation.result);
    await delay(35);
    assert.equal(calls.length, 1);
    assert.equal(mutation.getState().status, "failed");
  });
}

test("a total timeout after dispatch retains unknown", async (context) => {
  const { instance, calls } = client(context, () => new Promise(() => {}));
  const mutation = instance.mutate("record.write", {}, { retry: { ...policy, maxElapsedMs: 20 } });
  await assert.rejects(mutation.result, OutcomeUnknownError);
  assert.equal(mutation.getState().status, "unknown");
  assert.equal(calls.length, 1);
});

test("retry rejects missing and unsafe metadata and invalid budgets before sending", (context) => {
  const { instance, calls } = client(context, () => response("unused"), { operationMetadata: { ingest: { kind: "ingest" } } });
  assert.throws(() => instance.mutate("missing", {}, { retry: policy }), TypeError);
  assert.throws(() => instance.mutate("ingest", {}, { retry: policy }), TypeError);
  assert.equal(calls.length, 0);
  for (const retry of [{ maxAttempts: 0 }, { maxAttempts: 11 }, { maxElapsedMs: Infinity }, { baseDelayMs: -1 }, { maxDelayMs: 1, baseDelayMs: 2 }]) {
    assert.throws(() => instance.mutate("missing", {}, { retry }), TypeError);
  }
});

test("authentication refresh and retry use the original key", async (context) => {
  const { instance, calls } = client(context, (_url, _init, attempt) => {
    if (attempt === 1) return response({ code: "UNAUTHENTICATED", message: "expired" }, 401);
    if (attempt === 2) throw new TypeError("lost");
    return response("saved");
  });
  assert.equal(await instance.call("record.write", {}, { retry: policy }), "saved");
  assert.equal(calls.length, 3);
  assert.ok(calls.every(({ init }) => init.headers["idempotency-key"] === "fixed-key"));
  assert.ok(calls[2].url.endsWith("/recover"));
});

test("a recovery error preserves the original uncertain result", async (context) => {
  const { instance, calls } = client(context, (_url, _init, attempt) => {
    if (attempt === 1) throw new TypeError("lost");
    return response({ code: "FORBIDDEN", message: "revoked" }, 403);
  });
  const mutation = instance.mutate("record.write", {}, { retry: policy });
  await assert.rejects(mutation.result, (error) => error instanceof OutcomeUnknownError && error.cause instanceof ApiError && error.cause.code === "NETWORK_ERROR");
  assert.equal(calls.length, 2);
});

for (const failure of ["interrupt", "timeout"]) {
  test(`socket ${failure} recovers automatically using the same key`, async (context) => {
    const events = [];
    class RecoverySocket extends TestWebSocket {
      send(raw) {
        const [joinRef, ref, topic, event, payload] = JSON.parse(raw);
        if (!["call", "recover"].includes(event)) return super.send(raw);
        events.push({ event, payload });
        if (event === "call") {
          if (failure === "interrupt") queueMicrotask(() => this.interrupt());
          return;
        }
        queueMicrotask(() => this.emit([joinRef, ref, topic, "phx_reply", { status: "ok", response: { outcome: "committed", data: "saved" } }]));
      }
    }
    const { instance } = client(context, () => response("unused"), { WebSocket: RecoverySocket, operationTransport: "socket", timeoutMs: 30, retryDelayMs: () => 1 });
    assert.equal(await instance.call("record.write", {}, { retry: { ...policy, maxElapsedMs: 1000 } }), "saved");
    assert.deepEqual(events.map(({ event }) => event), ["call", "recover"]);
    assert.equal(events[0].payload.idempotency_key, events[1].payload.idempotency_key);
  });
}

test("cancelling an uncertain write during backoff keeps it unknown and stops recovery", async (context) => {
  const controller = new AbortController();
  const { instance, calls } = client(context, () => { throw new TypeError("lost"); });
  const mutation = instance.mutate("record.write", {}, { signal: controller.signal, retry: { ...policy, baseDelayMs: 100, maxDelayMs: 100 } });
  mutation.onChange((state) => { if (state.retry?.nextRetryAt) controller.abort(); });
  await assert.rejects(mutation.result, OutcomeUnknownError);
  await delay(35);
  assert.equal(calls.length, 1);
  assert.equal(mutation.getState().status, "unknown");
});

test("explicitly disabling retries sends exactly one request even with metadata", async (context) => {
  const { instance, calls } = client(context, () => response({ code: "LIMIT_EXCEEDED", message: "busy", retryable: true }, 429));
  await assert.rejects(instance.call("record.write", {}, { retry: false }), (error) => error.code === "LIMIT_EXCEEDED");
  assert.equal(calls.length, 1);
});

test("default retry options stop at three attempts and leave a definite rejection failed", async (context) => {
  const { instance, calls } = client(context, () => response({ code: "LIMIT_EXCEEDED", message: "busy", retryable: true }, 429));
  const mutation = instance.mutate("record.write", {}, { retry: {} });
  await assert.rejects(mutation.result, (error) => error.code === "LIMIT_EXCEEDED");
  assert.equal(calls.length, 3);
  assert.equal(mutation.getState().status, "failed");
  assert.deepEqual(await mutation.views, []);
});

test("a one-attempt budget never starts receipt recovery", async (context) => {
  const { instance, calls } = client(context, () => { throw new TypeError("lost"); });
  await assert.rejects(instance.call("record.write", {}, { retry: { ...policy, maxAttempts: 1 } }), OutcomeUnknownError);
  assert.equal(calls.length, 1);
});

test("accepted Run receipts retain their outcome and never restart the Run", async (context) => {
  const accepted = { run_id: "run-1" };
  const { instance, calls } = client(context, (url, _init, attempt) => {
    if (attempt === 1) throw new TypeError("lost acceptance");
    assert.ok(url.endsWith("/recover"));
    return response(accepted, 200, "accepted");
  }, { capabilities: ["runs"] });
  const mutation = instance.mutate("record.run", {}, { retry: policy });
  assert.deepEqual(await mutation.result, accepted);
  assert.equal(mutation.getState().status, "accepted");
  assert.equal(calls.length, 2);
});

test("a transient receipt lookup failure retries lookup and preserves the original input", async (context) => {
  const input = { value: "original" };
  const { instance, calls } = client(context, (_url, _init, attempt) => {
    input.value = "mutated";
    if (attempt < 3) throw new TypeError("offline");
    return response("saved");
  });
  assert.equal(await instance.call("record.write", input, { retry: policy, idempotencyKey: "caller-key" }), "saved");
  assert.equal(calls.length, 3);
  assert.ok(calls.slice(1).every(({ url }) => url.endsWith("/recover")));
  assert.ok(calls.every(({ init }) => init.body === '{"input":{"value":"original"}}' && init.headers["idempotency-key"] === "caller-key"));
});

for (const code of ["UNAVAILABLE", "INTERNAL_ERROR"]) {
  test(`a read retries ${code} on HTTP 503`, async (context) => {
    const { instance, calls } = client(context, (_url, _init, attempt) => attempt === 1
      ? response({ code, message: "temporarily unavailable", retryable: true }, 503) : response("read", 200, "completed"));
    assert.equal(await instance.call("record.read", {}, { retry: policy }), "read");
    assert.equal(calls.length, 2);
    assert.ok(calls.every(({ url }) => !url.endsWith("/recover")));
  });
}

for (const [code, status, retryable] of [["LIMIT_EXCEEDED", 429, false], ["UNAVAILABLE", 500, true], ["INTERNAL_ERROR", 502, true]]) {
  test(`${code} on HTTP ${status} with retryable=${retryable} does not replay`, async (context) => {
    const { instance, calls } = client(context, () => response({ code, message: "rejected", retryable }, status));
    await assert.rejects(instance.call("record.read", {}, { retry: policy }));
    assert.equal(calls.length, 1);
  });
}

for (const [field, value] of [["maxAttempts", 1.5], ["maxAttempts", NaN], ["maxElapsedMs", 0], ["maxElapsedMs", 60_001],
  ["baseDelayMs", 60_001], ["baseDelayMs", "1"], ["maxDelayMs", -1], ["maxDelayMs", Infinity]]) {
  test(`invalid ${field}=${String(value)} is rejected before dispatch`, (context) => {
    const { instance, calls } = client(context, () => response("unused"));
    assert.throws(() => instance.mutate("record.write", {}, { retry: { [field]: value } }), TypeError);
    assert.equal(calls.length, 0);
  });
}

for (const action of ["abort", "close"]) {
  test(`${action} while receipt recovery is in flight keeps the write unknown`, async (context) => {
    const external = new AbortController();
    const recovering = Promise.withResolvers();
    const { instance, calls } = client(context, (_url, _init, attempt) => {
      if (attempt === 1) throw new TypeError("lost committed response");
      recovering.resolve();
      return new Promise(() => {});
    });
    const mutation = instance.mutate("record.write", {}, { signal: external.signal, retry: { ...policy, maxElapsedMs: 1000 } });
    await recovering.promise;
    if (action === "close") instance.close();
    else external.abort(new Error("cancelled"));
    await assert.rejects(mutation.result, (error) => error instanceof OutcomeUnknownError && error.cause.code === "NETWORK_ERROR");
    assert.equal(mutation.getState().status, "unknown");
    assert.equal(calls.length, 2);
  });
}

test("terminal authentication failure stops a different mutation waiting in backoff", async (context) => {
  const { instance, calls } = client(context, (url) => url.includes("record.read")
    ? response({ code: "UNAUTHENTICATED", message: "revoked" }, 401)
    : response({ code: "LIMIT_EXCEEDED", message: "busy", retryable: true, details: { retry_after_ms: 1000 } }, 429));
  const waiting = instance.mutate("record.write", {}, { retry: { ...policy, maxElapsedMs: 2000 } });
  await until(() => waiting.getState().retry?.nextRetryAt);
  await assert.rejects(instance.call("record.read", {}), (error) => error.code === "UNAUTHENTICATED");
  await assert.rejects(waiting.result);
  assert.equal(calls.filter(({ url }) => url.includes("record.write")).length, 1);
  assert.equal(waiting.getState().status, "failed");
});

test("concurrent retries keep independent keys and cancellation", async (context) => {
  const attempts = new Map();
  const external = new AbortController();
  const { instance, calls } = client(context, (_url, init) => {
    const key = init.headers["idempotency-key"];
    const attempt = (attempts.get(key) ?? 0) + 1;
    attempts.set(key, attempt);
    return attempt === 1
      ? response({ code: "LIMIT_EXCEEDED", message: "busy", retryable: true, details: { retry_after_ms: 20 } }, 429)
      : response(key);
  });
  const first = instance.mutate("record.write", {}, { retry: policy, idempotencyKey: "first", signal: external.signal });
  const second = instance.mutate("record.write", {}, { retry: policy, idempotencyKey: "second" });
  first.onChange((state) => { if (state.retry?.nextRetryAt) external.abort(); });
  await assert.rejects(first.result);
  assert.equal(await second.result, "second");
  assert.equal(attempts.get("first"), 1);
  assert.equal(attempts.get("second"), 2);
  assert.equal(calls.length, 3);
});

for (const [name, header, bodyDelay, expected] of [
  ["HTTP date", "Sun, 08 Nov 2026 00:00:02 GMT", undefined, 2000],
  ["body longer than header", "1", 3000, 3000],
  ["invalid header", "later", 120, 120],
  ["past HTTP date", "Sat, 07 Nov 2026 00:00:00 GMT", 120, 120],
  ["zero header", "0", undefined, 0],
]) {
  test(`Retry-After parsing handles ${name}`, async (context) => {
    context.mock.method(Date, "now", () => Date.parse("2026-11-08T00:00:00Z"));
    await assert.rejects(request(async () => new Response(JSON.stringify({ error: {
      code: "LIMIT_EXCEEDED", message: "busy", retryable: true, details: bodyDelay === undefined ? {} : { retry_after_ms: bodyDelay },
    } }), { status: 429, headers: { "retry-after": header } }), "http://localhost/operation", {}),
    (error) => error instanceof ApiError && error.details.retry_after_ms === expected);
  });
}
