import { pool, until, delay } from "./async.mjs";
import { assertView, payload, summary } from "./stats.mjs";
import { trafficMeter } from "./transport.mjs";
import { resourceSampler } from "./resources.mjs";

export async function runScenario(adapter, fixture, config, scenario, repetition) {
  const actors = [];
  const groups = [];
  const firstReady = [];
  const writes = [];
  const propagation = [];
  const recovery = [];
  const pending = new Map();
  let observerFailure;
  let counter = 0;
  let resources;
  let sampler;
  let measurementStarted;
  let loadEnded;
  let ended;
  let completedWrites = 0;
  const result = {
    target: config.target, scenario: scenario.name, repetition,
    workload: { ...scenario, rows: config.rows, payloadBytes: config.payloadBytes, writesPerUser: config.writes,
      warmupPerUser: config.warmup, concurrency: config.concurrency, intervalMs: config.intervalMs,
      idleMs: config.idleMs, delayMs: scenario.name === "slow" ? config.delayMs : 0 },
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
            propagation.push(performance.now() - delivery.started);
          }
        }
      });
      await until(() => ready(actor), config.timeoutMs, "initial subscription");
      firstReady.push(performance.now() - began);
    }
    return actor;
  };
  const update = async (group, measured, waitForObservers) => {
    failIfObserver();
    const item = group.expected.get(group.itemId);
    const marker = `${fixture.run_id.slice(0, 12)}:${repetition}:${scenario.name}:${counter++}:`;
    const text = payload(marker, config.payloadBytes);
    const began = performance.now();
    if (measured) pending.set(text, { started: began, seen: new Set(), observers: new Set(group.observers.map((actor) => actor.id)) });
    let committed;
    try { committed = await group.writer.client.update(item, text); }
    catch (error) { observerFailure ??= error; throw error; }
    if (committed.id !== item.id || committed.text !== text || committed.version !== item.version + 1) {
      throw new Error("Write response does not match the requested versioned mutation");
    }
    group.expected.set(committed.id, committed);
    if (measured) { completedWrites++; writes.push(performance.now() - began); }
    if (waitForObservers) await until(() => correct(group), config.timeoutMs, "committed view on every observer");
    if (config.intervalMs) await delay(config.intervalMs);
  };
  try {
    await pool(fixture.users.slice(0, scenario.users), config.concurrency, async (user) => {
      const writer = await openActor(user, false);
      const observers = await pool(Array.from({ length: scenario.devices }), config.concurrency, () => openActor(user, true));
      const initial = observers[0].client.getState().data;
      const group = { writer, observers, expected: new Map(initial.map((item) => [item.id, item])), itemId: initial[0].id };
      groups.push(group);
      await until(() => correct(group), config.timeoutMs, "equal initial views");
    });
    await pool(groups, config.concurrency, async (group) => {
      for (let index = 0; index < config.warmup; index++) await update(group, false, true);
    });
    await delay(100);
    if (scenario.name === "slow") for (const group of groups) group.observers.at(-1).network.slow(config.delayMs);
    for (const actor of actors) actor.network.reset();
    sampler = await resourceSampler(config);
    measurementStarted = performance.now();
    if (scenario.mode === "idle") await delay(config.idleMs, undefined, { signal: config.signal });
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
        recovery.push(performance.now() - reconnectStarted);
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
    result.success = true;
  } catch (error) {
    result.errors.push({ name: error.name, code: error.code ?? null, message: error.message.replace(/(?:rts_|rtk_|mbt_)[\w-]+/g, "[redacted]").slice(0, 300) });
  } finally {
    ended ??= performance.now();
    if (sampler) resources = await sampler.stop();
    result.traffic = actors.map((actor) => actor.network.snapshot()).reduce((total, current) => {
      for (const [key, value] of Object.entries(current)) {
        total[key] = key === "queuedPeak" ? Math.max(total[key] ?? 0, value) : (total[key] ?? 0) + value;
      }
      return total;
    }, {});
    for (const actor of actors) { actor.stop?.(); actor.client.close(); }
  }
  const expectedDeliveries = [...pending.values()].reduce((total, value) => total + value.observers.size, 0);
  const durationMs = measurementStarted === undefined ? 0 : ended - measurementStarted;
  const loadDurationMs = measurementStarted === undefined ? 0 : (loadEnded ?? ended) - measurementStarted;
  return {
    ...result, completedWrites, expectedDeliveries, observedDeliveries: propagation.length,
    unobservedIntermediateDeliveries: expectedDeliveries - propagation.length,
    deliveryCoverage: expectedDeliveries ? propagation.length / expectedDeliveries : null,
    durationMs, loadDurationMs,
    writeRequestsPerSecond: loadDurationMs > 0 ? completedWrites * 1000 / loadDurationMs : null,
    convergedWritesPerSecond: scenario.mode === "converge" && durationMs > 0 ? completedWrites * 1000 / durationMs : null,
    firstReadyMs: summary(firstReady), writeMs: summary(writes), propagationMs: summary(propagation), recoveryMs: summary(recovery),
    samples: { firstReadyMs: firstReady, writeMs: writes, propagationMs: propagation, recoveryMs: recovery }, resources,
  };
}
