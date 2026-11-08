import test from "node:test";
import assert from "node:assert/strict";
import { createClient } from "../../dist/index.js";
import { response, TestWebSocket, until } from "../helpers.mjs";

function client(context, options = {}) {
  const instance = createClient({
    endpoint: "http://localhost:4000", projectId: "project", getToken: () => "rts_test",
    fetch: async (url) => response(url.endsWith("/identity") ? { project_id: "project", subject_id: "alice" } : "saved"),
    WebSocket: TestWebSocket, capabilities: ["append"], ...options,
  });
  context.after(() => instance.close());
  return instance;
}

function request(socket, index = -1) {
  return socket.messages.filter((message) => message.event === "refresh" && message.payload.confirmation_id).at(index);
}

test("accepted refreshes, unrelated pushes and stale generations do not confirm a committed write", async (context) => {
  const instance = client(context);
  const subscription = instance.subscribe("records.recent", {});
  await until(() => subscription.getState().status === "ready");
  const socket = TestWebSocket.instances.at(-1);
  const mutation = instance.mutate("records.add", {}, { optimistic: [{ subscription, update: () => ["predicted"] }] });
  await mutation.result;
  await until(() => request(socket));
  const identifier = request(socket).payload.confirmation_id;
  let confirmed = false;
  void mutation.views.then(() => { confirmed = true; });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(confirmed, false);
  socket.snapshot(["unrelated"], { confirmed: [] });
  assert.deepEqual(subscription.getState().data, ["predicted"]);
  socket.snapshot(["stale"], { generation: "old-generation", seq: 3, confirmed: [identifier] });
  socket.snapshot(["stale"], { seq: 2, confirmed: [identifier] });
  assert.equal(confirmed, false);
  socket.snapshot(["authoritative"], { seq: 3, confirmed: [identifier] });
  const views = await mutation.views;
  assert.equal(views[0].subscription, subscription);
  assert.equal(views[0].status, "confirmed");
  assert.deepEqual(subscription.getState().data, ["authoritative"]);
  assert.equal(subscription.getState().pending, undefined);
});

test("a delta carrying a confirmation cannot retire a prediction", async (context) => {
  const instance = client(context);
  const subscription = instance.subscribe("records.recent", {});
  await until(() => subscription.getState().status === "ready");
  const socket = TestWebSocket.instances.at(-1);
  socket.snapshot([{ id: "record", text: "before" }]);
  const mutation = instance.mutate("records.edit", {}, {
    optimistic: [{ subscription, update: () => [{ id: "record", text: "predicted" }] }],
  });
  await mutation.result;
  await until(() => request(socket));
  const identifier = request(socket).payload.confirmation_id;
  const [topic, joined] = [...socket.joins][0];
  socket.emit([joined.joinRef, null, topic, "delta", {
    g: joined.snapshot.generation, s: 3, b: 2, p: { c: [["record", { text: "unrelated" }]] }, confirmed: [identifier],
  }]);
  assert.equal(subscription.getState().status, "ready");
  assert.equal(subscription.getState().pending, 1);
  assert.deepEqual(subscription.getState().data, [{ id: "record", text: "predicted" }]);
  socket.snapshot([{ id: "record", text: "authoritative" }], { seq: 4, confirmed: [identifier] });
  assert.equal((await mutation.views)[0].status, "confirmed");
  assert.deepEqual(subscription.getState().data, [{ id: "record", text: "authoritative" }]);
});

test("unsubscribing before the write response reports an unconfirmed view", async (context) => {
  let complete;
  const instance = client(context, { fetch: async (url) => {
    if (url.endsWith("/identity")) return response({ project_id: "project", subject_id: "alice" });
    return new Promise((resolve) => { complete = () => resolve(response("saved")); });
  } });
  const subscription = instance.subscribe("records.recent", {});
  await until(() => subscription.getState().status === "ready");
  const mutation = instance.mutate("records.add", {}, { confirm: [subscription] });
  await until(() => complete);
  subscription.unsubscribe();
  complete();
  assert.equal(await mutation.result, "saved");
  const [view] = await mutation.views;
  assert.equal(view.subscription, subscription);
  assert.equal(view.status, "unconfirmed");
  assert.equal(view.error.code, "SUBSCRIPTION_CLOSED");
  assert.equal(mutation.getState().status, "committed");
});

test("a duplicate confirmation ID never sends another refresh or disturbs the first waiter", async (context) => {
  let identifiers = 0;
  const instance = client(context, { createId: () => identifiers++ === 0 ? "subscription" : "duplicate" });
  const subscription = instance.subscribe("records.recent", {});
  await until(() => subscription.getState().status === "ready");
  const socket = TestWebSocket.instances.at(-1);
  const first = subscription.confirm();
  await assert.rejects(subscription.confirm(), { code: "LIMIT_EXCEEDED" });
  assert.equal(socket.messages.filter((message) => message.payload.confirmation_id).length, 1);
  socket.snapshot([], { confirmed: ["duplicate"] });
  await first;
  assert.equal(subscription.getState().status, "ready");
});

test("permission revocation rejects confirmation and clears private predictions", async (context) => {
  const instance = client(context);
  const subscription = instance.subscribe("records.recent", {});
  await until(() => subscription.getState().status === "ready");
  const mutation = instance.mutate("records.add", {}, {
    optimistic: [{ subscription, update: () => ["private prediction"] }],
  });
  await mutation.result;
  const socket = TestWebSocket.instances.at(-1);
  await until(() => request(socket));
  const [topic, joined] = [...socket.joins][0];
  socket.emit([joined.joinRef, null, topic, "status", { error: { code: "FORBIDDEN", message: "Permission revoked" } }]);
  const [view] = await mutation.views;
  assert.equal(view.status, "unconfirmed");
  assert.equal(view.error.code, "FORBIDDEN");
  assert.equal(subscription.getState().data, undefined);
  assert.equal(subscription.getState().pending, undefined);
  assert.equal(mutation.getState().status, "committed");
});

