import { readFile, writeFile } from "node:fs/promises";
import { resolve, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { capacityVerdict } from "../lib/load.mjs";

export function resourceSummary(text, limits) {
  const lines = text.trim().split("\n");
  if (lines.length !== 4 || limits.length !== 2) throw new Error("Incomplete cgroup or resource-limit evidence");
  const cpuRanges = limits.map((limit) => String(limit.cpuset).split(",").map((range) => {
    const match = /^(\d+)(?:-(\d+))?$/.exec(range);
    if (!match) throw new Error("Invalid cpuset evidence");
    const lower = Number(match[1]);
    const upper = Number(match[2] ?? match[1]);
    if (!Number.isSafeInteger(upper) || lower > upper) throw new Error("Invalid cpuset evidence");
    return { lower, upper };
  }));
  if (cpuRanges[0].some((left) => cpuRanges[1].some((right) => left.lower <= right.upper && right.lower <= left.upper))) {
    throw new Error("Application and database CPU sets overlap");
  }
  const value = (line, key) => {
    const match = new RegExp(`(?:^| )${key} (\\d+)(?: |$)`).exec(line);
    if (!match) throw new Error(`Missing cgroup counter: ${key}`);
    return Number(match[1]);
  };
  return limits.map((limit, index) => {
    if (!(limit.nanoCpus > 0 && limit.memory > 0 && limit.memorySwap === limit.memory && limit.cpuset)) {
      throw new Error("CPU, memory, swap and cpuset limits must be enforced");
    }
    const before = lines[index];
    const after = lines[index + 2];
    if (!before.startsWith(`${limit.name.slice(1)} before `) || !after.startsWith(`${limit.name.slice(1)} after `)) {
      throw new Error("Cgroup samples do not match the inspected containers");
    }
    const delta = (key) => {
      const result = value(after, key) - value(before, key);
      if (result < 0) throw new Error("Cgroup counters reset during measurement");
      return result;
    };
    return { ...limit, cpuSeconds: delta("usage_usec") / 1e6, throttledPeriods: delta("nr_throttled"),
      oomKills: delta("oom_kill"), memoryCurrentBytes: Number(after.trim().split(/\s+/).at(-1)) };
  });
}

export async function recordResult(directory, runnerStatus = 0, { allowSourceMismatch = false } = {}) {
  const report = JSON.parse(await readFile(resolve(directory, "r/results.json"), "utf8"));
  if (report.results.length !== 1) throw new Error("Expected exactly one measured repetition");
  const result = report.results[0];
  const limits = (await readFile(resolve(directory, "limits.jsonl"), "utf8")).trim().split("\n").map((line) => JSON.parse(line));
  const resources = resourceSummary(await readFile(resolve(directory, "cgroup.txt"), "utf8"), limits);
  if (typeof resources[0].source !== "string" || !/^[a-f0-9]{64}$/.test(resources[0].source)) {
    throw new Error("Application image is missing its build-time source fingerprint");
  }
  const sourceMatches = resources[0].source === report.environment.sourceFingerprint.digest;
  if (!sourceMatches && !allowSourceMismatch) {
    throw new Error("Application image and generator sources differ; rebuild the image from this checkout");
  }
  const samples = (await readFile(resolve(directory, "anon.txt"), "utf8")).trim().split("\n").filter(Boolean).map((line) => Number(line.split(/\s+/)[1]));
  if (!samples.length || samples.some((sample) => !Number.isFinite(sample))) throw new Error("Missing anonymous-memory samples");
  const summary = { measuredAt: report.createdAt, sourceFingerprint: report.environment.sourceFingerprint,
    runnerStatus, resources, sourceMatches, sourceMismatchAllowed: allowSourceMismatch,
    anonymousPeakBytes: Math.max(...samples), result: { ...result, samples: undefined },
    capacity: capacityVerdict(result),
    caveat: "CPU includes connection setup and warmup. Memory is cgroup current/anonymous samples, not process RSS. " +
      (result.scenario === "mixed" ? "Mixed latency includes explicit view confirmations and polling, not passive update-only propagation." : "This workload updates existing records.") };
  await writeFile(resolve(directory, "summary.json"), JSON.stringify(summary, null, 2) + "\n");
  const app = resources[0];
  console.log(`RESULT ${basename(directory)} writes=${result.completedWrites} p95=${result.propagationMs.p95?.toFixed(2) ?? "NaN"}ms cov=${result.deliveryCoverage} appCPU=${app.cpuSeconds.toFixed(2)}s throttled=${app.throttledPeriods} mem=${Math.round(app.memoryCurrentBytes / 2 ** 20)}MiB oom=${app.oomKills} ok=${result.success} anonPeakMiB=${Math.round(summary.anonymousPeakBytes / 2 ** 20)} genDropped=${result.pacedLoad?.generatorDropped ?? "unknown"}`);
  if (runnerStatus !== 0 || !result.success || resources.some((resource) => resource.oomKills > 0)) {
    throw new Error("Run failed correctness, generator execution or OOM checks; inspect summary.json and private logs");
  }
  return summary;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await recordResult(resolve(process.argv[2]), Number(process.argv[3] ?? 0), { allowSourceMismatch: process.env.FAIR_ALLOW_SOURCE_MISMATCH === "1" }); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
