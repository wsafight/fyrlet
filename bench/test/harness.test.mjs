import test from "node:test";
import assert from "node:assert/strict";
import { configuration } from "../lib/config.mjs";
import { summary, assertView, payload } from "../lib/stats.mjs";
import { cpuMilliseconds, processTree } from "../lib/resources.mjs";
import { pool } from "../lib/async.mjs";
import { DDPConnection, decodeFields } from "../adapters/meteor.mjs";
import { markdown } from "../report.mjs";
import { trafficMeter } from "../lib/transport.mjs";

test("workload validation rejects misleading or excessive configurations", () => {
  assert.throws(() => configuration(["--rows", "101"]), /rows/);
  assert.throws(() => configuration(["--users", "1000", "--devices", "100"]), /limited/);
  assert.throws(() => configuration(["--users", "2.5"]), /integer/);
  assert.throws(() => configuration(["--scenario", "unknown"]), /scenario/);
  assert.throws(() => configuration(["--profile", "unknown"]), /profile/);
  const config = configuration(["--profile", "smoke", "--scenario", "fanout"]);
  assert.equal(config.scenarios[0].users, 1);
  assert.equal(config.rows, 5);
  assert.equal(config.repeats, 1);
});

test("percentiles use nearest rank and empty measurements remain missing", () => {
  assert.equal(summary([]).p95, null);
  assert.deepEqual(summary([10, 1, 5, 2]), { count: 4, min: 1, p50: 2, p95: 10, p99: 10, max: 10, mean: 4.5 });
  assert.equal(Buffer.byteLength(payload("sample:", 128)), 128);
});

test("correctness compares complete committed views and detects leakage or stale versions", () => {
  const expected = [{ id: "one", text: "value", version: 2 }, { id: "two", text: "other", version: 1 }];
  assert.doesNotThrow(() => assertView([...expected].reverse(), expected));
  assert.throws(() => assertView([expected[0]], expected));
  assert.throws(() => assertView([{ ...expected[0], version: 1 }, expected[1]], expected));
  assert.throws(() => assertView([...expected, { id: "foreign", text: "private", version: 1 }], expected));
});

test("resource accounting parses macOS/Linux CPU times and walks descendants", () => {
  assert.equal(cpuMilliseconds("02:03.45"), 123450);
  assert.equal(cpuMilliseconds("01:02:03"), 3723000);
  assert.equal(cpuMilliseconds("1-01:02:03"), 90123000);
  const rows = [{ pid: 1, parent: 0 }, { pid: 2, parent: 1 }, { pid: 3, parent: 2 }, { pid: 4, parent: 0 }];
  assert.deepEqual(processTree(rows, 2).map((row) => row.pid), [2, 3]);
  assert.deepEqual(processTree(rows, 0), []);
});

test("pool waits for in-flight cleanup after a failure and preserves result ordering", async () => {
  assert.deepEqual(await pool([3, 2, 1], 2, async (value) => value * 2), [6, 4, 2]);
  let cleaned = false;
  await assert.rejects(pool([0, 1, 2], 2, async (value) => {
    if (value === 0) { await new Promise((resolve) => setTimeout(resolve, 10)); cleaned = true; }
    else throw new Error("failure");
  }), /failure/);
  assert.equal(cleaned, true);
});

test("DDP applies EJSON dates, deltas, cleared fields and removals before emitting a view", () => {
  const connection = new DDPConnection("http://localhost", {}, 100);
  connection.subscriptionId = "sub";
  connection.receive({ msg: "added", id: "record", fields: { text: "old", version: 1, inserted_at: { $date: 0 }, updated_at: { $date: 0 }, optional: "gone" } });
  assert.equal(connection.state.status, "connecting");
  connection.receive({ msg: "ready", subs: ["sub"] });
  assert.equal(connection.state.data[0].inserted_at, "1970-01-01T00:00:00.000Z");
  connection.receive({ msg: "changed", id: "record", fields: { text: "new", version: 2 }, cleared: ["optional"] });
  assert.equal(connection.state.data[0].text, "new");
  assert.equal("optional" in connection.state.data[0], false);
  connection.receive({ msg: "removed", id: "record" });
  assert.deepEqual(connection.state.data, []);
  assert.deepEqual(decodeFields({ text: "normal" }), { text: "normal" });
});

test("DDP methods wait for both result and updated in either arrival order", async () => {
  for (const order of [["result", "updated"], ["updated", "result"]]) {
    const connection = new DDPConnection("http://localhost", {}, 100);
    let sent;
    connection.socket = { send: (data) => { sent = JSON.parse(data); }, close: () => {} };
    const response = connection.call("test", []);
    let resolved = false;
    response.then(() => { resolved = true; });
    for (const [index, kind] of order.entries()) {
      connection.receive(kind === "result" ? { msg: kind, id: sent.id, result: 42 } : { msg: kind, methods: [sent.id] });
      await Promise.resolve();
      assert.equal(resolved, index === 1);
    }
    assert.equal(await response, 42);
    connection.close();
  }
});

test("report retains protocol differences and missing samples rather than declaring a winner", () => {
  const result = markdown([{ target: "meteor", label: "test|label", results: [], environment: {}, capabilities: { client: "raw DDP" }, measurement: {} }]);
  assert.match(result, /raw DDP/);
  assert.match(result, /No automatic winner/);
  assert.match(result, /test label/);
});

test("transport counts payload bytes and delays consumption without dropping queued messages", async (context) => {
  const original = globalThis.WebSocket;
  const sockets = [];
  globalThis.WebSocket = class extends EventTarget {
    readyState = 1;
    constructor() { super(); sockets.push(this); }
    send() {}
    close() { this.readyState = 3; this.dispatchEvent(new Event("close")); }
  };
  context.after(() => { globalThis.WebSocket = original; });
  const network = trafficMeter();
  const socket = new network.WebSocket("ws://localhost");
  const messages = [];
  socket.onmessage = (event) => messages.push(event.data);
  network.slow(5);
  sockets[0].dispatchEvent(new MessageEvent("message", { data: "first" }));
  sockets[0].dispatchEvent(new MessageEvent("message", { data: "second" }));
  socket.send("你好");
  assert.deepEqual(messages, []);
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.deepEqual(messages, ["first", "second"]);
  assert.equal(network.snapshot().socketReceived, 11);
  assert.equal(network.snapshot().socketSent, 6);
  assert.equal(network.snapshot().queuedPeak, 2);
  network.reset();
  assert.equal(network.snapshot().socketReceived, 0);
  network.disconnect();
});

test("DDP ignores a late close from the socket replaced during reconnect", async () => {
  const sockets = [];
  const network = { WebSocket: class {
    constructor() { sockets.push(this); queueMicrotask(() => this.onopen()); }
    send(data) {
      if (JSON.parse(data).msg === "connect") this.onmessage({ data: JSON.stringify({ msg: "connected" }) });
    }
    close() {}
  } };
  const connection = new DDPConnection("http://localhost", network, 100);
  await connection.open();
  await connection.open();
  sockets[0].onclose();
  assert.equal(connection.connected, true);
  assert.notEqual(connection.state.status, "error");
  connection.close();
});
