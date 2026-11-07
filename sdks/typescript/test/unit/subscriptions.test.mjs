import test from "node:test";
import assert from "node:assert/strict";
import { createClient } from "../../dist/index.js";
import { response, TestWebSocket, until } from "../helpers.mjs";

const identity = { project_id: "project", subject_id: "alice" };

test("presence handles retain ownership for optimistic writes and stop accepting them after unsubscribe", async (context) => {
  const instance = client(context);
  const presence = instance.subscribePresence("rooms.members", {}, { typing: false });
  const socket = await ready(presence);
  const original = presence.getState().data;
  const states = [];
  presence.onChange((state) => states.push(state));
  const optimistic = [{ subscription: presence, update: (roster) => ({ ...roster, preview: [] }) }];

  await instance.call("records.update", {}, { optimistic });
  assert.ok(states.some((state) => state.pending === 1 && "preview" in state.data));
  assert.equal(presence.getState().pending, 1);
  channel(socket, "presence:").send("diff", { joins: {}, leaves: {} });
  assert.equal(presence.getState().pending, undefined);
  assert.deepEqual(presence.getState().data, original);

  presence.unsubscribe();
  await assert.rejects(instance.call("records.update", {}, { optimistic }), TypeError);
});

for (const event of ["refresh", "update"]) {
  test(`${event} rejects before joining, surfaces errors and times out without losing channel state`, async (context) => {
    const instance = client(context, { timeoutMs: 50 });
    const subscription = event === "update"
      ? instance.subscribePresence("rooms.members", {}, { typing: false })
      : instance.subscribe("records.recent", {});
    const perform = () => event === "update" ? subscription.update({ typing: true }) : subscription.refresh();
    await assert.rejects(perform(), { code: "NOT_READY" });
    const socket = await ready(subscription);
    const original = subscription.getState();
    const send = socket.send.bind(socket);
    socket.send = (raw) => {
      const [joinRef, ref, topic, name] = JSON.parse(raw);
      if (name !== event) return send(raw);
      queueMicrotask(() => socket.emit([joinRef, ref, topic, "phx_reply", {
        status: "error", response: { error: { code: "LIMIT_EXCEEDED", message: "Rejected", retryable: true } },
      }]));
    };
    await assert.rejects(perform(), { code: "LIMIT_EXCEEDED", retryable: true });
    socket.send = (raw) => { if (JSON.parse(raw)[3] !== event) send(raw); };
    await assert.rejects(perform(), { code: "TIMEOUT", retryable: true });
    assert.equal(subscription.getState(), original);

    if (event === "update") {
      await instance.reconnect();
      const reconnected = await ready(subscription);
      assert.deepEqual(channel(reconnected, "presence:").snapshot.state.alice[0].data, { typing: false });
    }
  });
}

function client(context, options = {}) {
  const instance = createClient({
    endpoint: "http://localhost:4000", projectId: "project", getToken: () => "rts_test",
    fetch: async () => response(identity), WebSocket: TestWebSocket,
    capabilities: ["append", "presence"], retryDelayMs: () => 10, ...options,
  });
  context.after(() => instance.close());
  return instance;
}

async function ready(...subscriptions) {
  await until(() => subscriptions.every((subscription) => subscription.getState().status === "ready"));
  return TestWebSocket.instances.at(-1);
}

function channel(socket, prefix, index = 0) {
  const [topic, joined] = [...socket.joins].filter(([topic]) => topic.startsWith(prefix))[index];
  return {
    topic, snapshot: joined.snapshot,
    send: (event, payload) => socket.emit([joined.joinRef, null, topic, event, payload]),
    messages: (event) => socket.messages.filter((message) => message.topic === topic && message.event === event),
  };
}

function sendSnapshot(target, data, seq = 2) {
  target.send("snapshot", { ...target.snapshot, data, seq });
}

for (const append of [false, true]) {
  for (const [label, changes] of [
    ["wrong protocol version", { protocol_version: 2 }],
    ["wrong subscription ID", { subscription_id: "another-subscription" }],
    ["wrong project", { project_id: "another-project" }],
    ["wrong subject", { subject_id: "bob" }],
    ["zero sequence", { seq: 0 }],
    ["unsafe sequence", { seq: Number.MAX_SAFE_INTEGER + 1 }],
    ["invalid generation", { generation: null }],
  ]) {
    test(`${append ? "append" : "snapshot"} rejects ${label} without affecting a sibling channel`, async (context) => {
      const instance = client(context);
      const target = append ? instance.subscribeAppend("feed.recent", {}) : instance.subscribe("records.recent", {});
      const sibling = instance.subscribe("records.other", {});
      const socket = await ready(target, sibling);
      const bad = channel(socket, append ? "append:" : "subscription:");
      const good = channel(socket, "subscription:", append ? 0 : 1);
      const acknowledgements = bad.messages("ack").length;
      bad.send("snapshot", { ...bad.snapshot, data: [], seq: 2, ...changes });
      assert.equal(target.getState().status, "error");
      assert.equal(target.getState().error.code, "PROTOCOL_ERROR");
      assert.equal(target.getState().data, undefined);
      assert.equal(bad.messages("ack").length, acknowledgements);
      sendSnapshot(good, ["sibling is live"]);
      assert.equal(sibling.getState().status, "ready");
      assert.deepEqual(sibling.getState().data, ["sibling is live"]);
      assert.equal(good.messages("ack").at(-1).payload.s, 2);
    });
  }
}

