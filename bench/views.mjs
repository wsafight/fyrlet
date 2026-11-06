import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { performance } from "node:perf_hooks";
import { applyDelta, immutable } from "../sdks/typescript/dist/delta.js";

const iterations = Number(process.env.BENCH_VIEW_ITERATIONS ?? 10_000);
if (!Number.isSafeInteger(iterations) || iterations < 1 || iterations > 100_000) throw new Error("Invalid iteration count");
const samples = [];

for (let repetition = 1; repetition <= 5; repetition += 1) {
  for (const rows of repetition % 2 === 0 ? [100, 50] : [50, 100]) {
    const initial = immutable(Array.from({ length: rows }, (_, index) => ({
      id: `record-${index}`, text: "initial".padEnd(128, "x"), version: 0,
    })));
    let data = initial;
    globalThis.gc?.();
    const started = performance.now();
    for (let update = 0; update < iterations; update += 1) {
      data = applyDelta(data, { c: [[`record-${update % rows}`, { version: update + 1, text: "更新\n\"\\" }]] });
    }
    const durationMs = performance.now() - started;
    const expected = new Array(rows).fill(0);
    for (let update = 0; update < iterations; update += 1) expected[update % rows] = update + 1;
    assert.deepEqual(data.map((record) => record.version), expected);
    assert.deepEqual(data.map((record) => record.id), initial.map((record) => record.id));
    assert.ok(Object.isFrozen(data) && data.every(Object.isFrozen));
    assert.ok(initial.every((record) => record.version === 0));
    samples.push({ rows, repetition, durationMs, usPerUpdate: durationMs * 1_000 / iterations });
  }
}

const report = {
  formatVersion: 1, kind: "sdk-view-microbenchmark", createdAt: new Date().toISOString(),
  label: process.env.BENCH_VIEW_LABEL ?? "", node: process.version, iterations, samples,
};
await mkdir(new URL("../.local/bench/", import.meta.url), { recursive: true });
const output = new URL(`../.local/bench/views-${Date.now()}.json`, import.meta.url);
await writeFile(output, JSON.stringify(report, null, 2) + "\n");
console.log(JSON.stringify(report, null, 2));
console.log(`Results: ${output.pathname}`);
