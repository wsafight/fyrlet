import test, { beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { createElement, StrictMode, Suspense, act } from "react";
import { createRoot, hydrateRoot } from "react-dom/client";
import { renderToString } from "react-dom/server";
import { FyrletProvider, useFyrletClient, useQuery } from "../dist/index.js";
import { QueryStore } from "../dist/store.js";

let dom;
let roots;
beforeEach(() => {
  roots = new Set();
  dom = new JSDOM("<div id='root'></div>", { url: "http://localhost" });
  globalThis.window = dom.window;
  globalThis.document = dom.window.document;
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
});
afterEach(async () => {
  for (const root of roots) await act(() => root.unmount());
  dom.window.close();
  delete globalThis.window;
  delete globalThis.document;
});

function fakeClient() {
  const subscriptions = [];
  const client = { subscriptions, subscribe(name, params) {
    let state = Object.freeze({ status: "connecting", data: undefined, error: undefined, generation: undefined, seq: 0 });
    const listeners = new Set();
    const source = { name, params, closed: false, releases: 0, get listeners() { return listeners.size; }, getState: () => state,
      onChange(listener) { listeners.add(listener); listener(state); return () => listeners.delete(listener); },
      publish(data, status = "ready") { state = Object.freeze({ ...state, data, status, seq: state.seq + 1 }); for (const listener of listeners) listener(state); },
      unsubscribe() { source.closed = true; source.releases++; listeners.clear(); }, refresh: async () => {}, confirm: async () => {} };
    subscriptions.push(source);
    return source;
  }, subscribeAppend(name, params) { const source = client.subscribe(name, params); source.append = true; return source; } };
  return client;
}

function Component({ params = {}, select, client, label = "query", mode }) {
  const provided = useFyrletClient();
  const state = useQuery(client ?? provided, "records", params, { select, mode });
  return createElement("div", { "data-label": label }, `${state.status}:${JSON.stringify(state.data)}`);
}
const tree = (client, ...children) => createElement(FyrletProvider, { client }, ...children);

test("equal queries share a subscription, release independently and clean the last reference", async () => {
  const client = fakeClient();
  const root = createRoot(document.getElementById("root"));
  await act(() => root.render(tree(client, createElement(Component, { key: "one", params: { limit: 2, filter: {} } }), createElement(Component, { key: "two", params: { filter: {}, limit: 2 } }))));
  assert.equal(client.subscriptions.length, 1);
  await act(() => client.subscriptions[0].publish(["shared"]));
  assert.equal(document.querySelectorAll("[data-label]").length, 2);
  assert.ok(document.body.textContent.includes('ready:["shared"]'));
  await act(() => root.render(tree(client, createElement(Component, { key: "two", params: { filter: {}, limit: 2 } }))));
  assert.equal(client.subscriptions[0].closed, false);
  await act(() => root.unmount());
  assert.equal(client.subscriptions[0].closed, true);
});

test("Strict Mode and parameter changes leave only the active query", async () => {
  const client = fakeClient();
  const root = createRoot(document.getElementById("root"));
  await act(() => root.render(createElement(StrictMode, null, tree(client, createElement(Component, { params: { limit: 1 } })))));
  assert.equal(client.subscriptions.filter((source) => !source.closed).length, 1);
  await act(() => root.render(createElement(StrictMode, null, tree(client, createElement(Component, { params: { limit: 2 } })))));
  assert.equal(client.subscriptions.filter((source) => !source.closed).length, 1);
  assert.equal(client.subscriptions.filter((source) => !source.closed)[0].params.limit, 2);
  await act(() => root.unmount());
  assert.ok(client.subscriptions.every((source) => source.closed));
});

test("selectors update and reconnect or logout clears private data", async () => {
  const client = fakeClient();
  const root = createRoot(document.getElementById("root"));
  await act(() => root.render(tree(client, createElement(Component, { select: (items) => items.length }))));
  const source = client.subscriptions[0];
  await act(() => source.publish(["private", "record"]));
  assert.equal(document.body.textContent, "ready:2");
  await act(() => source.publish(undefined, "recovering"));
  assert.equal(document.body.textContent, "recovering:undefined");
  await act(() => source.publish([], "ready"));
  assert.equal(document.body.textContent, "ready:0");
  await act(() => source.publish(undefined, "closed"));
  assert.equal(document.body.textContent, "closed:undefined");
  await act(() => root.unmount());
});

test("different clients and transmission modes never share private state", async () => {
  const first = fakeClient();
  const second = fakeClient();
  const root = createRoot(document.getElementById("root"));
  await act(() => root.render(tree(first, createElement(Component), createElement(Component, { client: second }), createElement(Component, { mode: "append" }))));
  assert.equal(first.subscriptions.length, 2);
  assert.equal(second.subscriptions.length, 1);
  await act(() => root.unmount());
  assert.ok([...first.subscriptions, ...second.subscriptions].every((source) => source.closed));
});

test("SSR makes no subscriptions and hydrates from the same empty snapshot", async () => {
  const client = fakeClient();
  const element = tree(client, createElement(Component));
  const markup = renderToString(element);
  assert.equal(client.subscriptions.length, 0);
  document.getElementById("root").innerHTML = markup;
  const errors = [];
  let root;
  await act(() => { root = hydrateRoot(document.getElementById("root"), element, { onRecoverableError: (error) => errors.push(error) }); });
  assert.deepEqual(errors, []);
  assert.equal(client.subscriptions.length, 1);
  await act(() => client.subscriptions[0].publish(["hydrated"]));
  assert.ok(document.body.textContent.includes("hydrated"));
  await act(() => root.unmount());
});

test("abandoned renders do not allocate subscriptions", async () => {
  const client = fakeClient();
  const root = createRoot(document.getElementById("root"));
  function Abandoned() { useQuery(client, "records", {}); throw new Promise(() => {}); }
  await act(() => root.render(createElement(Suspense, { fallback: "waiting" }, tree(client, createElement(Abandoned)))));
  assert.equal(client.subscriptions.length, 0);
  await act(() => root.unmount());
});

test("query storage is bounded and final release frees capacity immediately", () => {
  const client = fakeClient();
  const releases = Array.from({ length: 100 }, (_, index) => new QueryStore(client, "records", { index }, "snapshot").subscribe(() => {}));
  const overflow = new QueryStore(client, "records", { index: 100 }, "snapshot");
  assert.throws(() => overflow.subscribe(() => {}), /100 active entries/);
  releases.pop()();
  const stop = overflow.subscribe(() => {});
  assert.equal(overflow.getSnapshot(), overflow.getSnapshot());
  stop();
  for (const release of releases) release();
  assert.ok(client.subscriptions.every((source) => source.closed));
});

function mountedRoot() {
  const root = createRoot(document.getElementById("root"));
  roots.add(root);
  return root;
}

test("reading the client outside a Provider reports the missing boundary", () => {
  function MissingProvider() { useFyrletClient(); return null; }
  assert.throws(() => renderToString(createElement(MissingProvider)), /requires FyrletProvider/);
});

test("a direct client supports useQuery without a Provider and exposes its live subscription", async () => {
  const client = fakeClient();
  const root = mountedRoot();
  let result;
  function Direct() { result = useQuery(client, "records", {}); return result.status; }
  await act(() => root.render(createElement(Direct)));
  await act(() => client.subscriptions[0].publish(["direct"]));
  assert.equal(result.subscription, client.subscriptions[0]);
  assert.deepEqual(result.data, ["direct"]);
  assert.ok(Object.isFrozen(result));
});

test("switching the Provider client releases old data and ignores late old deliveries", async () => {
  const first = fakeClient();
  const second = fakeClient();
  const root = mountedRoot();
  await act(() => root.render(tree(first, createElement(Component))));
  await act(() => first.subscriptions[0].publish(["alice-private"]));
  assert.ok(document.body.textContent.includes("alice-private"));
  await act(() => root.render(tree(second, createElement(Component))));
  assert.equal(document.body.textContent, "connecting:undefined");
  assert.equal(first.subscriptions[0].closed, true);
  assert.equal(first.subscriptions[0].listeners, 0);
  await act(() => first.subscriptions[0].publish(["stale-private"]));
  assert.equal(document.body.textContent, "connecting:undefined");
  await act(() => second.subscriptions[0].publish(["bob-private"]));
  assert.equal(document.body.textContent, 'ready:["bob-private"]');
});

test("a Provider releases subscriptions while leaving its caller-owned client open", async () => {
  const client = fakeClient();
  let closes = 0;
  client.close = () => { closes++; };
  const root = createRoot(document.getElementById("root"));
  await act(() => root.render(createElement(StrictMode, null, tree(client, createElement(Component)))));
  await act(() => root.unmount());
  assert.equal(closes, 0);
  assert.ok(client.subscriptions.every((source) => source.closed && source.releases === 1));
});

test("switching a query name or delivery mode drops the old snapshot and subscription", async () => {
  const client = fakeClient();
  const root = mountedRoot();
  function Named({ name, mode }) { const state = useQuery(client, name, {}, { mode }); return `${state.status}:${JSON.stringify(state.data)}`; }
  await act(() => root.render(createElement(Named, { name: "first" })));
  await act(() => client.subscriptions[0].publish(["first-private"]));
  await act(() => root.render(createElement(Named, { name: "second" })));
  assert.equal(client.subscriptions[0].closed, true);
  assert.equal(document.body.textContent, "connecting:undefined");
  await act(() => client.subscriptions[1].publish(["second-private"]));
  await act(() => root.render(createElement(Named, { name: "second", mode: "append" })));
  assert.equal(client.subscriptions[1].closed, true);
  assert.equal(client.subscriptions[2].append, true);
  assert.equal(document.body.textContent, "connecting:undefined");
});

test("equal selector values retain their reference and changing a selector uses current data", async () => {
  const client = fakeClient();
  const root = mountedRoot();
  const length = (items) => ({ value: items.length });
  const first = (items) => ({ value: items[0] });
  const equal = (left, right) => left.value === right.value;
  let result;
  function Selected({ select }) { result = useQuery(client, "records", {}, { select, isEqual: equal }); return JSON.stringify(result.data); }
  await act(() => root.render(createElement(Selected, { select: length })));
  await act(() => client.subscriptions[0].publish(["one"]));
  const previous = result.data;
  await act(() => client.subscriptions[0].publish(["two"]));
  assert.equal(result.data, previous);
  await act(() => root.render(createElement(Selected, { select: first })));
  assert.deepEqual(result.data, { value: "two" });
  assert.equal(client.subscriptions.length, 1);
});

test("rerendering structurally equal nested parameters keeps the subscription and data", async () => {
  const client = fakeClient();
  const root = mountedRoot();
  await act(() => root.render(tree(client, createElement(Component, { params: { filter: { tags: ["a", "b"], archived: false }, limit: 2 } }))));
  await act(() => client.subscriptions[0].publish(["retained"]));
  await act(() => root.render(tree(client, createElement(Component, { params: { limit: 2, filter: { archived: false, tags: ["a", "b"] } } }))));
  assert.equal(client.subscriptions.length, 1);
  assert.equal(document.body.textContent, 'ready:["retained"]');
});

test("unmounting one selected consumer removes only its own listener", async () => {
  const client = fakeClient();
  const root = mountedRoot();
  const count = (items) => items.length;
  await act(() => root.render(tree(client, createElement(Component, { key: "count", select: count }), createElement(Component, { key: "list" }))));
  assert.equal(client.subscriptions[0].listeners, 2);
  await act(() => root.render(tree(client, createElement(Component, { key: "list" }))));
  assert.equal(client.subscriptions[0].listeners, 1);
  assert.equal(client.subscriptions[0].closed, false);
  await act(() => client.subscriptions[0].publish(["still-live"]));
  assert.equal(document.body.textContent, 'ready:["still-live"]');
});

test("repeated parameter switches and remounts release every unused subscription", async () => {
  const client = fakeClient();
  const root = createRoot(document.getElementById("root"));
  for (let index = 0; index < 120; index++) {
    await act(() => root.render(tree(client, createElement(Component, { params: { index } }))));
    assert.equal(client.subscriptions.filter((source) => !source.closed).length, 1);
  }
  await act(() => root.unmount());
  assert.equal(client.subscriptions.length, 120);
  assert.ok(client.subscriptions.every((source) => source.closed && source.releases === 1 && source.listeners === 0));
});

test("server rendering stays empty even when the same client's query already has private data", () => {
  const client = fakeClient();
  const store = new QueryStore(client, "records", {}, "snapshot");
  const stop = store.subscribe(() => {});
  client.subscriptions[0].publish(["private-cached"]);
  const markup = renderToString(tree(client, createElement(Component)));
  assert.ok(markup.includes("connecting:undefined"));
  assert.ok(!markup.includes("private-cached"));
  assert.equal(client.subscriptions.length, 1);
  stop();
});

test("query parameters are copied before commit and invalid JSON never allocates a subscription", () => {
  const client = fakeClient();
  const params = { filter: { value: "original" } };
  const store = new QueryStore(client, "records", params, "snapshot");
  params.filter.value = "mutated";
  const stop = store.subscribe(() => {});
  assert.deepEqual(client.subscriptions[0].params, { filter: { value: "original" } });
  stop();
  const cycle = {}; cycle.self = cycle;
  for (const value of [cycle, { value: undefined }, { value: Infinity }, { value: new Date() }, { text: "界".repeat(22_000) }]) {
    assert.throws(() => new QueryStore(client, "records", value, "snapshot"), TypeError);
  }
  assert.equal(client.subscriptions.length, 1);
});

test("release is idempotent and a remount never receives the released private snapshot", () => {
  const client = fakeClient();
  const store = new QueryStore(client, "records", {}, "snapshot");
  const stop = store.subscribe(() => {});
  client.subscriptions[0].publish(["private"]);
  stop();
  stop();
  assert.equal(client.subscriptions[0].releases, 1);
  assert.equal(store.getSubscription(), undefined);
  assert.equal(store.getSnapshot().data, undefined);
  const next = store.subscribe(() => {});
  assert.equal(store.getSnapshot().data, undefined);
  assert.equal(client.subscriptions.length, 2);
  next();
});

test("shared consumers can join at capacity without consuming another query slot", () => {
  const client = fakeClient();
  const releases = Array.from({ length: 100 }, (_, index) => new QueryStore(client, "records", { index }, "snapshot").subscribe(() => {}));
  const duplicate = new QueryStore(client, "records", { index: 0 }, "snapshot");
  const stop = duplicate.subscribe(() => {});
  assert.equal(client.subscriptions.length, 100);
  releases[0]();
  assert.equal(client.subscriptions[0].closed, false);
  stop();
  assert.equal(client.subscriptions[0].closed, true);
  for (const release of releases.slice(1)) release();
});