test("snapshot, append and presence channels share one socket with isolated state", async (context) => {
  const before = TestWebSocket.instances.length;
  const instance = client(context);
  const subscription = instance.subscribe("records.recent", {});
  const append = instance.subscribeAppend("feed.recent", {});
  const presence = instance.subscribePresence("rooms.members", {}, { page: "home" });
  const socket = await ready(subscription, append, presence);
  assert.equal(TestWebSocket.instances.length, before + 1);
  const snapshots = channel(socket, "subscription:");
  const stream = channel(socket, "append:");
  const room = channel(socket, "presence:");
  sendSnapshot(snapshots, [{ id: "record", text: "private" }]);
  stream.send("append", { g: stream.snapshot.generation, s: 2, base_cursor: "e:0", cursor: "e:1", items: [{ text: "event" }] });
  room.send("diff", { joins: { bob: [{ ref: "bob-ref", data: { page: "other" } }] }, leaves: {} });
  assert.deepEqual(subscription.getState().data, [{ id: "record", text: "private" }]);
  assert.deepEqual(append.getState().data, [{ text: "event" }]);
  assert.deepEqual(Object.keys(presence.getState().data).sort(), ["alice", "bob"]);
  assert.equal(presence.self(), "alice");
  assert.deepEqual(stream.messages("ack").at(-1).payload, { g: stream.snapshot.generation, s: 2, c: "e:1" });
  assert.equal(room.messages("ack").length, 0);
});

for (const action of ["unsubscribe", "close"]) {
  test(`${action} ignores late pushes and releases listeners`, async (context) => {
    const instance = client(context);
    const subscription = instance.subscribe("records.recent", {});
    const socket = await ready(subscription);
    const target = channel(socket, "subscription:");
    const seen = [];
    subscription.onChange((state) => seen.push(state));
    if (action === "unsubscribe") subscription.unsubscribe(); else instance.close();
    const closed = subscription.getState();
    assert.equal(closed.status, "closed");
    assert.equal(closed.data, undefined);
    const notifications = seen.length;
    const acknowledgements = target.messages("ack").length;
    sendSnapshot(target, ["late"]);
    target.send("delta", { g: target.snapshot.generation, s: 3, b: 2, p: {} });
    assert.equal(subscription.getState(), closed);
    assert.equal(seen.length, notifications);
    assert.equal(target.messages("ack").length, acknowledgements);
  });
}

test("unsubscribing from a listener skips its stale ACK while other channels continue", async (context) => {
  const instance = client(context);
  const subscription = instance.subscribe("records.recent", {});
  const sibling = instance.subscribe("records.other", {});
  const socket = await ready(subscription, sibling);
  const target = channel(socket, "subscription:");
  const other = channel(socket, "subscription:", 1);
  subscription.onChange((state) => { if (state.seq === 2 && state.status === "ready") subscription.unsubscribe(); });
  const acknowledgements = target.messages("ack").length;
  sendSnapshot(target, ["unsubscribe now"]);
  assert.equal(subscription.getState().status, "closed");
  assert.equal(target.messages("ack").length, acknowledgements);
  sendSnapshot(other, ["still connected"]);
  assert.deepEqual(sibling.getState().data, ["still connected"]);
  assert.equal(socket.readyState, 1);
});

test("removing a listener leaves the subscription active and acknowledgement working", async (context) => {
  const instance = client(context);
  const subscription = instance.subscribe("records.recent", {});
  const socket = await ready(subscription);
  const target = channel(socket, "subscription:");
  let notifications = 0;
  const remove = subscription.onChange(() => notifications++);
  assert.equal(notifications, 1);
  remove();
  remove();
  sendSnapshot(target, ["new"]);
  assert.equal(notifications, 1);
  assert.deepEqual(subscription.getState().data, ["new"]);
  assert.equal(target.messages("ack").at(-1).payload.s, 2);
  assert.equal(target.messages("phx_leave").length, 0);
});

