import { delay } from "./async.mjs";
import { series } from "./stats.mjs";

export async function pacedLoad({ items, rate, durationMs, concurrency, task, signal }) {
  const offered = Math.floor(rate * durationMs / 1000);
  const interval = 1000 / rate;
  const started = performance.now();
  const busy = new Set();
  const inFlight = new Set();
  const lag = series();
  let dispatched = 0;
  let busyDropped = 0;
  let concurrencyDropped = 0;
  let generatorDropped = 0;
  let slot = 0;
  let failure;
  try {
    while (slot < offered && !failure) {
      if (signal?.aborted) throw new Error("Benchmark interrupted");
      const due = started + slot * interval;
      const pause = due - performance.now();
      if (pause > 0) await delay(pause, undefined, { signal });
      const now = performance.now();
      const current = Math.min(offered, Math.floor((now - started) / interval));
      if (current > slot) { generatorDropped += current - slot; slot = current; }
      if (slot >= offered) break;
      const item = items[slot % items.length];
      if (busy.has(item)) busyDropped++;
      else if (inFlight.size >= concurrency) concurrencyDropped++;
      else {
        lag.record(Math.max(0, now - (started + slot * interval)));
        dispatched++;
        busy.add(item);
        const operation = Promise.resolve().then(() => task(item)).catch((error) => { failure ??= error; }).finally(() => {
          busy.delete(item);
          inFlight.delete(operation);
        });
        inFlight.add(operation);
      }
      slot++;
    }
    if (!failure) {
      const remaining = started + durationMs - performance.now();
      if (remaining > 0) await delay(remaining, undefined, { signal });
    }
  } finally { await Promise.all(inFlight); }
  if (failure) throw failure;
  return { offered, dispatched, busyDropped, concurrencyDropped, generatorDropped,
    schedulerLagMs: lag.summary(), offeredRate: rate, durationMs, elapsedMs: performance.now() - started };
}

export function capacityVerdict(result, { p95Ms = 250, minCoverage = 0.99, maxDropRate = 0.01 } = {}) {
  const load = result.pacedLoad;
  const drops = load ? load.offered - load.dispatched : null;
  const dropRate = load?.offered ? drops / load.offered : null;
  const checks = {
    correct: result.success,
    latency: result.propagationMs.p95 !== null && result.propagationMs.p95 <= p95Ms,
    coverage: result.deliveryCoverage !== null && result.deliveryCoverage >= minCoverage,
    offeredLoad: dropRate !== null && dropRate <= maxDropRate,
    completed: Boolean(load) && result.completedWrites === load.dispatched,
    environment: result.measurementValidity?.valid === true,
  };
  return { pass: Object.values(checks).every(Boolean), checks, dropRate, limits: { p95Ms, minCoverage, maxDropRate } };
}
