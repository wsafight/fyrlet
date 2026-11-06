import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { configuration } from "../lib/config.mjs";
import { summary, assertView, assertCompleteView, payload, series } from "../lib/stats.mjs";
import { cpuMilliseconds, processTree, resourceTrend } from "../lib/resources.mjs";
import { pacedLoad, capacityVerdict } from "../lib/load.mjs";
import { runScenario } from "../lib/scenario.mjs";
import { pool } from "../lib/async.mjs";
import { DDPConnection, decodeFields } from "../adapters/meteor.mjs";
import { markdown } from "../report.mjs";
import { schedulerOptions, sourceFingerprint, verifySourceFingerprint } from "../lib/manifest.mjs";
import { comparisonAssessment } from "../lib/comparison.mjs";

test("runtime metadata only records scheduler options and excludes unrelated VM secrets", () => {
  assert.deepEqual(schedulerOptions({ ERL_FLAGS: "+sbwt none -setcookie secret +S 4:4", ERL_AFLAGS: "+sbwtdcpu none" }), [
    { source: "ERL_AFLAGS", flag: "+sbwtdcpu", value: "none" },
    { source: "ERL_FLAGS", flag: "+sbwt", value: "none" },
    { source: "ERL_FLAGS", flag: "+S", value: "4:4" },
  ]);
});
import { trafficMeter } from "../lib/transport.mjs";

test("workload validation rejects misleading or excessive configurations", () => {
  assert.throws(() => configuration(["--rows", "101"]), /rows/);
  assert.throws(() => configuration(["--users", "1000", "--devices", "100"]), /limited/);
  assert.throws(() => configuration(["--users", "2.5"]), /integer/);
  assert.throws(() => configuration(["--users", "5001"]), /integer/);
  assert.equal(configuration(["--users", "5000", "--devices", "1"]).scenarios[0].users, 5000);
  assert.throws(() => configuration(["--scenario", "unknown"]), /scenario/);
  assert.throws(() => configuration(["--profile", "unknown"]), /profile/);
  assert.throws(() => configuration(["--sessions", "unknown"]), /sessions/);
  assert.equal(configuration(["--sessions", "device"]).sessions, "device");
  const config = configuration(["--profile", "smoke", "--scenario", "fanout"]);
  assert.equal(config.scenarios[0].users, 1);
  assert.equal(config.rows, 5);
  assert.equal(config.repeats, 1);
  assert.equal(configuration(["--scenario", "soak"]).rate, 100);
  assert.equal(configuration([]).scenarios.some((scenario) => scenario.name === "soak"), false);
  assert.throws(() => configuration(["--scenario", "soak", "--rate", "10000", "--duration-ms", "600000"]), /offered/);
});

test("bounded series retains exact counts and extrema when samples are capped", () => {
  const values = series(2, () => 0.999);
  for (const value of [1, 2, 30, 40]) values.record(value);
  assert.deepEqual(values.samples, [1, 2]);
  assert.equal(values.summary().count, 4);
  assert.equal(values.summary().max, 40);
  assert.equal(values.summary().mean, 18.25);
  assert.equal(values.summary().percentiles, "uniform reservoir sample");
  assert.equal(resourceTrend([{ elapsedMs: 0, rss: 10 }, { elapsedMs: 60000, rss: 30 }], "rss").rssTrendBytesPerMinute, 20);
});

test("paced load reports unserved slots without accumulating a request queue", async () => {
  let concurrent = 0;
  let peak = 0;
  const load = await pacedLoad({ items: [1, 2], rate: 200, durationMs: 100, concurrency: 1,
    task: async () => {
      concurrent++;
      peak = Math.max(peak, concurrent);
      await new Promise((resolve) => setTimeout(resolve, 18));
      concurrent--;
    } });
  assert.equal(peak, 1);
  assert.equal(load.offered, 20);
  assert.equal(load.dispatched + load.busyDropped + load.concurrencyDropped + load.generatorDropped, 20);
  assert.ok(load.busyDropped + load.concurrencyDropped > 0);
  await assert.rejects(pacedLoad({ items: [1], rate: 10, durationMs: 100, concurrency: 1,
    task: () => { throw new Error("write failed"); } }), /write failed/);
});

test("capacity verdict cannot call a low-coverage or generator-limited result a pass", () => {
  const result = { success: true, measurementValidity: { valid: true }, propagationMs: { p95: 5 }, deliveryCoverage: 1, completedWrites: 100,
    pacedLoad: { offered: 100, dispatched: 100 } };
  assert.equal(capacityVerdict(result).pass, true);
  assert.equal(capacityVerdict({ ...result, deliveryCoverage: 0.5 }).pass, false);
  assert.equal(capacityVerdict({ ...result, pacedLoad: { offered: 200, dispatched: 100 } }).pass, false);
  assert.equal(capacityVerdict({ ...result, success: false }).pass, false);
  assert.equal(capacityVerdict({ ...result, measurementValidity: { valid: false } }).pass, false);
});

