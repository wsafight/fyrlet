import { summary } from "./stats.mjs";

const add = (values) => values.reduce((total, value) => total + (value ?? 0), 0);
const pooled = (results, name) => {
  const samples = results.flatMap((result) => result.samples?.[name] ?? []);
  const count = add(results.map((result) => result[name]?.count));
  // Exact only while every shard kept all of its samples; otherwise percentiles come from the reservoirs.
  const exact = results.every((result) => result[name]?.percentiles !== "uniform reservoir sample");
  return { samples, summary: { ...summary(samples), count, sampleCount: samples.length,
    percentiles: exact ? "exact" : "pooled uniform reservoir samples" } };
};

// Combine the results of one run driven by several generator shards (same scenario and repetition).
export function mergeShards(results) {
  if (results.length < 2) throw new Error("Merging needs at least two shard results");
  const first = results[0];
  for (const result of results) {
    if (result.scenario !== first.scenario || result.repetition !== first.repetition) throw new Error("Shards differ in scenario or repetition");
    if (!result.shard || result.shard.count !== results.length) throw new Error("Shard metadata does not match the number of results");
  }
  if (new Set(results.map((result) => result.shard.index)).size !== results.length) throw new Error("Duplicate shard index");
  const series = Object.fromEntries(["firstReadyMs", "writeMs", "propagationMs", "recoveryMs"].map((name) => [name, pooled(results, name)]));
  const expectedDeliveries = add(results.map((result) => result.expectedDeliveries));
  const observedDeliveries = add(results.map((result) => result.observedDeliveries));
  const paced = results.every((result) => result.pacedLoad) ? {
    ...Object.fromEntries(["offered", "dispatched", "busyDropped", "concurrencyDropped", "generatorDropped"]
      .map((key) => [key, add(results.map((result) => result.pacedLoad[key]))])),
    schedulerLagMs: { p95: Math.max(...results.map((result) => result.pacedLoad.schedulerLagMs.p95 ?? 0)),
      max: Math.max(...results.map((result) => result.pacedLoad.schedulerLagMs.max ?? 0)), note: "worst shard" },
    offeredRate: add(results.map((result) => result.pacedLoad.offeredRate)), durationMs: first.pacedLoad.durationMs,
    elapsedMs: Math.max(...results.map((result) => result.pacedLoad.elapsedMs)),
  } : first.pacedLoad;
  const traffic = results.reduce((total, result) => {
    for (const [key, value] of Object.entries(result.traffic ?? {})) {
      total[key] = key === "queuedPeak" ? Math.max(total[key] ?? 0, value) : (total[key] ?? 0) + value;
    }
    return total;
  }, {});
  const durationMs = Math.max(...results.map((result) => result.durationMs ?? 0));
  const completedWrites = add(results.map((result) => result.completedWrites));
  return {
    ...first, shard: undefined,
    shards: results.map((result) => ({ shard: result.shard, success: result.success, completedWrites: result.completedWrites,
      setupDurationMs: result.setupDurationMs, generator: result.resources?.generator, measurementValidity: result.measurementValidity,
      propagationP95Ms: result.propagationMs?.p95 ?? null, pacedLoad: result.pacedLoad })),
    success: results.every((result) => result.success),
    errors: results.flatMap((result) => result.errors.map((error) => ({ ...error, shard: result.shard.index }))),
    measurementValidity: { valid: results.every((result) => result.measurementValidity?.valid),
      reason: results.find((result) => !result.measurementValidity?.valid)?.measurementValidity?.reason ?? null },
    completedWrites, expectedDeliveries, observedDeliveries,
    ...(first.operations ? { operations: Object.fromEntries(Object.keys(first.operations).map((name) => [name, add(results.map((result) => result.operations?.[name]))])) } : {}),
    unobservedIntermediateDeliveries: expectedDeliveries - observedDeliveries,
    deliveryCoverage: expectedDeliveries ? observedDeliveries / expectedDeliveries : null,
    connections: Object.fromEntries(["writers", "observers", "total", "opened"].map((key) => [key, add(results.map((result) => result.connections[key]))])),
    setupDurationMs: Math.max(...results.map((result) => result.setupDurationMs)),
    pendingDeliveries: { peakMarkers: add(results.map((result) => result.pendingDeliveries?.peakMarkers)),
      remainingMarkers: add(results.map((result) => result.pendingDeliveries?.remainingMarkers)), limit: first.pendingDeliveries?.limit },
    pacedLoad: paced, traffic, durationMs,
    writeRequestsPerSecond: durationMs ? completedWrites / (durationMs / 1000) : first.writeRequestsPerSecond,
    firstReadyMs: series.firstReadyMs.summary, writeMs: series.writeMs.summary,
    propagationMs: series.propagationMs.summary, recoveryMs: series.recoveryMs.summary,
    samples: Object.fromEntries(Object.entries(series).map(([name, value]) => [name, value.samples])),
    // Per-window latency cannot be pooled without raw samples; keep only the additive counters.
    windows: first.windows.map((window) => {
      const parts = results.map((result) => result.windows.find((other) => other.index === window.index)).filter(Boolean);
      const expected = add(parts.map((part) => part.expectedDeliveries));
      const observed = add(parts.map((part) => part.observedDeliveries));
      return { index: window.index, startedAtMs: window.startedAtMs, durationMs: window.durationMs,
        completedWrites: add(parts.map((part) => part.completedWrites)), expectedDeliveries: expected,
        observedDeliveries: observed, deliveryCoverage: expected ? observed / expected : null };
    }),
    resources: undefined,
    note: "Merged from generator shards: latency percentiles are pooled from raw samples; resources are per shard under `shards`.",
  };
}
