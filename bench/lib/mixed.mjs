import { pool, until, delay } from "./async.mjs";
import { assertCompleteView, payload, series } from "./stats.mjs";
import { pacedLoad } from "./load.mjs";
import { trafficMeter } from "./transport.mjs";
import { resourceSampler } from "./resources.mjs";

const timestamp = (value) => Date.parse(value.replace(/\.\d+Z$/, "Z")) * 1000 + Number((value.match(/\.(\d+)Z$/)?.[1] ?? "").padEnd(6, "0"));
export const mixedWindow = (records, limit) => [...records].filter((item) => !item.archived)
  .sort((left, right) => timestamp(right.inserted_at) - timestamp(left.inserted_at) || right.id.localeCompare(left.id)).slice(0, limit);

export async function runMixedScenario(adapter, fixture, config, scenario, repetition) {
  const actors = [];
  const groups = [];
  const timings = Object.fromEntries(["firstReadyMs", "writeMs", "propagationMs", "recoveryMs"].map((name) => [name, series()]));
  const operations = { add: 0, update: 0, archive: 0, restore: 0, delete: 0, history: 0, confirmations: 0 };
  const shard = config.shard ?? { index: 0, count: 1 };
  const users = fixture.users.slice(0, scenario.users).filter((_user, index) => index % shard.count === shard.index);
  const rate = Math.floor(config.rate / shard.count) + (shard.index < config.rate % shard.count ? 1 : 0);
  if (!users.length || !rate) throw new Error("Shard has no users or no share of the rate");
  const began = performance.now();
  let measuredAt;
  let loadEnded;
  let sampler;
  let resources;
  let paced;
  let completedWrites = 0;
  let expectedDeliveries = 0;
  let pendingPeak = 0;
  let failure;
  let success = false;
  const errors = [];
  async function history(group) {
    const records = [];
    let cursor;
    let pages = 0;
    do {
      if (++pages > 2) throw new Error("Mixed workload exceeded its history page bound");
      const page = await group.writer.history(cursor);
      records.push(...page.items); cursor = page.next_cursor;
      if (records.length > config.rows + 1) throw new Error("Mixed workload history exceeded its bounded model");
    } while (cursor);
    return records;
  }
  async function check(group) {
    await until(() => {
      if (failure) throw failure;
      const expected = mixedWindow(group.records.values(), config.rows);
      return group.observers.every((observer) => {
        const state = observer.client.getState();
        if (["error", "closed"].includes(state.status)) throw new Error("Mixed observer disconnected or failed");
        if (state.status !== "ready") return false;
        try { assertCompleteView(state.data, expected); return true; } catch { return false; }
      });
    }, config.timeoutMs, "mixed authoritative view");
  }
  async function step(group, measured) {
    if (failure) throw failure;
    group.pending = measured;
    if (measured) pendingPeak = Math.max(pendingPeak, groups.filter((candidate) => candidate.pending).length);
    const started = performance.now();
    const phase = group.phase++ % 5;
    const name = ["add", "update", "archive", "restore", "delete"][phase];
    const marker = `${group.marker}:${group.phase}:`;
    const text = payload(marker, config.payloadBytes);
    let item;
    if (phase === 0) {
      group.adding = text;
      item = await group.writer.add(text);
      group.active = item;
      group.permitted.add(item.id); group.adding = undefined;
    } else if (phase === 1) item = await group.writer.update(group.active, text);
    else if (phase === 2 || phase === 3) item = await group.writer.archive(group.active, phase === 2);
    else {
      const deleted = await group.writer.remove(group.active);
      if (!deleted.deleted || deleted.id !== group.active.id) throw new Error("Delete did not confirm the expected record");
      group.records.delete(deleted.id);
    }
    if (item) { group.active = item; group.records.set(item.id, item); }
    if (measured) { completedWrites++; operations[name]++; timings.writeMs.record(performance.now() - started); expectedDeliveries += group.observers.length; }
    await Promise.all(group.observers.map((observer) => observer.client.confirm()));
    await check(group);
    if (measured) {
      operations.confirmations += group.observers.length;
      for (const _observer of group.observers) timings.propagationMs.record(performance.now() - started);
    }
    group.pending = false;
    if (phase === 4) {
      group.permitted.delete(group.active.id); group.active = undefined;
      assertCompleteView(await history(group), [...group.records.values()]);
      if (measured) operations.history++;
    }
  }
  try {
    await pool(users, config.concurrency, async (user, index) => {
      const network = trafficMeter();
      const writer = await adapter.connect({ endpoint: config.endpoint, fixture, user, network, timeoutMs: config.timeoutMs, observe: false });
      actors.push({ client: writer, network });
      const group = { writer, phase: 0, marker: `${fixture.run_id.slice(0, 12)}:${shard.index}:${index}:${repetition}`, permitted: new Set(user.ids), observers: [] };
      group.records = new Map((await history(group)).map((item) => [item.id, item]));
      groups.push(group);
      for (let device = 0; device < scenario.devices; device++) {
        const meter = trafficMeter();
        const started = performance.now();
        const client = await adapter.connect({ endpoint: config.endpoint, fixture, user: { ...user, token: config.sessions === "device" ? user.observer_tokens[device] : user.token }, network: meter, timeoutMs: config.timeoutMs });
        const actor = { client, network: meter };
        actors.push(actor); group.observers.push(actor);
        actor.stop = client.onChange((state) => {
          if (state.status === "ready" && (!Array.isArray(state.data) || state.data.length > config.rows ||
            new Set(state.data.map((item) => item.id)).size !== state.data.length ||
            state.data.some((item) => item.archived || (!group.permitted.has(item.id) && item.text !== group.adding)))) failure = new Error("Mixed observer received duplicate, archived or unauthorized records");
        });
        await until(() => client.getState().status === "ready", config.timeoutMs, "mixed initial view");
        timings.firstReadyMs.record(performance.now() - started);
      }
      await check(group);
      for (let warmup = 0; warmup < config.warmup; warmup++) for (let phase = 0; phase < 5; phase++) await step(group, false);
    });
    if (config.startAt) {
      if (Date.now() >= config.startAt) throw new Error("Mixed setup missed the common start time");
      await delay(config.startAt - Date.now());
    }
    sampler = await resourceSampler(config);
    measuredAt = performance.now();
    paced = await pacedLoad({ items: groups, rate, durationMs: config.durationMs, concurrency: config.concurrency, signal: config.signal, task: (group) => step(group, true) });
    loadEnded = performance.now();
    for (const group of groups) { await check(group); assertCompleteView(await history(group), [...group.records.values()]); }
    for (const group of groups) while (group.phase % 5 !== 0) await step(group, false);
    if (failure) throw failure;
    success = true;
  } catch (error) { errors.push({ name: error.name, message: error.message.replace(/(?:rts_|rtk_)[\w-]+/g, "[redacted]").slice(0, 250) }); }
  finally {
    if (sampler) resources = await sampler.stop();
    for (const actor of actors) { actor.stop?.(); actor.client.close(); }
    if (config.settleMs) await delay(config.settleMs);
  }
  const ended = performance.now();
  return { target: config.target, scenario: scenario.name, repetition, success, errors, shard: config.shard,
    workload: { ...scenario, rows: config.rows, sessions: config.sessions, payloadBytes: config.payloadBytes, durationMs: config.durationMs, offeredRate: config.rate,
      mix: "add/update/archive/restore/delete cycle; history after every delete; explicit confirmation on every observer after every write; no automatic retry", warmupCyclesPerUser: config.warmup },
    operations, completedWrites, expectedDeliveries, observedDeliveries: timings.propagationMs.count,
    deliveryCoverage: expectedDeliveries ? timings.propagationMs.count / expectedDeliveries : null,
    unobservedIntermediateDeliveries: expectedDeliveries - timings.propagationMs.count,
    connections: { writers: users.length, observers: users.length * scenario.devices, total: actors.length, opened: actors.length },
    pacedLoad: paced, setupDurationMs: (measuredAt ?? ended) - began, durationMs: measuredAt ? ended - measuredAt : 0,
    pendingDeliveries: { peakMarkers: pendingPeak, remainingMarkers: groups.filter((group) => group.pending).length, limit: users.length },
    runtimeStats: {}, windows: [],
    loadDurationMs: measuredAt ? (loadEnded ?? ended) - measuredAt : 0, resources,
    writeRequestsPerSecond: measuredAt ? completedWrites * 1000 / ((loadEnded ?? ended) - measuredAt) : null,
    measurementValidity: { valid: Boolean(resources && !resources.errors.length && resources.generator.eventLoopMaxMs <= 1000), reason: "Mixed propagation includes explicit confirmation and polling, not passive update-only latency" },
    ...Object.fromEntries(Object.entries(timings).map(([name, samples]) => [name, samples.summary()])),
    samples: Object.fromEntries(Object.entries(timings).map(([name, samples]) => [name, samples.samples])),
    traffic: actors.reduce((total, actor) => { for (const [key, value] of Object.entries(actor.network.snapshot())) total[key] = key === "queuedPeak" ? Math.max(total[key] ?? 0, value) : (total[key] ?? 0) + value; return total; }, {}),
  };
}
