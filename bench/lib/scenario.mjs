import { pool, until, delay } from "./async.mjs";
import { assertView, assertCompleteView, payload, series } from "./stats.mjs";
import { trafficMeter } from "./transport.mjs";
import { resourceSampler } from "./resources.mjs";
import { pacedLoad } from "./load.mjs";

export async function runScenario(adapter, fixture, config, scenario, repetition) {
  const actors = [];
  const groups = [];
  const firstReady = series();
  const writes = series();
  const propagation = series();
  const recovery = series();
  const pending = new Map();
  const windows = new Map();
  let observerFailure;
  let counter = 0;
  let resources;
  let sampler;
  let measurementStarted;
  let loadEnded;
  let ended;
  let completedWrites = 0;
  let expectedDeliveries = 0;
  let pendingPeak = 0;
  let setupSampler;
  let setupResources;
  let postCloseResources;
  let paced;
  let setupDurationMs;
  const runtimeStats = {};
  // With --shard I/N this process drives every N-th user and its proportional share of the offered rate.
  const shard = config.shard ?? { index: 0, count: 1 };
  const shardUsers = fixture.users.slice(0, scenario.users).filter((_user, position) => position % shard.count === shard.index);
  const shardRate = Math.floor(config.rate / shard.count) + (shard.index < config.rate % shard.count ? 1 : 0);
  if (!shardUsers.length || !shardRate) throw new Error("Shard has no users or no share of the rate; use fewer shards");
  const setupStarted = performance.now();
  const windowAt = (time) => {
    const index = Math.floor((time - measurementStarted) / 10000);
    if (!windows.has(index)) windows.set(index, { index, completedWrites: 0, expectedDeliveries: 0,
      observedDeliveries: 0, writeMs: series(10000), propagationMs: series(10000) });
    return windows.get(index);
  };
  const result = {
    target: config.target, scenario: scenario.name, repetition,
    workload: { ...scenario, sessions: config.sessions, rows: config.rows, payloadBytes: config.payloadBytes, writesPerUser: config.writes,
      warmupPerUser: config.warmup, concurrency: config.concurrency, intervalMs: config.intervalMs,
      idleMs: config.idleMs, delayMs: scenario.name === "slow" ? config.delayMs : 0,
      durationMs: scenario.mode === "paced" ? config.durationMs : null,
      offeredRate: scenario.mode === "paced" ? config.rate : null, settleMs: config.settleMs, timeoutMs: config.timeoutMs },
    success: false, errors: [],
  };
  const failIfObserver = () => {
    if (config.signal?.aborted) throw new Error("Benchmark interrupted");
    if (observerFailure) throw observerFailure;
  };
  const ready = (actor) => {
    failIfObserver();
    const state = actor.client.getState();
    if (["error", "closed"].includes(state.status)) throw new Error(`Observer ended with ${state.error?.code ?? state.status}`);
    return state.status === "ready";
  };
  const correct = (group) => group.observers.every((actor) => {
    if (!ready(actor)) return false;
    try { assertView(actor.client.getState().data, [...group.expected.values()]); return true; }
    catch { return false; }
  });
  const openActor = async (user, observe) => {
    const network = trafficMeter();
    const began = performance.now();
    let client;
    try { client = await adapter.connect({ endpoint: config.endpoint, fixture, user, network, timeoutMs: config.timeoutMs, observe }); }
    catch (error) { network.disconnect(); throw error; }
    const actor = { client, network, id: actors.length };
    actors.push(actor);
    if (observe) {
      const permitted = new Set(user.ids);
      actor.stop = client.onChange((state) => {
        if (state.status !== "ready") return;
        if (!Array.isArray(state.data) || state.data.length !== config.rows ||
            new Set(state.data.map((item) => item.id)).size !== config.rows || state.data.some((item) => !permitted.has(item.id))) {
          observerFailure = new Error("Observer received an incomplete, duplicate or unauthorized record set");
          return;
        }
        for (const item of state.data) {
          const delivery = pending.get(item.text);
          if (delivery && delivery.observers.has(actor.id) && !delivery.seen.has(actor.id)) {
            delivery.seen.add(actor.id);
            propagation.record(performance.now() - delivery.started);
            delivery.window.observedDeliveries++;
            delivery.window.propagationMs.record(performance.now() - delivery.started);
            if (delivery.seen.size === delivery.observers.size) pending.delete(item.text);
          }
        }
      });
      await until(() => ready(actor), config.timeoutMs, "initial subscription");
      firstReady.record(performance.now() - began);
    }
    return actor;
  };
  const update = async (group, measured, waitForObservers) => {
    failIfObserver();
    const item = group.expected.get(group.itemId);
    const marker = `${fixture.run_id.slice(0, 12)}:${repetition}:${scenario.name}:${counter++}:`;
    const text = payload(marker, config.payloadBytes);
    const began = performance.now();
    const window = measured ? windowAt(began) : undefined;
    if (measured) {
      if (pending.size >= 100000) throw new Error("Generator pending-delivery safety limit reached (100000 markers)");
      expectedDeliveries += group.observers.length;
      window.expectedDeliveries += group.observers.length;
      pending.set(text, { started: began, window, seen: new Set(), observers: new Set(group.observers.map((actor) => actor.id)) });
      pendingPeak = Math.max(pendingPeak, pending.size);
    }
    let committed;
    try { committed = await group.writer.client.update(item, text); }
    catch (error) { observerFailure ??= error; throw error; }
    if (committed.id !== item.id || committed.text !== text || committed.version !== item.version + 1) {
      throw new Error("Write response does not match the requested versioned mutation");
    }
    group.expected.set(committed.id, committed);
    if (measured) {
      completedWrites++;
      writes.record(performance.now() - began);
      window.completedWrites++;
      window.writeMs.record(performance.now() - began);
    }
    if (waitForObservers) await until(() => correct(group), config.timeoutMs, "committed view on every observer");
    if (config.intervalMs) await delay(config.intervalMs);
  };
  try {
    setupSampler = await resourceSampler(config);
    await pool(shardUsers, config.concurrency, async (user) => {
      const writer = await openActor(user, false);
      const observers = await pool(Array.from({ length: scenario.devices }), config.concurrency, (_unused, index) =>
        openActor(config.sessions === "device" ? { ...user, token: user.observer_tokens[index] } : user, true));
      const initial = observers[0].client.getState().data;
      const group = { writer, observers, expected: new Map(initial.map((item) => [item.id, item])), itemId: initial[0].id };
      groups.push(group);
      await until(() => correct(group), config.timeoutMs, "equal initial views");
    });
    await pool(groups, config.concurrency, async (group) => {
      for (let index = 0; index < config.warmup; index++) await update(group, false, true);
    });
    await delay(100);
    setupDurationMs = performance.now() - setupStarted;
    setupResources = await setupSampler.stop();
    setupSampler = undefined;
    if (adapter.runtimeStats) {
      runtimeStats.before = await adapter.runtimeStats(config);
      if (runtimeStats.before.loggedInConnections !== actors.length) throw new Error("Benchmark contains sessions retained from a previous repetition");
    }
    if (scenario.name === "slow") for (const group of groups) group.observers.at(-1).network.slow(config.delayMs);
    for (const actor of actors) actor.network.reset();
    if (config.startAt) {
      const wait = config.startAt - Date.now();
      if (wait < 0) throw new Error(`Setup finished ${-wait} ms after --start-at; use a later start time`);
      await delay(wait, undefined, { signal: config.signal });
    }
    sampler = await resourceSampler(config);
    measurementStarted = performance.now();
    if (scenario.mode === "paced") {
      paced = await pacedLoad({ items: groups, rate: shardRate, durationMs: config.durationMs,
        concurrency: config.concurrency, signal: config.signal, task: (group) => update(group, true, true) });
    } else if (scenario.mode === "idle") await delay(config.idleMs, undefined, { signal: config.signal });
    else if (scenario.mode === "reconnect") {
      await Promise.all(groups.flatMap((group) => group.observers.map((actor) => actor.client.offline())));
      await until(() => groups.every((group) => group.observers.every((actor) => actor.client.getState().status !== "ready")), config.timeoutMs, "observers offline");
      await pool(groups, config.concurrency, async (group) => {
        for (let index = 0; index < config.writes; index++) await update(group, true, false);
      });
      loadEnded = performance.now();
      const reconnectStarted = performance.now();
      await Promise.all(groups.flatMap((group) => group.observers.map(async (actor) => {
        await actor.client.online();
        await until(() => {
          if (!ready(actor)) return false;
          try { assertView(actor.client.getState().data, [...group.expected.values()]); return true; } catch { return false; }
        }, config.timeoutMs, "current view after reconnect");
        recovery.record(performance.now() - reconnectStarted);
      })));
    } else {
      await pool(groups, config.concurrency, async (group) => {
        for (let index = 0; index < config.writes; index++) await update(group, true, scenario.mode === "converge");
      });
    }
    loadEnded ??= performance.now();
    await until(() => groups.every(correct), config.timeoutMs, "final committed views");
    ended = performance.now();
    failIfObserver();
    resources = await sampler.stop();
    sampler = undefined;
    for (const group of groups) for (const observer of group.observers) {
      assertCompleteView(observer.client.getState().data, [...group.expected.values()]);
    }
    result.success = true;
  } catch (error) {
    result.errors.push({ name: error.name, code: error.code ?? null, message: error.message.replace(/(?:rts_|rtk_|mbt_)[\w-]+/g, "[redacted]").slice(0, 300) });
  } finally {
    ended ??= performance.now();
    setupDurationMs ??= ended - setupStarted;
    if (setupSampler) setupResources = await setupSampler.stop();
    if (sampler) resources = await sampler.stop();
    if (adapter.runtimeStats) {
      try { runtimeStats.after = await adapter.runtimeStats(config); }
      catch (error) { result.errors.push({ name: error.name, message: error.message }); result.success = false; }
    }
    result.traffic = actors.map((actor) => actor.network.snapshot()).reduce((total, current) => {
      for (const [key, value] of Object.entries(current)) {
        total[key] = key === "queuedPeak" ? Math.max(total[key] ?? 0, value) : (total[key] ?? 0) + value;
      }
      return total;
    }, {});
    for (const actor of actors) { actor.stop?.(); actor.client.close(); }
    if (config.settleMs) {
      const cleanupSampler = await resourceSampler(config);
      await delay(config.settleMs);
      postCloseResources = await cleanupSampler.stop();
      if (adapter.runtimeStats) {
        try {
          runtimeStats.postClose = await adapter.runtimeStats(config);
          if (runtimeStats.postClose.loggedInConnections !== 0 || runtimeStats.postClose.observedQueries !== 0) {
            result.errors.push({ name: "Error", message: "Benchmark sessions or observed queries were not reclaimed after graceful close" });
            result.success = false;
          }
        }
        catch (error) { result.errors.push({ name: error.name, message: error.message }); result.success = false; }
      }
    }
  }
  const durationMs = measurementStarted === undefined ? 0 : ended - measurementStarted;
  const loadDurationMs = measurementStarted === undefined ? 0 : (loadEnded ?? ended) - measurementStarted;
  const generatorMaxLag = resources?.generator.eventLoopMaxMs;
  const measurementValidity = { valid: generatorMaxLag !== undefined && generatorMaxLag <= 1000 && resources.errors.length === 0,
    reason: generatorMaxLag > 1000 ? "Generator stalled for over 1s; host suspension or generator saturation invalidates capacity inference" : null };
  return {
    ...result, measurementValidity, completedWrites, expectedDeliveries, observedDeliveries: propagation.count,
    unobservedIntermediateDeliveries: expectedDeliveries - propagation.count,
    deliveryCoverage: expectedDeliveries ? propagation.count / expectedDeliveries : null,
    connections: { writers: shardUsers.length, observers: shardUsers.length * scenario.devices,
      total: shardUsers.length * (scenario.devices + 1), opened: actors.length },
    shard: config.shard,
    setupDurationMs, setupResources, postCloseResources, runtimeStats, pacedLoad: paced,
    windows: [...windows.values()].sort((left, right) => left.index - right.index).map((window) => ({
      index: window.index, startedAtMs: window.index * 10000,
      durationMs: Math.max(0, Math.min(10000, loadDurationMs - window.index * 10000)),
      completedWrites: window.completedWrites, expectedDeliveries: window.expectedDeliveries,
      observedDeliveries: window.observedDeliveries,
      deliveryCoverage: window.expectedDeliveries ? window.observedDeliveries / window.expectedDeliveries : null,
      writeMs: window.writeMs.summary(), propagationMs: window.propagationMs.summary(),
    })),
    pendingDeliveries: { peakMarkers: pendingPeak, remainingMarkers: pending.size, limit: 100000 },
    durationMs, loadDurationMs,
    writeRequestsPerSecond: loadDurationMs > 0 ? completedWrites * 1000 / loadDurationMs : null,
    convergedWritesPerSecond: scenario.mode === "converge" && durationMs > 0 ? completedWrites * 1000 / durationMs : null,
    firstReadyMs: firstReady.summary(), writeMs: writes.summary(), propagationMs: propagation.summary(), recoveryMs: recovery.summary(),
    samples: { firstReadyMs: firstReady.samples, writeMs: writes.samples, propagationMs: propagation.samples, recoveryMs: recovery.samples }, resources,
  };
}
