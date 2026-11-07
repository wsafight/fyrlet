import test from "node:test";
import assert from "node:assert/strict";
import { getEventListeners } from "node:events";
import { createSessionService, ApiError } from "../../dist/server.js";
import { response } from "../helpers.mjs";

const session = {
  token: "rts_user", project_id: "project", subject_id: "alice",
  session_id: "session", expires_at: "2026-11-08T00:00:00Z",
};

function service(fetch, endpoint = "https://example.com/fyrlet/") {
  return createSessionService({ endpoint, serviceKey: "rtk_backend", fetch });
}

for (const endpoint of [
  "ws://example.com", "ftp://example.com", "file:///tmp/fyrlet",
  "https://user@example.com", "https://user:password@example.com",
  "https://example.com?token=secret", "https://example.com#fragment", "/relative/path",
]) {
  test(`session services reject unsafe or non-HTTP endpoints: ${endpoint}`, () => {
    assert.throws(() => service(async () => response(session), endpoint), TypeError);
  });
}

for (const serviceKey of ["rts_user", "public", "", "RTK_backend"]) {
  test(`session services reject a non-service credential: ${JSON.stringify(serviceKey)}`, () => {
    assert.throws(() => createSessionService({ endpoint: "https://example.com", serviceKey }), TypeError);
  });
}

test("session issuance preserves backend fields, base paths and private request options", async () => {
  const calls = [];
  const controller = new AbortController();
  const instance = service(async (url, init) => { calls.push({ url, init }); return response(session); });
  const input = { external_subject: "用户/one", issuer: "my-backend", ttl_seconds: 90 };

  assert.deepEqual(await instance.issueSession(input, controller.signal), session);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://example.com/fyrlet/api/v1/sessions");
  assert.deepEqual(calls[0].init, {
    method: "POST",
    headers: { authorization: "Bearer rtk_backend", "content-type": "application/json" },
    body: JSON.stringify(input), signal: controller.signal, cache: "no-store", credentials: "omit",
  });
  assert.equal(getEventListeners(controller.signal, "abort").length, 0);
  assert.deepEqual(input, { external_subject: "用户/one", issuer: "my-backend", ttl_seconds: 90 });
});

test("revoking a session encodes the entire identifier as one path segment", async () => {
  const identifier = "session/用户?# %";
  const calls = [];
  const instance = service(async (url, init) => { calls.push({ url, init }); return response({ revoked: true }); });

  assert.deepEqual(await instance.revokeSession(identifier), { revoked: true });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, `https://example.com/fyrlet/api/v1/sessions/${encodeURIComponent(identifier)}`);
  assert.equal(calls[0].init.method, "DELETE");
  assert.equal(calls[0].init.headers.authorization, "Bearer rtk_backend");
  assert.equal(calls[0].init.body, undefined);
  assert.equal(calls[0].init.signal, undefined);
  assert.equal(calls[0].init.cache, "no-store");
  assert.equal(calls[0].init.credentials, "omit");
});

test("the session service can use the host's fetch implementation", async (context) => {
  const fetcher = context.mock.method(globalThis, "fetch", async () => response(session));
  const instance = createSessionService({ endpoint: "http://localhost:4000/", serviceKey: "rtk_backend" });

  assert.deepEqual(await instance.issueSession({ external_subject: "alice" }), session);
  assert.equal(fetcher.mock.calls.length, 1);
  assert.equal(fetcher.mock.calls[0].arguments[0], "http://localhost:4000/api/v1/sessions");
});

for (const [status, code] of [[401, "UNAUTHENTICATED"], [403, "FORBIDDEN"], [429, "RATE_LIMITED"], [503, "UNAVAILABLE"]]) {
  test(`session service preserves a ${status} error without retrying the backend credential`, async () => {
    let attempts = 0;
    const details = { retry_after_ms: 2500 };
    const instance = service(async () => {
      attempts++;
      return response({ code, message: "Service rejected the request", details, retryable: true }, status);
    });

    await assert.rejects(instance.issueSession({ external_subject: "alice" }), (error) => {
      assert.ok(error instanceof ApiError);
      assert.equal(error.code, code);
      assert.equal(error.message, "Service rejected the request");
      assert.equal(error.status, status);
      assert.equal(error.requestId, "test-request");
      assert.equal(error.retryable, true);
      assert.deepEqual(error.details, details);
      return true;
    });
    assert.equal(attempts, 1);
  });
}

for (const [name, body] of [
  ["null envelope", null], ["array envelope", []], ["string envelope", "invalid"],
  ["missing data", {}], ["invalid error code", { error: { code: 123, message: "Rejected" } }],
  ["missing error message", { error: { code: "REJECTED" } }],
]) {
  test(`session service reports a protocol error for ${name}`, async () => {
    const instance = service(async () => new Response(JSON.stringify(body), { status: 200 }));
    await assert.rejects(instance.revokeSession("session"), (error) =>
      error instanceof ApiError && error.code === "PROTOCOL_ERROR" && error.status === 200);
  });
}

test("malformed JSON and unstructured HTTP failures have stable session service errors", async () => {
  const malformed = service(async () => new Response("not JSON", { status: 502 }));
  await assert.rejects(malformed.revokeSession("session"), { code: "PROTOCOL_ERROR", status: 502 });

  const rejected = service(async () => new Response(JSON.stringify({ request_id: "unstructured" }), { status: 500 }));
  await assert.rejects(rejected.revokeSession("session"), {
    code: "HTTP_ERROR", status: 500, requestId: "unstructured", retryable: false,
  });
});

test("network failures are sanitized and do not replay session issuance", async () => {
  let attempts = 0;
  const instance = service(async () => { attempts++; throw new Error("private proxy credentials"); });

  await assert.rejects(instance.issueSession({ external_subject: "alice" }), (error) =>
    error instanceof ApiError && error.code === "NETWORK_ERROR" && error.retryable &&
    !error.message.includes("private"));
  assert.equal(attempts, 1);
});

for (const [operation, invoke] of [
  ["issue", (instance, signal) => instance.issueSession({ external_subject: "alice" }, signal)],
  ["revoke", (instance, signal) => instance.revokeSession("session", signal)],
]) {
  test(`preaborted ${operation} requests preserve the reason without sending a request`, async () => {
    const reason = new Error("cancelled before dispatch");
    let attempts = 0;
    const instance = service(async () => { attempts++; return response(session); });

    await assert.rejects(invoke(instance, AbortSignal.abort(reason)), (error) => error === reason);
    assert.equal(attempts, 0);
  });

  for (const stage of ["fetch", "body"]) {
    test(`aborting ${operation} while waiting for ${stage} cancels even if the implementation ignores abort`, async () => {
      const controller = new AbortController();
      const reason = new Error("caller cancelled");
      const started = Promise.withResolvers();
      const blocked = Promise.withResolvers();
      const instance = service(async () => {
        if (stage === "fetch") { started.resolve(); return blocked.promise; }
        return { status: 200, ok: true, json: () => { started.resolve(); return blocked.promise; } };
      });
      const pending = invoke(instance, controller.signal);
      const rejected = assert.rejects(pending, (error) => error === reason);

      await started.promise;
      controller.abort(reason);
      await rejected;
      assert.equal(getEventListeners(controller.signal, "abort").length, 0);
      blocked.resolve(stage === "fetch" ? response(session) : { data: session });
    });
  }
}
