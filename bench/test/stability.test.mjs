import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { evaluateStabilityThresholds, parseStabilityProfile, requiredStabilitySamples, stabilityConfiguration, stabilityInterruptionFailure,
  stabilityWatchdogMs, validateStabilityProfile } from "../../scripts/stability.mjs";

const workload = { seconds: 20, clients: 4, sampleMs: 10000 };
const runWindow = { workloadStartedAt: "2026-01-01T00:00:00.000Z", workloadFinishedAt: "2026-01-01T00:00:20.000Z" };
const allLimits = {
  memoryGrowthBytes: 300,
  databaseGrowthBytes: 50,
  tableRowGrowth: { sessions: 5, idempotency_results: 30, jobs: 1 },
  pendingRuns: 2,
  pendingAgeSeconds: 3.5,
  unresolvedEffects: 1,
  databaseLockWaiters: 1,
  poolQueuePerQueryMs: 0.1,
  sampleGapMs: 10000,
};
const profile = (limits = allLimits) => ({ version: 1, workload, limits });

function fixture() {
  const chat = [
    { at: "2026-01-01T00:00:00.000Z", database_bytes: 1000, sessions: 10, idempotency_results: 100, jobs: 1, pending_runs: 0, oldest_pending_seconds: 0, unresolved_effects: 0, database_lock_waiters: 0, private: "do-not-copy" },
    { at: "2026-01-01T00:00:10.000Z", database_bytes: 1050, sessions: 15, idempotency_results: 130, jobs: 2, pending_runs: 2, oldest_pending_seconds: 3.5, unresolved_effects: 1, database_lock_waiters: 1 },
    { at: "2026-01-01T00:00:20.000Z", database_bytes: 1020, sessions: 12, idempotency_results: 125, jobs: 1, pending_runs: 1, oldest_pending_seconds: 2, unresolved_effects: 0, database_lock_waiters: 0 },
  ];
  const samples = { chat, agent: chat.map((sample) => ({ ...sample, private: undefined })) };
  const node = (label, memory, queue, queries) => ({ label, memory_bytes: memory, telemetry: { db_queue_microseconds: queue, db_queries: queries }, private: "do-not-copy" });
  const nodes = [
    [node("node-0", 1000, 100, 10), node("node-1", 2000, 500, 5)],
    [node("node-0", 1100, 1100, 20), node("node-1", 2300, 2500, 25)],
    [node("node-0", 1200, 3100, 40), node("node-1", 2100, 6500, 65)],
  ];
  return { samples, runWindow, chat: { soak: { initial: nodes[0], samples: nodes.map((nodesAtTime) => ({ nodes: nodesAtTime })) }, private: "do-not-copy" } };
}

function check(outcome, name) {
  const result = outcome.checks.find((candidate) => candidate.name === name);
  assert.ok(result, `missing threshold outcome ${name}`);
  return result;
}

test("stability profiles are versioned, self-contained and strictly validated", () => {
  assert.deepEqual(validateStabilityProfile(profile()), profile());
  assert.deepEqual(parseStabilityProfile(JSON.stringify(profile())), profile());
  assert.deepEqual(validateStabilityProfile(profile({ memoryGrowthBytes: 1 })), profile({ memoryGrowthBytes: 1 }));
  assert.throws(() => validateStabilityProfile(profile({ databaseGrowthBytes: 1 })), /sampleGapMs/);
  const invalid = [
    null, [], { ...profile(), version: 2 }, { ...profile(), unknown: true },
    { version: 1, workload }, { ...profile(), workload: { ...workload, seconds: 4 } },
    { ...profile(), workload: { ...workload, clients: 51 } }, { ...profile(), workload: { ...workload, sampleMs: 999 } },
    { ...profile(), workload: { ...workload, extra: 1 } }, profile({}), profile({ unknown: 1 }),
    profile({ memoryGrowthBytes: -1 }), profile({ databaseGrowthBytes: 1.5, sampleGapMs: 1 }), profile({ pendingRuns: NaN, sampleGapMs: 1 }),
    profile({ pendingAgeSeconds: Infinity, sampleGapMs: 1 }), profile({ poolQueuePerQueryMs: "1" }), profile({ tableRowGrowth: {}, sampleGapMs: 1 }),
    profile({ tableRowGrowth: { unknown: 1 }, sampleGapMs: 1 }), profile({ tableRowGrowth: { sessions: -1 }, sampleGapMs: 1 }),
  ];
  for (const document of invalid) assert.throws(() => validateStabilityProfile(document), /stability profile/i);
  assert.throws(() => validateStabilityProfile({ ...profile(), secretCredentialName: "do-not-copy" }), (error) => {
    assert.doesNotMatch(error.message, /secretCredentialName|do-not-copy/);
    return true;
  });
  assert.throws(() => parseStabilityProfile("{not json"), /Invalid stability profile JSON/);
});