test("oversized append batches fail only their channel without allocating a public view", async (context) => {
  const instance = client(context);
  const append = instance.subscribeAppend("feed.recent", {});
  const subscription = instance.subscribe("records.recent", {});
  const socket = await ready(append, subscription);
  const stream = channel(socket, "append:");
  const acknowledgements = stream.messages("ack").length;
  stream.send("append", { g: stream.snapshot.generation, s: 2, base_cursor: "e:0", cursor: "e:1001", items: Array(1001).fill({ text: "event" }) });
  assert.equal(append.getState().error.code, "PROTOCOL_ERROR");
  assert.equal(append.getState().data, undefined);
  assert.equal(stream.messages("ack").length, acknowledgements);
  sendSnapshot(channel(socket, "subscription:"), ["live"]);
  assert.deepEqual(subscription.getState().data, ["live"]);
});

test("malformed presence diffs leave a sibling snapshot channel usable", async (context) => {
  const instance = client(context);
  const room = instance.subscribePresence("rooms.members", {});
  const subscription = instance.subscribe("records.recent", {});
  const socket = await ready(room, subscription);
  channel(socket, "presence:").send("diff", { joins: { bob: [{ ref: "ref", data: [] }] }, leaves: {} });
  assert.equal(room.getState().error.code, "PROTOCOL_ERROR");
  sendSnapshot(channel(socket, "subscription:"), ["live"]);
  assert.deepEqual(subscription.getState().data, ["live"]);
});

test("presence keys such as __proto__ behave as ordinary subjects", async (context) => {
  const instance = client(context);
  const room = instance.subscribePresence("rooms.members", {});
  const socket = await ready(room);
  const target = channel(socket, "presence:");
  const joins = JSON.parse('{"__proto__":[{"ref":"special","data":{"active":true}}]}');
  target.send("diff", { joins, leaves: {} });
  assert.ok(Object.hasOwn(room.getState().data, "__proto__"));
  assert.deepEqual(room.getState().data.__proto__, [{ ref: "special", data: { active: true } }]);
  assert.equal({}.active, undefined);
  target.send("diff", { joins: {}, leaves: joins });
  assert.equal(Object.hasOwn(room.getState().data, "__proto__"), false);
  assert.ok(room.getState().data.alice);
});

test("retained snapshot and presence states stay immutable after later deliveries", async (context) => {
  const instance = client(context);
  const subscription = instance.subscribe("records.recent", {});
  const room = instance.subscribePresence("rooms.members", {}, { page: "home" });
  const socket = await ready(subscription, room);
  const target = channel(socket, "subscription:");
  sendSnapshot(target, [{ id: "a", nested: { text: "before" } }]);
  const previous = subscription.getState();
  const roster = room.getState();
  target.send("delta", { g: previous.generation, s: 3, b: 2, p: { c: [["a", { nested: { text: "after" } }]] } });
  channel(socket, "presence:").send("diff", { joins: { bob: [{ ref: "bob", data: {} }] }, leaves: {} });
  assert.equal(previous.data[0].nested.text, "before");
  assert.equal(subscription.getState().data[0].nested.text, "after");
  assert.deepEqual(Object.keys(roster.data), ["alice"]);
  assert.ok(Object.isFrozen(previous) && Object.isFrozen(previous.data[0].nested));
  assert.ok(Object.isFrozen(roster.data.alice[0].data));
});

test("out-of-order write success and failure remove only their own optimistic overlays", async (context) => {
  const writes = [];
  const instance = client(context, {
    fetch: async (url) => {
      if (url.endsWith("/identity")) return response(identity);
      return new Promise((resolve) => writes.push(resolve));
    },
  });
  const subscription = instance.subscribe("records.recent", {});
  const socket = await ready(subscription);
  const predict = (text) => ({ optimistic: [{ subscription, update: (items) => items.includes(text) ? items : [...items, text] }] });
  const first = instance.call("records.add", {}, predict("first"));
  const second = instance.call("records.add", {}, predict("second"));
  const third = instance.call("records.add", {}, predict("third"));
  const failed = assert.rejects(first, { code: "CONFLICT" });
  await until(() => writes.length === 3);
  writes[1](response("second saved"));
  await second;
  assert.deepEqual(subscription.getState().data, ["initial", "first", "second", "third"]);
  sendSnapshot(channel(socket, "subscription:"), ["initial", "second"]);
  assert.deepEqual(subscription.getState().data, ["initial", "second", "first", "third"]);
  assert.equal(subscription.getState().pending, 2);
  writes[0](response({ code: "CONFLICT", message: "Rejected", retryable: false }, 409));
  await failed;
  assert.deepEqual(subscription.getState().data, ["initial", "second", "third"]);
  assert.equal(subscription.getState().pending, 1);
  writes[2](response("third saved"));
  await third;
  sendSnapshot(channel(socket, "subscription:"), ["initial", "second", "third"], 3);
  assert.equal(subscription.getState().pending, undefined);
  assert.deepEqual(subscription.getState().data, ["initial", "second", "third"]);
});
