import test from "node:test";
import assert from "node:assert/strict";
import { mixedWindow, runMixedScenario } from "../lib/mixed.mjs";
import { configuration } from "../lib/config.mjs";
import { scanConfiguration } from "../fair/scan.mjs";

test("mixed windows preserve PostgreSQL microsecond ordering, exclude archived rows and refill", () => {
  const first = { id: "first", inserted_at: "2026-11-08T01:00:00.000001Z", archived: false };
  const second = { id: "second", inserted_at: "2026-11-08T01:00:00.000002Z", archived: false };
  assert.deepEqual(mixedWindow([first, second], 1), [second]);
  assert.deepEqual(mixedWindow([first, { ...second, archived: true }], 1), [first]);
});

test("mixed load is explicit and density scans reject excessive observer counts", () => {
  assert.equal(configuration(["--scenario", "mixed"]).scenarios[0].mode, "mixed");
  assert.equal(configuration([]).scenarios.some((scenario) => scenario.name === "mixed"), false);
  assert.throws(() => configuration(["--target", "meteor", "--scenario", "mixed"]), /Fyrlet-only/);
  const config = scanConfiguration(["--users", "10,100", "--devices", "1,5", "--scenario", "mixed"]);
  assert.deepEqual(config.users, [10, 100]);
  assert.deepEqual(config.devices, [1, 5]);
  assert.throws(() => scanConfiguration(["--users", "1000", "--devices", "10"]), /5000/);
});

test("mixed runner validates add/update/archive/restore/delete, history and view confirmations", async () => {
  const rows = new Map([["seed", { id: "seed", text: "seed", version: 1, archived: false, inserted_at: "2026-11-08T00:00:00.000000Z" }]]);
  const observers = new Set();
  let counter = 0;
  const emit = () => { for (const listener of observers) listener({ status: "ready", data: mixedWindow(rows.values(), 1) }); };
  const adapter = { async connect() { return {
    getState: () => ({ status: "ready", data: mixedWindow(rows.values(), 1) }),
    onChange(listener) { observers.add(listener); return () => observers.delete(listener); },
    async history() { return { items: [...rows.values()], next_cursor: null }; },
    async add(text) { const item = { id: String(counter++), text, version: 1, archived: false, inserted_at: "2026-11-08T01:00:00.000000Z" }; rows.set(item.id, item); emit(); return item; },
    async update(item, text) { const updated = { ...item, text, version: item.version + 1 }; rows.set(item.id, updated); emit(); return updated; },
    async archive(item, archived) { const updated = { ...item, archived, version: item.version + 1 }; rows.set(item.id, updated); emit(); return updated; },
    async remove(item) { rows.delete(item.id); emit(); return { id: item.id, deleted: true }; },
    async confirm() {}, close() {},
  }; } };
  const config = { ...configuration(["--profile", "smoke", "--scenario", "mixed", "--users", "1", "--devices", "1", "--rows", "1", "--rate", "20", "--duration-ms", "500", "--settle-ms", "0"]), target: "fyrlet" };
  const result = await runMixedScenario(adapter, { run_id: "mixed-test", users: [{ ids: ["seed"] }] }, config, config.scenarios[0], 1);
  assert.equal(result.success, true, JSON.stringify(result.errors));
  assert.equal(result.completedWrites, result.pacedLoad.dispatched);
  assert.equal(result.deliveryCoverage, 1);
  for (const name of ["add", "update", "archive", "restore", "delete", "history", "confirmations"]) assert.ok(result.operations[name] > 0, name);
  assert.equal(observers.size, 0);
});