test("the current CLI defaults remain safe and profile workload values have explicit CLI overrides", async (context) => {
  assert.equal(stabilityConfiguration([]).seconds, 86400);
  assert.equal(stabilityConfiguration([]).clients, 20);
  assert.equal(stabilityConfiguration([]).sampleMs, 30000);
  assert.equal(stabilityConfiguration([]).profile, null);
  const directory = await mkdtemp(join(tmpdir(), "fyrlet-stability-profile-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const filename = join(directory, "profile.json");
  await writeFile(filename, JSON.stringify(profile({ databaseGrowthBytes: 1024, sampleGapMs: 15000 })));
  const selected = stabilityConfiguration(["--profile", filename]);
  assert.equal(selected.seconds, 20);
  assert.equal(selected.clients, 4);
  assert.equal(selected.sampleMs, 10000);
  assert.equal(selected.profile.limits.databaseGrowthBytes, 1024);
  const overridden = stabilityConfiguration(["--profile", filename, "--seconds", "45", "--clients", "6", "--sample-ms", "10000"]);
  assert.deepEqual(overridden.profile.workload, { seconds: 45, clients: 6, sampleMs: 10000 });
  assert.deepEqual(overridden.profile.limits, { databaseGrowthBytes: 1024, sampleGapMs: 15000 });
});

test("all supported thresholds evaluate both real DB streams and node metrics independently", () => {
  const data = fixture();
  const outcome = evaluateStabilityThresholds({ profile: profile(), ...data, runComplete: true });
  assert.equal(outcome.status, "passed");
  assert.equal(outcome.runComplete, true);
  assert.deepEqual(outcome.violations, []);
  assert.deepEqual(outcome.unverified, []);
  assert.equal(outcome.checks.length, 20);
  assert.equal(check(outcome, "memoryGrowthBytes").observed, 300);
  for (const domain of ["chat", "agent"]) {
    assert.equal(check(outcome, `${domain}.databaseGrowthBytes`).observed, 50);
    assert.equal(check(outcome, `${domain}.databaseGrowthBytes`).database, domain);
    assert.equal(check(outcome, `${domain}.tableRowGrowth.sessions`).observed, 5);
    assert.equal(check(outcome, `${domain}.tableRowGrowth.idempotency_results`).observed, 30);
    assert.equal(check(outcome, `${domain}.tableRowGrowth.jobs`).observed, 1);
    assert.equal(check(outcome, `${domain}.pendingRuns`).observed, 2);
    assert.equal(check(outcome, `${domain}.pendingAgeSeconds`).observed, 3.5);
    assert.equal(check(outcome, `${domain}.unresolvedEffects`).observed, 1);
    assert.equal(check(outcome, `${domain}.databaseLockWaiters`).observed, 1);
    assert.equal(check(outcome, `${domain}.sampleGapMs`).observed, 10000);
    assert.equal(outcome.databaseResults[domain].status, "passed");
    assert.equal(outcome.databaseResults[domain].samplingCoverage.status, "passed");
    assert.equal(outcome.databaseResults[domain].samplingCoverage.requiredSamples, 3);
  }
  assert.equal(check(outcome, "poolQueuePerQueryMs").observed, 0.1);
  assert.doesNotMatch(JSON.stringify(outcome), /do-not-copy/);
});

test("an Agent-only database violation fails Agent and the gate without implicating Chat", () => {
  const data = fixture();
  data.samples.agent[1].database_bytes += 100;
  const outcome = evaluateStabilityThresholds({ profile: profile({ databaseGrowthBytes: 50, sampleGapMs: 10000 }), ...data, runComplete: true });
  assert.equal(check(outcome, "chat.databaseGrowthBytes").status, "passed");
  assert.equal(check(outcome, "agent.databaseGrowthBytes").status, "failed");
  assert.equal(check(outcome, "agent.databaseGrowthBytes").observed, 150);
  assert.equal(outcome.databaseResults.chat.status, "passed");
  assert.equal(outcome.databaseResults.agent.status, "failed");
  assert.deepEqual(outcome.violations, ["agent.databaseGrowthBytes"]);
  assert.equal(outcome.status, "failed");
});

test("actual violations fail every corresponding threshold on both databases", () => {
  const zeroLimits = Object.fromEntries(Object.keys(allLimits).map((name) => [name, name === "tableRowGrowth" ? { sessions: 0, idempotency_results: 0, jobs: 0 } : 0]));
  const outcome = evaluateStabilityThresholds({ profile: profile(zeroLimits), ...fixture(), runComplete: true });
  assert.equal(outcome.status, "failed");
  assert.equal(outcome.checks.length, 20);
  assert.ok(outcome.checks.every((result) => result.status === "failed"));
  assert.equal(outcome.violations.length, outcome.checks.length);
  assert.deepEqual(outcome.unverified, []);
});

test("not-run, incomplete and unavailable evidence can never become a threshold pass", () => {
  const data = fixture();
  const notRun = evaluateStabilityThresholds({ profile: null, ...data, runComplete: true });
  assert.equal(notRun.status, "not-run");
  assert.deepEqual(notRun.checks, []);
  const incomplete = evaluateStabilityThresholds({ profile: profile(), ...data, runComplete: false });
  assert.equal(incomplete.status, "failed");
  assert.equal(incomplete.runComplete, false);
  assert.ok(incomplete.checks.every((result) => result.status === "passed"));
  assert.equal(incomplete.databaseResults.agent.status, "failed");
  const missingNodes = evaluateStabilityThresholds({ profile: profile({ memoryGrowthBytes: 1, poolQueuePerQueryMs: 1 }), samples: data.samples, runComplete: true });
  assert.equal(missingNodes.status, "failed");
  assert.deepEqual(missingNodes.unverified, ["memoryGrowthBytes", "poolQueuePerQueryMs"]);
  assert.ok(missingNodes.checks.every((result) => result.observed === null));
  const missingSamples = evaluateStabilityThresholds({ profile: profile({ databaseGrowthBytes: 1, sampleGapMs: 1 }), samples: {}, chat: data.chat, runWindow, runComplete: true });
  assert.equal(missingSamples.status, "failed");
  assert.deepEqual(missingSamples.unverified, ["chat.databaseGrowthBytes", "chat.sampleGapMs", "agent.databaseGrowthBytes", "agent.sampleGapMs"]);
  assert.ok(missingSamples.checks.every((result) => result.observed === null));
});

test("database cadence requires monotonic start/end coverage and enough scheduled samples", () => {
  const longProfile = { version: 1, workload: { seconds: 86400, clients: 20, sampleMs: 60000 }, limits: { sampleGapMs: 86400000 } };
  const points = [
    { at: "2026-01-01T00:00:00.000Z" },
    { at: "2026-01-02T00:00:00.000Z" },
  ];
  const longWindow = { workloadStartedAt: points[0].at, workloadFinishedAt: points[1].at };
  const isolated = evaluateStabilityThresholds({ profile: longProfile, samples: { chat: points, agent: points }, runWindow: longWindow, runComplete: true });
  assert.equal(requiredStabilitySamples(86400, 60000), 1441);
  assert.equal(isolated.status, "failed");
  assert.equal(isolated.databaseResults.chat.samplingCoverage.sampleCount, 2);
  assert.equal(isolated.databaseResults.chat.samplingCoverage.requiredSamples, 1441);
  assert.equal(isolated.databaseResults.chat.samplingCoverage.maxGapMs, 86400000);
  assert.ok(isolated.checks.every((result) => result.status === "unverified"));

  const missingEdges = evaluateStabilityThresholds({ profile: profile({ sampleGapMs: 20000 }), ...fixture(),
    runWindow: { workloadStartedAt: "2025-12-31T23:59:59.000Z", workloadFinishedAt: "2026-01-01T00:00:21.000Z" }, runComplete: true });
  assert.equal(missingEdges.databaseResults.chat.samplingCoverage.startCovered, false);
  assert.equal(missingEdges.databaseResults.chat.samplingCoverage.endCovered, false);
  assert.equal(check(missingEdges, "chat.sampleGapMs").status, "unverified");

  const arrayFixture = fixture();
  const arrayInput = evaluateStabilityThresholds({ profile: profile({ sampleGapMs: 10000 }), samples: arrayFixture.samples.chat, runWindow, runComplete: true });
  assert.equal(check(arrayInput, "chat.sampleGapMs").status, "unverified");
  assert.equal(check(arrayInput, "agent.sampleGapMs").status, "unverified");
  assert.equal(arrayInput.status, "failed");
});

test("counter resets, zero query deltas and invalid sample times make pool/gap evidence unverified", () => {
  const reset = fixture();
  reset.chat.soak.samples[2].nodes[0].telemetry.db_queue_microseconds = 0;
  const resetOutcome = evaluateStabilityThresholds({ profile: profile({ poolQueuePerQueryMs: 1 }), ...reset, runComplete: true });
  assert.equal(check(resetOutcome, "poolQueuePerQueryMs").status, "unverified");
  const idle = fixture();
  for (const sample of idle.chat.soak.samples) for (const node of sample.nodes) node.telemetry = { db_queue_microseconds: 0, db_queries: 0 };
  const idleOutcome = evaluateStabilityThresholds({ profile: profile({ poolQueuePerQueryMs: 1 }), ...idle, runComplete: true });
  assert.equal(check(idleOutcome, "poolQueuePerQueryMs").status, "unverified");
  const unordered = fixture();
  unordered.samples.chat[2].at = unordered.samples.chat[1].at;
  unordered.samples.chat[1].at = "2026-01-01T00:00:30.000Z";
  const gapOutcome = evaluateStabilityThresholds({ profile: profile({ sampleGapMs: 40000 }), ...unordered, runComplete: true });
  assert.equal(check(gapOutcome, "chat.sampleGapMs").status, "unverified");
  assert.equal(gapOutcome.databaseResults.chat.samplingCoverage.monotonic, false);
  assert.equal(check(gapOutcome, "agent.sampleGapMs").status, "passed");
});

test("outer watchdog retains inner soak grace and late interruptions always fail", () => {
  assert.equal(stabilityWatchdogMs(30), (30 + 60 + 600) * 1000);
  assert.equal(stabilityWatchdogMs(86400), 91320000);
  assert.equal(stabilityWatchdogMs(86400), (86400 + Math.ceil(86400 / 20) + 600) * 1000);
  assert.throws(() => stabilityWatchdogMs(86401));
  assert.match(stabilityInterruptionFailure("signal"), /interrupted/);
  assert.match(stabilityInterruptionFailure("watchdog"), /watchdog/);
  assert.equal(stabilityInterruptionFailure(undefined), undefined);
});
