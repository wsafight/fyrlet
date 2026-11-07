import test from "node:test";
import assert from "node:assert/strict";
import { createClient, ApiError } from "../../dist/index.js";
import { response, TestWebSocket, until } from "../helpers.mjs";

const identity = { project_id: "project", subject_id: "alice" };

function client(context, options = {}) {
  const instance = createClient({
    endpoint: "http://localhost:4000", projectId: "project", getToken: () => "rts_test",
    fetch: async (url) => response(url.endsWith("/identity") ? identity : "saved"),
    WebSocket: TestWebSocket, retryDelayMs: () => 10, ...options,
  });
  context.after(() => instance.close());
  return instance;
}

for (const token of [undefined, null, 123, {}, "", "rtk_backend", "invalid"]) {
  test(`an invalid token provider result (${JSON.stringify(token)}) fails before dispatch`, async (context) => {
    let requests = 0;
    const instance = client(context, {
      getToken: () => token,
      fetch: async () => { requests++; return response(identity); },
    });
    const mutation = instance.mutate("records.add", {});

    await assert.rejects(mutation.result, (error) => error instanceof ApiError && error.code === "UNAUTHENTICATED");
    assert.equal(mutation.getState().status, "failed");
    assert.equal(requests, 0);
  });
}

for (const token of [null, "rtk_backend"]) {
  test(`an invalid refreshed identity credential (${JSON.stringify(token)}) is never sent`, async (context) => {
    const refreshes = [];
    const requests = [];
    const instance = client(context, {
      getToken: ({ forceRefresh }) => { refreshes.push(forceRefresh); return forceRefresh ? token : "rts_expired"; },
      fetch: async (url) => {
        requests.push(url);
        return response({ code: "UNAUTHENTICATED", message: "Expired" }, 401);
      },
    });

    await assert.rejects(instance.call("records.add", {}), { code: "UNAUTHENTICATED" });
    assert.deepEqual(refreshes, [false, true]);
    assert.equal(requests.length, 1);
    assert.ok(requests[0].endsWith("/identity"));
  });
}

test("an identity from another project is rejected before sending a business operation", async (context) => {
  const requests = [];
  const instance = client(context, {
    fetch: async (url) => { requests.push(url); return response({ ...identity, project_id: "other" }); },
  });

  await assert.rejects(instance.call("records.add", {}), { code: "FORBIDDEN" });
  assert.equal(requests.length, 1);
  assert.ok(requests[0].endsWith("/identity"));
});

for (const rejected of [false, true]) {
  test(`reconnect waits for ${rejected ? "a rejected" : "an unresolved"} authorization before forcing a fresh token`, async (context) => {
    const token = Promise.withResolvers();
    const failure = new Error("initial credential unavailable");
    const refreshes = [];
    const instance = client(context, {
      getToken: ({ forceRefresh }) => { refreshes.push(forceRefresh); return forceRefresh ? "rts_fresh" : token.promise; },
    });
    const operation = instance.call("records.add", {});
    const settled = rejected
      ? assert.rejects(operation, (error) => error === failure)
      : assert.doesNotReject(operation);
    const subscription = instance.subscribe("records.recent", {});
    const reconnected = instance.reconnect();
    assert.deepEqual(refreshes, [false]);
    if (rejected) token.reject(failure); else token.resolve("rts_initial");

    await settled;
    await reconnected;
    await until(() => subscription.getState().status === "ready");
    assert.deepEqual(refreshes, [false, true]);
    assert.equal(subscription.getState().error, undefined);
  });
}

test("an identity network failure automatically retries and joins with a refreshed credential", async (context) => {
  const refreshes = [];
  let attempts = 0;
  const instance = client(context, {
    getToken: ({ forceRefresh }) => { refreshes.push(forceRefresh); return forceRefresh ? "rts_fresh" : "rts_initial"; },
    fetch: async () => { if (++attempts === 1) throw new Error("temporary network failure"); return response(identity); },
  });
  const subscription = instance.subscribe("records.recent", {});

  await until(() => subscription.getState().status === "recovering");
  assert.equal(subscription.getState().data, undefined);
  await until(() => subscription.getState().status === "ready");
  assert.deepEqual(refreshes, [false, true]);
  assert.equal(attempts, 2);
});

test("closing during connection backoff cancels the retry and releases the subscription", async (context) => {
  context.mock.timers.enable({ apis: ["setTimeout"] });
  let attempts = 0;
  const instance = client(context, {
    fetch: async () => { attempts++; throw new Error("offline"); },
  });
  const subscription = instance.subscribe("records.recent", {});
  await until(() => subscription.getState().status === "recovering");

  instance.close();
  context.mock.timers.tick(60_000);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(subscription.getState().status, "closed");
  assert.equal(subscription.getState().data, undefined);
  assert.equal(attempts, 1);
});
