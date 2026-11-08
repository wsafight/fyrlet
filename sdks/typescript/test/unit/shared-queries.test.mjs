import test from "node:test";
import assert from "node:assert/strict";
import { createClient } from "../../dist/index.js";
import { response, TestWebSocket, until } from "../helpers.mjs";

function client(context, options = {}) {
  const instance = createClient({
    endpoint: "http://localhost:4000", projectId: "project", getToken: () => "rts_test",
    fetch: async (url) => response(url.endsWith("/identity") ? { project_id: "project", subject_id: "alice" } : "saved"),
    WebSocket: TestWebSocket, shareSubscriptions: true, capabilities: ["append", "presence"], ...options,
  });
  context.after(() => instance.close());
  return instance;
}

test("equivalent JSON parameters share one channel with independent handles and listeners", async (context) => {
  const instance = client(context);
  const params = { nested: { limit: 10, archived: false }, labels: ["a", "b"] };
  const first = instance.subscribe("records.recent", params);
  const second = instance.subscribe("records.recent", { labels: ["a", "b"], nested: { archived: false, limit: 10 } });
  await until(() => first.getState().status === "ready" && second.getState().status === "ready");
  const socket = TestWebSocket.instances.at(-1);
  assert.equal(socket.joins.size, 1);
  assert.equal(first.getState(), second.getState());
  assert.equal(first.getState(), first.getState());
  params.nested.limit = 99;
  const seen = [];
  const listener = (state) => seen.push(state.status);
  first.onChange(listener);
  second.onChange(listener);
  first.unsubscribe();
  assert.deepEqual(seen, ["ready", "ready", "closed"]);
  assert.equal(first.getState().status, "closed");
  socket.snapshot(["updated"]);
  assert.deepEqual(second.getState().data, ["updated"]);
  assert.equal(seen.at(-1), "ready");
  assert.equal(socket.messages.filter((message) => message.event === "phx_leave").length, 0);
  await assert.rejects(instance.call("records.add", {}, { optimistic: [{ subscription: first, update: () => [] }] }), TypeError);
  await instance.reconnect();
  await until(() => second.getState().status === "ready");
  const next = TestWebSocket.instances.at(-1);
  assert.equal(next.messages.find((message) => message.event === "phx_join").payload.params.nested.limit, 10);
  second.unsubscribe();
  assert.ok(next.messages.some((message) => message.event === "phx_leave"));
  assert.equal(next.readyState, 3);
});

test("query names, parameters and delivery modes remain separate, and presence is never shared", async (context) => {
  const instance = client(context);
  const subscriptions = [
    instance.subscribe("records.recent", { limit: 1 }), instance.subscribe("records.recent", { limit: 2 }),
    instance.subscribe("records.other", { limit: 1 }), instance.subscribeAppend("records.recent", { limit: 1 }),
    instance.subscribePresence("rooms.members", {}), instance.subscribePresence("rooms.members", {}),
  ];
  await until(() => subscriptions.every((subscription) => subscription.getState().status === "ready"));
  assert.equal(TestWebSocket.instances.at(-1).joins.size, 6);
});

test("the shared query limit releases capacity after the final reference and preserves unshared defaults", async (context) => {
  const instance = client(context, { maxSharedSubscriptions: 1 });
  const first = instance.subscribe("records.recent", {});
  const second = instance.subscribe("records.recent", {});
  assert.throws(() => instance.subscribe("records.other", {}), { code: "LIMIT_EXCEEDED" });
  first.unsubscribe();
  assert.throws(() => instance.subscribe("records.other", {}), { code: "LIMIT_EXCEEDED" });
  second.unsubscribe();
  const replacement = instance.subscribe("records.other", {});
  await until(() => replacement.getState().status === "ready");
  const unshared = client(context, { shareSubscriptions: false });
  const left = unshared.subscribe("records.recent", {});
  const right = unshared.subscribe("records.recent", {});
  await until(() => left.getState().status === "ready" && right.getState().status === "ready");
  assert.equal(TestWebSocket.instances.at(-1).joins.size, 2);
});

test("releasing a shared handle cancels only its own confirmation", async (context) => {
  const instance = client(context);
  const first = instance.subscribe("records.recent", {});
  const second = instance.subscribe("records.recent", {});
  await until(() => first.getState().status === "ready");
  const stopped = assert.rejects(first.confirm(), { code: "SUBSCRIPTION_CLOSED" });
  const pending = second.confirm();
  first.unsubscribe();
  await stopped;
  TestWebSocket.instances.at(-1).snapshot(["confirmed"]);
  await pending;
  assert.equal(second.getState().status, "ready");
});

test("closed and failed clients retain no reusable private query state", async (context) => {
  let forbidden = false;
  const instance = client(context, { maxSharedSubscriptions: 1, fetch: async (url) => {
    if (url.endsWith("/identity")) return response({ project_id: "project", subject_id: forbidden ? "bob" : "alice" });
    return response({ code: "UNAUTHENTICATED", message: "Expired" }, 401);
  } });
  const first = instance.subscribe("records.recent", {});
  await until(() => first.getState().status === "ready");
  forbidden = true;
  await assert.rejects(instance.call("records.add", {}), { code: "FORBIDDEN" });
  assert.equal(first.getState().data, undefined);
  forbidden = false;
  const next = instance.subscribe("records.recent", {});
  await until(() => next.getState().status === "ready");
  assert.notEqual(first.getState(), next.getState());
  instance.close();
  assert.equal(next.getState().data, undefined);
  assert.throws(() => instance.subscribe("records.recent", {}), { code: "CLIENT_CLOSED" });
});

for (const value of [undefined, { absent: undefined }, { number: NaN }, { value: new Date() }, { list: [Infinity] }]) {
  test(`shared parameters reject ambiguous non-JSON values: ${String(value)}`, (context) => {
    const instance = client(context);
    assert.throws(() => instance.subscribe("records.recent", value), TypeError);
  });
}

test("cyclic and oversized parameters are refused before creating a subscription", (context) => {
  const instance = client(context);
  const cyclic = {};
  cyclic.self = cyclic;
  assert.throws(() => instance.subscribe("records.recent", cyclic), TypeError);
  assert.throws(() => instance.subscribe("records.recent", { text: "字".repeat(30_000) }), TypeError);
});
