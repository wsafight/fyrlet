import test from "node:test";
import assert from "node:assert/strict";
import { selectSubscription } from "../../dist/index.js";
import { generate } from "../../scripts/generate.mjs";

test("selectors preserve snapshots and equal selected values without mutating source data", () => {
  let state = Object.freeze({ status: "ready", data: Object.freeze({ count: 1, text: "first" }), seq: 1 });
  const source = { getState: () => state, onChange: () => () => {}, refresh() {}, confirm() {}, unsubscribe() {} };
  const selected = selectSubscription(source, ({ count }) => ({ count }), (left, right) => left.count === right.count);
  const first = selected.getState();
  assert.equal(first, selected.getState());
  state = Object.freeze({ ...state, data: Object.freeze({ count: 1, text: "second" }), seq: 2 });
  const second = selected.getState();
  assert.equal(first.data, second.data);
  assert.equal(second.seq, 2);
  state = Object.freeze({ ...state, status: "closed", data: undefined });
  assert.equal(selected.getState().data, undefined);
});

test("contracts generate presence, operation categories and explicit runtime metadata", () => {
  const empty = { type: "object", additionalProperties: false };
  const result = generate({ protocol_version: 1, schema_dialect: "fyrlet-subset", operations: {
    read: { kind: "read", input: empty, output: { type: "string" } },
  }, subscriptions: {}, presence: { lobby: { input: empty }, room: { input: empty, meta: { ...empty, properties: { typing: { type: "boolean" } } } } } });
  assert.match(result, /kind: "read"/);
  assert.match(result, /presence:/);
  assert.match(result, /"typing"\?: boolean/);
  assert.match(result, /"lobby": \{ input: Record<string, never>; meta: Record<string, never>/);
  assert.match(result, /export const operationMetadata/);
});

function fixture(selector, equal) {
  let state = Object.freeze({ status: "ready", data: { count: 1 }, error: undefined, generation: "one", seq: 1 });
  const listeners = new Set();
  const calls = [];
  const source = { getState: () => state, onChange(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    async refresh() { calls.push("refresh"); }, async confirm(options) { calls.push(options); }, unsubscribe() { calls.push("unsubscribe"); } };
  const selected = selectSubscription(source, selector, equal);
  return { selected, calls, publish(changes) { state = Object.freeze({ ...state, ...changes }); for (const listener of listeners) listener(state); } };
}

test("selector listeners observe projected snapshots and detach independently", () => {
  const { selected, publish } = fixture(({ count }) => count);
  const first = [];
  const second = [];
  const stop = selected.onChange((state) => first.push(state));
  selected.onChange((state) => second.push(state));
  publish({ data: { count: 2 }, seq: 2 });
  assert.equal(first[0].data, 2);
  assert.equal(first[0], second[0]);
  stop();
  publish({ data: { count: 3 }, seq: 3 });
  assert.equal(first.length, 1);
  assert.equal(second.length, 2);
});

test("selector delegates refresh, confirmation options and unsubscribe", async () => {
  const { selected, calls } = fixture(({ count }) => count);
  const options = { signal: new AbortController().signal };
  await selected.refresh();
  await selected.confirm(options);
  selected.unsubscribe();
  assert.deepEqual(calls, ["refresh", options, "unsubscribe"]);
});

for (const [field, value] of [["status", "recovering"], ["error", new Error("denied")], ["generation", "two"],
  ["pending", 1], ["cursor", "opaque-cursor"]]) {
  test(`selectors retain equal data while exposing changed ${field}`, () => {
    const { selected, publish } = fixture(({ count }) => ({ count }), (left, right) => left.count === right.count);
    const before = selected.getState();
    publish({ [field]: value });
    const after = selected.getState();
    assert.notEqual(before, after);
    assert.equal(after.data, before.data);
    assert.equal(after[field], value);
    assert.ok(Object.isFrozen(after));
  });
}

test("selector skips absent private data and recomputes after logout and relogin", () => {
  const inputs = [];
  const { selected, publish } = fixture((data) => { inputs.push(data); return data.count; });
  assert.equal(selected.getState().data, 1);
  publish({ data: undefined, status: "closed" });
  assert.equal(selected.getState().data, undefined);
  assert.equal(inputs.length, 1);
  publish({ data: { count: 2 }, status: "ready" });
  assert.equal(selected.getState().data, 2);
  assert.equal(inputs.length, 2);
});

test("default equality preserves falsy selections and unchanged snapshots", () => {
  for (const value of [false, 0, "", null]) {
    const { selected, publish } = fixture(() => value);
    const first = selected.getState();
    publish({ data: { count: 2 } });
    assert.equal(selected.getState(), first);
    assert.equal(first.data, value);
  }
});

test("a throwing selector can recover after a corrected source snapshot", () => {
  const { selected, publish } = fixture(({ count }) => { if (count === 1) throw new Error("invalid projection"); return count; });
  assert.throws(() => selected.getState(), /invalid projection/);
  publish({ data: { count: 2 } });
  assert.equal(selected.getState().data, 2);
});