test("servers without confirmation support leave committed views unconfirmed", async (context) => {
  class OlderWebSocket extends TestWebSocket {
    emit(frame) {
      if (frame[3] === "phx_reply" && frame[4].response?.capabilities) {
        delete frame[4].response.capabilities.view_confirmation;
      }
      super.emit(frame);
    }
  }
  const instance = client(context, { WebSocket: OlderWebSocket });
  const subscription = instance.subscribe("records.recent", {});
  await until(() => subscription.getState().status === "ready");
  const mutation = instance.mutate("records.add", {}, { confirm: [subscription] });
  await mutation.result;
  const [view] = await mutation.views;
  assert.equal(view.status, "unconfirmed");
  assert.equal(view.error.code, "UNSUPPORTED_CAPABILITY");
  assert.equal(request(TestWebSocket.instances.at(-1)), undefined);
  assert.equal(mutation.getState().status, "committed");
});

test("malformed confirmation lists fail the subscription without confirming its view", async (context) => {
  const instance = client(context);
  const subscription = instance.subscribe("records.recent", {});
  await until(() => subscription.getState().status === "ready");
  const socket = TestWebSocket.instances.at(-1);
  const pending = subscription.confirm();
  const rejected = assert.rejects(pending, { code: "PROTOCOL_ERROR" });
  const identifier = request(socket).payload.confirmation_id;
  await new Promise((resolve) => setImmediate(resolve));
  socket.snapshot(["invalid"], { confirmed: [identifier, identifier] });
  await rejected;
  assert.equal(subscription.getState().data, undefined);
  assert.equal(subscription.getState().status, "error");
});

test("each subscription and concurrent write needs its own matching confirmation", async (context) => {
  const instance = client(context);
  const first = instance.subscribe("records.recent", {});
  const second = instance.subscribe("records.other", {});
  await until(() => first.getState().status === "ready" && second.getState().status === "ready");
  const socket = TestWebSocket.instances.at(-1);
  const earlier = instance.mutate("records.add", {}, { optimistic: [{ subscription: first, update: (items) => [...items, "earlier"] }] });
  await earlier.result;
  await until(() => request(socket));
  const earlierId = request(socket).payload.confirmation_id;
  const later = instance.mutate("records.add", {}, {
    optimistic: [{ subscription: first, update: (items) => [...items, "later"] }], confirm: [second],
  });
  await later.result;
  await until(() => socket.messages.filter((message) => message.payload.confirmation_id).length === 3);
  socket.snapshot(["earlier"], { confirmed: [earlierId] });
  assert.equal((await earlier.views)[0].status, "confirmed");
  assert.deepEqual(first.getState().data, ["earlier", "later"]);
  const pending = socket.messages.filter((message) => message.payload.confirmation_id && message.payload.confirmation_id !== earlierId);
  for (const message of pending) {
    const joined = socket.joins.get(message.topic);
    socket.emit([joined.joinRef, null, message.topic, "snapshot", { ...joined.snapshot, seq: 3, data: [], confirmed: [message.payload.confirmation_id] }]);
  }
  assert.deepEqual((await later.views).map((view) => view.status), ["confirmed", "confirmed"]);
  assert.deepEqual(first.getState().data, []);
});

for (const failure of ["timeout", "abort", "reconnect", "unsubscribe"]) {
  test(`${failure} reports an unconfirmed view without changing the committed outcome`, async (context) => {
    const instance = client(context, { timeoutMs: 60 });
    const subscription = instance.subscribe("records.recent", {});
    await until(() => subscription.getState().status === "ready");
    const controller = new AbortController();
    const mutation = instance.mutate("records.add", {}, { confirm: [subscription], signal: controller.signal });
    await mutation.result;
    await until(() => request(TestWebSocket.instances.at(-1)));
    if (failure === "abort") controller.abort(new Error("cancelled confirmation"));
    if (failure === "reconnect") await instance.reconnect();
    if (failure === "unsubscribe") subscription.unsubscribe();
    const [view] = await mutation.views;
    assert.equal(view.status, "unconfirmed");
    assert.ok(view.error);
    assert.equal(mutation.getState().status, "committed");
  });
}

test("append confirmation requires a new matched snapshot, including when the result is unchanged", async (context) => {
  const instance = client(context);
  const subscription = instance.subscribeAppend("feed.recent", {});
  await until(() => subscription.getState().status === "ready");
  const socket = TestWebSocket.instances.at(-1);
  const pending = subscription.confirm();
  const identifier = request(socket).payload.confirmation_id;
  socket.snapshot([], { confirmed: [identifier], cursor: "e:0" });
  await pending;
  assert.equal(subscription.getState().seq, 2);
  assert.ok(socket.messages.some((message) => message.event === "ack" && message.payload.s === 2 && message.payload.c === "e:0"));
});

test("confirmation failures and unknown outcomes never replay the original operation", async (context) => {
  let writes = 0;
  const instance = client(context, { fetch: async (url) => {
    if (url.endsWith("/identity")) return response({ project_id: "project", subject_id: "alice" });
    writes++;
    throw new Error("response lost");
  } });
  const subscription = instance.subscribe("records.recent", {});
  await until(() => subscription.getState().status === "ready");
  const mutation = instance.mutate("records.add", {}, { confirm: [subscription] });
  await assert.rejects(mutation.result);
  assert.equal((await mutation.views)[0].status, "unconfirmed");
  assert.equal(mutation.getState().status, "unknown");
  assert.equal(writes, 1);
  assert.equal(request(TestWebSocket.instances.at(-1)), undefined);
});