test("DDP resumes with message counts, resets rejected sessions and closes gracefully", () => {
  const connection = new DDPConnection("http://localhost", {}, 100);
  const sent = [];
  connection.socket = { readyState: 1, send: (message) => sent.push(JSON.parse(message)), close() {} };
  connection.receive({ msg: "connected", session: "old" });
  connection.subscriptionId = "sub";
  connection.receive({ msg: "added", id: "one", fields: { text: "old" } });
  connection.receive({ msg: "ready", subs: ["sub"] });
  const beforePing = connection.receivedCount;
  connection.receive({ msg: "ping" });
  assert.equal(connection.receivedCount, beforePing);
  connection.receive({ msg: "connected", session: "old" });
  assert.equal(connection.resumed, true);
  assert.equal(connection.state.data[0].text, "old");
  connection.receive({ msg: "changed", id: "one", fields: { text: "new" } });
  assert.equal(connection.state.data[0].text, "new");
  connection.receive({ msg: "connected", session: "new" });
  assert.equal(connection.resumed, false);
  assert.equal(connection.records.size, 0);
  assert.equal(connection.receivedCount, 1);
  connection.close();
  assert.deepEqual(sent.at(-1), { msg: "disconnect" });
});

test("delivery accounting survives pruning completed markers and duplicate notifications", async () => {
  let record = { id: "one", text: "initial", version: 1 };
  const listeners = new Set();
  const adapter = { connect: async () => ({
    getState: () => ({ status: "ready", data: [record] }),
    onChange: (listener) => { listeners.add(listener); return () => listeners.delete(listener); },
    update: async (item, text) => {
      record = { ...item, text, version: item.version + 1 };
      for (const listener of listeners) for (let repeat = 0; repeat < 2; repeat++) listener({ status: "ready", data: [record] });
      return record;
    },
    close() {},
  }) };
  const config = configuration(["--scenario", "fanout", "--rows", "1", "--devices", "2", "--writes", "3", "--warmup", "0"]);
  const result = await runScenario(adapter, { run_id: "bench-test", users: [{ ids: ["one"] }] }, config, config.scenarios[0], 1);
  assert.equal(result.success, true);
  assert.equal(result.expectedDeliveries, 6);
  assert.equal(result.observedDeliveries, 6);
  assert.equal(result.deliveryCoverage, 1);
  assert.equal(result.pendingDeliveries.remainingMarkers, 0);
  assert.equal(result.pendingDeliveries.peakMarkers, 1);
  assert.equal(result.connections.total, 3);
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
  assert.doesNotThrow(() => assertCompleteView([...expected].reverse(), expected));
  assert.throws(() => assertCompleteView([{ ...expected[0], archived: true }, expected[1]], expected));
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

test("matching workloads and host metadata cannot establish an equal-resource comparison", () => {
  const environment = { hostname: "test", platform: "linux", release: "test", arch: "arm64", cpu: "test", logicalCpus: 4,
    totalMemoryBytes: 1073741824, generatorNode: "v24", sourceFingerprint: { digest: "a".repeat(64) } };
  const results = [{ repetition: 1, workload: { users: 100, devices: 2, sessions: "shared", timeoutMs: 30000, offeredRate: 200 } }];
  const runs = ["fyrlet", "meteor"].map((target) => ({ target, environment, results }));
  const assessment = comparisonAssessment(runs);
  assert.equal(assessment.status, "observational-only");
  assert.equal(assessment.workloadsMatch, true);
  assert.equal(assessment.sourceMatches, true);
  assert.equal(assessment.hostsMatch, true);
  assert.ok(assessment.reasons.some((reason) => reason.includes("not CPU quotas")));
  assert.ok(assessment.reasons.some((reason) => reason.includes("guarantees")));
  for (const [field, value] of [["sessions", "device"], ["timeoutMs", 15000], ["offeredRate", 500]]) {
    const changed = { ...runs[1], results: [{ ...results[0], workload: { ...results[0].workload, [field]: value } }] };
    assert.equal(comparisonAssessment([runs[0], changed]).workloadsMatch, false);
  }
  assert.equal(comparisonAssessment([runs[0], { ...runs[1], results: [...results, { ...results[0], repetition: 2 }] }]).workloadsMatch, false);
  assert.equal(comparisonAssessment([runs[0], { ...runs[1], environment: { ...environment, cpu: "other" } }]).hostsMatch, false);
  assert.equal(comparisonAssessment([runs[0], { ...runs[1], environment: { ...environment, sourceFingerprint: { digest: "b".repeat(64) } } }]).sourceMatches, false);
  const incomplete = comparisonAssessment([{ target: "fyrlet", results: [] }, { target: "meteor", results: [] }]);
  assert.equal(incomplete.workloadsMatch, false);
  assert.equal(incomplete.sourceMatches, false);
  assert.equal(incomplete.hostsMatch, false);
  const report = markdown(runs.map((run) => ({ ...run, results: [] })));
  assert.match(report, /observational-only/);
  assert.match(report, /not CPU quotas/);
});

test("source verification rejects changes between benchmark targets", async (context) => {
  const root = await mkdtemp(join(tmpdir(), "fyrlet-bench-source-"));
  context.after(() => rm(root, { recursive: true, force: true }));
  for (const directory of ["lib", "config", "priv/repo/migrations", "sdks/typescript/src", "bench"]) {
    await mkdir(join(root, directory), { recursive: true });
  }
  for (const file of ["mix.exs", "mix.lock", "sdks/typescript/package-lock.json", "lib/example.ex"]) {
    await writeFile(join(root, file), "initial");
  }
  const fingerprint = await sourceFingerprint(root);
  await verifySourceFingerprint(root, fingerprint);
  await writeFile(join(root, "lib/example.ex"), "changed");
  await assert.rejects(verifySourceFingerprint(root, fingerprint), /source changed/);
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
