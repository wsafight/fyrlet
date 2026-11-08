import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm, symlink } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resourceSummary, recordResult } from "../fair/result.mjs";
import { scanConfiguration } from "../fair/scan.mjs";
import { acceptancePlan, acceptanceFingerprint } from "../../scripts/acceptance.mjs";

const limits = ["app", "pg"].map((name, index) => ({ name: `/${name}`, nanoCpus: 1e9, cpuset: String(index), memory: 1024, memorySwap: 1024 }));
const counters = "app before usage_usec 100 nr_throttled 2 oom_kill 0 512\npg before usage_usec 200 nr_throttled 1 oom_kill 0 512\napp after usage_usec 1000100 nr_throttled 5 oom_kill 0 768\npg after usage_usec 500200 nr_throttled 1 oom_kill 0 640\n";

test("limited runs require complete, matched, monotonic resource evidence", () => {
  assert.equal(resourceSummary(counters, limits)[0].cpuSeconds, 1);
  assert.equal(resourceSummary(counters, limits)[0].throttledPeriods, 3);
  assert.throws(() => resourceSummary(counters.replace("app after", "other after"), limits), /match/);
  assert.throws(() => resourceSummary(counters.replace("1000100", "0"), limits), /reset/);
  assert.throws(() => resourceSummary(counters, [{ ...limits[0], nanoCpus: 0 }, limits[1]]), /enforced/);
  assert.throws(() => resourceSummary(counters, [{ ...limits[0], cpuset: "1-2" }, limits[1]]), /overlap/);
  assert.throws(() => resourceSummary(counters.split("\n").slice(0, 2).join("\n"), limits), /Incomplete/);
});

test("A/B can deliberately compare labeled revisions without weakening current-source runs", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "fyrlet-evidence-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  await mkdir(join(directory, "r"));
  const result = { scenario: "mixed", success: true, completedWrites: 10, propagationMs: { p95: 2 }, deliveryCoverage: 1,
    pacedLoad: { offered: 10, dispatched: 10, generatorDropped: 0 }, measurementValidity: { valid: true } };
  await writeFile(join(directory, "r/results.json"), JSON.stringify({ environment: { sourceFingerprint: { digest: "b".repeat(64) } }, results: [result] }));
  await writeFile(join(directory, "limits.jsonl"), limits.map((limit) => JSON.stringify({ ...limit, source: "a".repeat(64) })).join("\n"));
  await writeFile(join(directory, "cgroup.txt"), counters);
  await writeFile(join(directory, "anon.txt"), "anon 512\n");
  await assert.rejects(recordResult(directory), /sources differ/);
  const summary = await recordResult(directory, 0, { allowSourceMismatch: true });
  assert.equal(summary.sourceMatches, false);
  assert.equal(summary.sourceMismatchAllowed, true);
  assert.match(summary.caveat, /explicit view confirmations/);
  assert.doesNotMatch(summary.caveat, /updates existing records/);
  await assert.rejects(recordResult(directory, 1, { allowSourceMismatch: true }), /Run failed/);
});

test("rate scans require at least three repetitions and safe unique run tags", () => {
  assert.equal(scanConfiguration([]).repeats, 3);
  assert.deepEqual(scanConfiguration(["--rates", "100,500,100"]).rates, [100, 500]);
  for (const arguments_ of [["--repeats", "2"], ["--rates", "0"], ["--rates", "NaN"], ["--label", "../outside"]]) {
    assert.throws(() => scanConfiguration(arguments_));
  }
});

test("acceptance groups are explicit and never imply external verification", () => {
  const plan = acceptancePlan("bench,core");
  assert.equal(plan[0].group, "bench");
  assert.ok(plan.some((stage) => stage.command.includes("scripts/test_all.sh")));
  assert.throws(() => acceptancePlan("remote-ci"), /Unknown/);
  assert.throws(() => acceptancePlan("core,core"), /duplicate/);
  assert.ok(acceptancePlan().every((stage) => !stage.command.includes("scripts/mail_live.sh")));
});

test("acceptance fingerprints include new host code, deletions and symlinks but exclude ignored artifacts", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "fyrlet-acceptance-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  execFileSync("git", ["init", "-q", directory]);
  await writeFile(join(directory, ".gitignore"), "cache.txt\n");
  await writeFile(join(directory, "tracked.txt"), "original");
  execFileSync("git", ["-C", directory, "add", ".gitignore", "tracked.txt"]);
  const original = await acceptanceFingerprint(directory);
  await writeFile(join(directory, "cache.txt"), "build output");
  assert.equal((await acceptanceFingerprint(directory)).digest, original.digest);
  await writeFile(join(directory, "host.mjs"), "new host source");
  const withHost = await acceptanceFingerprint(directory);
  assert.notEqual(withHost.digest, original.digest);
  await symlink("tracked.txt", join(directory, "link"));
  const withLink = await acceptanceFingerprint(directory);
  await rm(join(directory, "link"));
  await writeFile(join(directory, "link"), "tracked.txt");
  assert.notEqual((await acceptanceFingerprint(directory)).digest, withLink.digest);
  await rm(join(directory, "tracked.txt"));
  assert.notEqual((await acceptanceFingerprint(directory)).digest, withHost.digest);
});
