import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { monitorEventLoopDelay } from "node:perf_hooks";

const execute = promisify(execFile);

export function resourceTrend(samples, key) {
  if (!samples.length) return { initialRssBytes: null, finalRssBytes: null, meanRssBytes: null, rssTrendBytesPerMinute: null };
  const meanTime = samples.reduce((total, sample) => total + sample.elapsedMs, 0) / samples.length;
  const mean = samples.reduce((total, sample) => total + sample[key], 0) / samples.length;
  const variance = samples.reduce((total, sample) => total + (sample.elapsedMs - meanTime) ** 2, 0);
  const covariance = samples.reduce((total, sample) => total + (sample.elapsedMs - meanTime) * (sample[key] - mean), 0);
  return { initialRssBytes: samples[0][key], finalRssBytes: samples.at(-1)[key], meanRssBytes: mean,
    rssTrendBytesPerMinute: variance ? covariance / variance * 60000 : null };
}

export function cpuMilliseconds(value) {
  const [days, clock] = value.includes("-") ? value.split("-") : ["0", value];
  const parts = clock.split(":").map(Number);
  if (parts.length === 2) parts.unshift(0);
  if (parts.length !== 3 || parts.some((part) => !Number.isFinite(part))) throw new Error("Invalid ps CPU time");
  return (Number(days) * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000;
}

export function processTree(rows, root) {
  const selected = new Set(root ? [root] : []);
  let changed = true;
  while (changed) {
    changed = false;
    for (const row of rows) {
      if (selected.has(row.parent) && !selected.has(row.pid)) { selected.add(row.pid); changed = true; }
    }
  }
  return rows.filter((row) => selected.has(row.pid));
}

export async function processSnapshot() {
  const { stdout } = await execute("ps", ["-axo", "pid=,ppid=,time=,rss=,comm="], { maxBuffer: 4 * 1024 * 1024 });
  return stdout.trim().split("\n").filter(Boolean).map((line) => {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(\S+)\s+(\d+)\s+(.+)$/);
    if (!match) throw new Error("Cannot parse process resource sample");
    return { pid: Number(match[1]), parent: Number(match[2]), cpuMs: cpuMilliseconds(match[3]), rssBytes: Number(match[4]) * 1024, command: match[5] };
  });
}

export async function resourceSampler({ appPid, appWorkerPid, databasePid }) {
  const initialUsage = process.cpuUsage();
  const lag = monitorEventLoopDelay({ resolution: 10 });
  lag.enable();
  const previous = new Map();
  const totals = { application: { peakRssBytes: 0, cpuMs: 0 }, applicationWorker: { peakRssBytes: 0, cpuMs: 0 }, database: { peakRssBytes: 0, cpuMs: 0 } };
  const samples = [];
  const errors = [];
  let generatorPeakRssBytes = process.memoryUsage().rss;
  let generatorPeakHeapBytes = process.memoryUsage().heapUsed;
  const capture = async (initial = false) => {
    generatorPeakRssBytes = Math.max(generatorPeakRssBytes, process.memoryUsage().rss);
    generatorPeakHeapBytes = Math.max(generatorPeakHeapBytes, process.memoryUsage().heapUsed);
    if (!appPid && !databasePid) return;
    try {
      const rows = await processSnapshot();
      const appRows = processTree(rows, appPid);
      const mongo = appRows.find((row) => /(?:^|\/)mongod$/.test(row.command));
      const databaseRows = processTree(rows, databasePid || mongo?.pid);
      const databaseIds = new Set(databaseRows.map((row) => row.pid));
      const buckets = { application: appRows.filter((row) => !databaseIds.has(row.pid)),
        applicationWorker: appRows.filter((row) => row.pid === appWorkerPid), database: databaseRows };
      const sample = { elapsedMs: performance.now() - started };
      for (const [name, processes] of Object.entries(buckets)) {
        const rssBytes = processes.reduce((total, row) => total + row.rssBytes, 0);
        totals[name].peakRssBytes = Math.max(totals[name].peakRssBytes, rssBytes);
        for (const row of processes) {
          const key = `${name}:${row.pid}`;
          const before = previous.get(key);
          if (!initial) totals[name].cpuMs += Math.max(0, row.cpuMs - (before ?? 0));
          previous.set(key, row.cpuMs);
        }
        sample[`${name}RssBytes`] = rssBytes;
      }
      samples.push(sample);
    } catch (error) { errors.push(error.message); }
  };
  const started = performance.now();
  await capture(true);
  let inFlight = Promise.resolve();
  const timer = setInterval(() => { inFlight = inFlight.then(() => capture()); }, 250);
  return {
    stop: async () => {
      clearInterval(timer);
      await inFlight;
      await capture();
      lag.disable();
      const usage = process.cpuUsage(initialUsage);
      for (const name of Object.keys(totals)) Object.assign(totals[name], resourceTrend(samples, `${name}RssBytes`));
      return {
        sampled: Boolean(appPid || databasePid), workerSampled: Boolean(appWorkerPid), intervalMs: 250, ...totals, samples, errors,
        generator: { peakRssBytes: generatorPeakRssBytes, peakHeapBytes: generatorPeakHeapBytes,
          finalHeapBytes: process.memoryUsage().heapUsed, cpuMs: (usage.user + usage.system) / 1000,
          eventLoopP95Ms: lag.percentile(95) / 1e6, eventLoopMaxMs: lag.max / 1e6 },
      };
    },
  };
}
