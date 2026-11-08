import { parseArgs } from "node:util";
import { createRequire } from "node:module";
import { readFileSync, statSync } from "node:fs";
import { mkdir, open, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "../bench/lib/process.mjs";
import { acceptanceFingerprint } from "./acceptance.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const domains = ["chat", "agent"];
const workloadKeys = ["seconds", "clients", "sampleMs"];
const tableGrowthKeys = ["sessions", "idempotency_results", "jobs"];
const databaseLimitKeys = ["databaseGrowthBytes", "tableRowGrowth", "pendingRuns", "pendingAgeSeconds", "unresolvedEffects", "databaseLockWaiters", "sampleGapMs"];
const limitKeys = ["memoryGrowthBytes", ...databaseLimitKeys, "poolQueuePerQueryMs"];
const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
const setupAndFinalizationSeconds = 600;

class SafeStabilityError extends Error {}

function objectWithKeys(value, name, allowed, required = allowed) {
  const label = name || "document";
  if (!value || typeof value !== "object" || Array.isArray(value) || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) throw new TypeError(`Invalid stability profile ${label}`);
  for (const key of Object.keys(value)) if (!allowed.includes(key)) throw new TypeError(`Invalid stability profile ${label}`);
  for (const key of required) if (!own(value, key)) throw new TypeError(`Invalid stability profile ${label}.${key}`);
  return value;
}

function nonnegative(value, name, integer = false) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > Number.MAX_SAFE_INTEGER || (integer && !Number.isSafeInteger(value))) throw new TypeError(`Invalid stability profile ${name}`);
  return value;
}

export function validateStabilityProfile(document) {
  objectWithKeys(document, "", ["version", "workload", "limits"]);
  if (document.version !== 1) throw new TypeError("Invalid stability profile version");
  const workload = objectWithKeys(document.workload, "workload", workloadKeys);
  if (!Number.isSafeInteger(workload.seconds) || workload.seconds < 5 || workload.seconds > 86400) throw new TypeError("Invalid stability profile workload.seconds");
  if (!Number.isSafeInteger(workload.clients) || workload.clients < 2 || workload.clients > 50) throw new TypeError("Invalid stability profile workload.clients");
  if (!Number.isSafeInteger(workload.sampleMs) || workload.sampleMs < 1000 || workload.sampleMs > 60000) throw new TypeError("Invalid stability profile workload.sampleMs");
  const input = objectWithKeys(document.limits, "limits", limitKeys, []);
  if (!Object.keys(input).length) throw new TypeError("Invalid stability profile limits: at least one is required");
  if (databaseLimitKeys.some((name) => name !== "sampleGapMs" && own(input, name)) && !own(input, "sampleGapMs")) throw new TypeError("Invalid stability profile limits.sampleGapMs is required for database thresholds");
  const limits = {};
  for (const name of ["memoryGrowthBytes", "databaseGrowthBytes", "pendingRuns", "unresolvedEffects", "databaseLockWaiters", "sampleGapMs"]) {
    if (own(input, name)) limits[name] = nonnegative(input[name], `limits.${name}`, true);
  }
  for (const name of ["pendingAgeSeconds", "poolQueuePerQueryMs"]) if (own(input, name)) limits[name] = nonnegative(input[name], `limits.${name}`);
  if (own(input, "tableRowGrowth")) {
    const tableGrowth = objectWithKeys(input.tableRowGrowth, "limits.tableRowGrowth", tableGrowthKeys, []);
    if (!Object.keys(tableGrowth).length) throw new TypeError("Invalid stability profile limits.tableRowGrowth: at least one table is required");
    limits.tableRowGrowth = {};
    for (const name of tableGrowthKeys) if (own(tableGrowth, name)) limits.tableRowGrowth[name] = nonnegative(tableGrowth[name], `limits.tableRowGrowth.${name}`, true);
  }
  return { version: 1, workload: { seconds: workload.seconds, clients: workload.clients, sampleMs: workload.sampleMs }, limits };
}

export function parseStabilityProfile(source) {
  if (typeof source !== "string") throw new TypeError("Invalid stability profile JSON");
  let document;
  try { document = JSON.parse(source); }
  catch { throw new TypeError("Invalid stability profile JSON"); }
  return validateStabilityProfile(document);
}

function profileFile(path) {
  const filename = resolve(path);
  if (statSync(filename).size > 65536) throw new TypeError("Invalid stability profile: maximum size is 65536 bytes");
  return parseStabilityProfile(readFileSync(filename, "utf8"));
}

export function stabilityConfiguration(arguments_) {
  const { values } = parseArgs({ args: arguments_, options: Object.fromEntries(["seconds", "clients", "sample-ms", "base-port", "out", "profile"].map((name) => [name, { type: "string" }])) });
  const selectedProfile = values.profile === undefined ? null : profileFile(values.profile);
  const integer = (name, fallback, minimum, maximum) => {
    const value = Number(values[name] ?? fallback);
    if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new TypeError(`Invalid ${name}`);
    return value;
  };
  const seconds = integer("seconds", selectedProfile?.workload.seconds ?? 86400, 5, 86400);
  const clients = integer("clients", selectedProfile?.workload.clients ?? 20, 2, 50);
  const sampleMs = integer("sample-ms", selectedProfile?.workload.sampleMs ?? 30000, 1000, 60000);
  return { seconds, clients, sampleMs,
    basePort: integer("base-port", 4250, 1024, 65530), output: resolve(values.out ?? resolve(root, ".local/readiness", `stability-${Date.now()}`)),
    profile: selectedProfile ? { version: 1, workload: { seconds, clients, sampleMs }, limits: selectedProfile.limits } : null };
}

export function stabilityWatchdogMs(seconds) {
  if (!Number.isSafeInteger(seconds) || seconds < 5 || seconds > 86400) throw new TypeError("Invalid stability watchdog duration");
  const innerSoakGraceSeconds = Math.max(60, Math.ceil(seconds / 20));
  return (seconds + innerSoakGraceSeconds + setupAndFinalizationSeconds) * 1000;
}

export function requiredStabilitySamples(seconds, sampleMs) {
  if (!Number.isSafeInteger(seconds) || seconds < 5 || seconds > 86400 || !Number.isSafeInteger(sampleMs) || sampleMs < 1000 || sampleMs > 60000) throw new TypeError("Invalid stability sampling cadence");
  return Math.max(2, Math.ceil(seconds * 1000 / sampleMs) + 1);
}

export function stabilityInterruptionFailure(reason) {
  if (reason === "watchdog") return "Stability watchdog expired";
  if (reason === "signal") return "Stability run interrupted by signal";
  return undefined;
}

function metric(value, integer = true) {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && (!integer || Number.isSafeInteger(value));
}

function maximum(samples, key, integer = true) {
  if (!Array.isArray(samples) || !samples.length) return null;
  let result = 0;
  for (const sample of samples) {
    if (!sample || !metric(sample[key], integer)) return null;
    result = Math.max(result, sample[key]);
  }
  return result;
}

function growth(samples, key) {
  if (!Array.isArray(samples) || samples.length < 2 || !metric(samples[0]?.[key])) return null;
  const peak = maximum(samples, key);
  return peak === null ? null : Math.max(0, peak - samples[0][key]);
}

function timestamp(value) {
  const result = typeof value === "string" ? Date.parse(value) : NaN;
  return Number.isSafeInteger(result) ? result : null;
}

function samplingCoverage(samples, runWindow, workload) {
  const result = { status: "unverified", sampleCount: Array.isArray(samples) ? samples.length : 0,
    requiredSamples: requiredStabilitySamples(workload.seconds, workload.sampleMs), monotonic: false, startCovered: false, endCovered: false,
    startGapMs: null, endGapMs: null, maxGapMs: null };
  if (!Array.isArray(samples) || !samples.length) return result;
  const startedAt = timestamp(runWindow?.workloadStartedAt);
  const finishedAt = timestamp(runWindow?.workloadFinishedAt);
  const times = samples.map((sample) => timestamp(sample?.at));
  if (startedAt === null || finishedAt === null || finishedAt < startedAt || times.some((value) => value === null)) return result;
  result.monotonic = times.every((value, index) => index === 0 || value > times[index - 1]);
  result.startCovered = times[0] <= startedAt;
  result.endCovered = times.at(-1) >= finishedAt;
  if (result.startCovered) result.startGapMs = startedAt - times[0];
  if (result.endCovered) result.endGapMs = times.at(-1) - finishedAt;
  if (!result.monotonic) return result;
  let maximumGap = 0;
  for (let index = 1; index < times.length; index++) maximumGap = Math.max(maximumGap, times[index] - times[index - 1]);
  if (result.startCovered) maximumGap = Math.max(maximumGap, result.startGapMs);
  if (result.endCovered) maximumGap = Math.max(maximumGap, result.endGapMs);
  if (!Number.isSafeInteger(maximumGap)) return result;
  result.maxGapMs = maximumGap;
  if (result.sampleCount >= result.requiredSamples && result.startCovered && result.endCovered) result.status = "passed";
  return result;
}

function nodeSeries(chat) {
  const initial = chat?.soak?.initial;
  const samples = chat?.soak?.samples;
  if (!Array.isArray(initial) || !initial.length || !Array.isArray(samples) || samples.length < 2) return null;
  const labels = initial.map((node) => node?.label);
  if (labels.some((label) => typeof label !== "string" || !label) || new Set(labels).size !== labels.length) return null;
  const nodesByLabel = (nodes) => {
    if (!Array.isArray(nodes) || nodes.length !== labels.length) return null;
    const result = new Map();
    for (const node of nodes) {
      if (!node || typeof node.label !== "string" || result.has(node.label) || !labels.includes(node.label)) return null;
      result.set(node.label, node);
    }
    return result;
  };
  const initialNodes = nodesByLabel(initial);
  const series = samples.map((sample) => nodesByLabel(sample?.nodes));
  return initialNodes && series.every(Boolean) ? { initial: initialNodes, samples: series } : null;
}

function memoryGrowth(chat) {
  const series = nodeSeries(chat);
  if (!series) return null;
  let result = 0;
  for (const [label, initial] of series.initial) {
    if (!metric(initial.memory_bytes)) return null;
    let peak = initial.memory_bytes;
    for (const sample of series.samples) {
      const value = sample.get(label).memory_bytes;
      if (!metric(value)) return null;
      peak = Math.max(peak, value);
    }
    result = Math.max(result, peak - initial.memory_bytes);
  }
  return result;
}

function poolQueuePerQuery(chat) {
  const series = nodeSeries(chat);
  if (!series) return null;
  let queueMicroseconds = 0;
  let queries = 0;
  for (const label of series.initial.keys()) {
    for (let index = 1; index < series.samples.length; index++) {
      const before = series.samples[index - 1].get(label).telemetry;
      const after = series.samples[index].get(label).telemetry;
      if (![before?.db_queue_microseconds, before?.db_queries, after?.db_queue_microseconds, after?.db_queries].every((value) => metric(value))) return null;
      const queueDelta = after.db_queue_microseconds - before.db_queue_microseconds;
      const queryDelta = after.db_queries - before.db_queries;
      if (queueDelta < 0 || queryDelta < 0) return null;
      queueMicroseconds += queueDelta;
      queries += queryDelta;
      if (!Number.isSafeInteger(queueMicroseconds) || !Number.isSafeInteger(queries)) return null;
    }
  }
  return queries > 0 ? queueMicroseconds / queries / 1000 : null;
}

function samplesByDatabase(samples) {
  return Object.fromEntries(domains.map((domain) => [domain, Array.isArray(samples?.[domain]) ? samples[domain] : []]));
}

export function evaluateStabilityThresholds({ profile, samples, chat, runComplete = true, runWindow }) {
  if (profile === null || profile === undefined) return { status: "not-run", profileVersion: null, runComplete: runComplete === true, checks: [], violations: [], unverified: [], databaseResults: {} };
  const { limits, workload } = validateStabilityProfile(profile);
  const checks = [];
  const add = (name, limit, observed, unit, aggregation, database = null) => checks.push({ name, database,
    status: observed === null ? "unverified" : observed <= limit ? "passed" : "failed", observed, limit, unit, aggregation });
  if (own(limits, "memoryGrowthBytes")) add("memoryGrowthBytes", limits.memoryGrowthBytes, memoryGrowth(chat), "bytes", "maximum-node-peak-minus-initial");
  const databaseSamples = samplesByDatabase(samples);
  const databaseResults = {};
  for (const domain of domains) {
    const firstCheck = checks.length;
    const selected = databaseLimitKeys.some((name) => own(limits, name));
    const coverage = selected ? samplingCoverage(databaseSamples[domain], runWindow, workload) : null;
    const observation = (callback) => coverage?.status === "passed" ? callback() : null;
    const current = databaseSamples[domain];
    if (own(limits, "databaseGrowthBytes")) add(`${domain}.databaseGrowthBytes`, limits.databaseGrowthBytes, observation(() => growth(current, "database_bytes")), "bytes", "peak-minus-baseline-sample", domain);
    for (const table of tableGrowthKeys) if (own(limits.tableRowGrowth ?? {}, table)) add(`${domain}.tableRowGrowth.${table}`, limits.tableRowGrowth[table], observation(() => growth(current, table)), "rows", "peak-minus-baseline-sample", domain);
    if (own(limits, "pendingRuns")) add(`${domain}.pendingRuns`, limits.pendingRuns, observation(() => maximum(current, "pending_runs")), "rows", "maximum-sample", domain);
    if (own(limits, "pendingAgeSeconds")) add(`${domain}.pendingAgeSeconds`, limits.pendingAgeSeconds, observation(() => maximum(current, "oldest_pending_seconds", false)), "seconds", "maximum-sample", domain);
    if (own(limits, "unresolvedEffects")) add(`${domain}.unresolvedEffects`, limits.unresolvedEffects, observation(() => maximum(current, "unresolved_effects")), "rows", "maximum-sample", domain);
    if (own(limits, "databaseLockWaiters")) add(`${domain}.databaseLockWaiters`, limits.databaseLockWaiters, observation(() => maximum(current, "database_lock_waiters")), "waiters", "maximum-sample", domain);
    if (own(limits, "sampleGapMs")) add(`${domain}.sampleGapMs`, limits.sampleGapMs, observation(() => coverage.maxGapMs), "milliseconds", "maximum-baseline-workload-and-final-sample-gap-including-end-coverage", domain);
    const domainChecks = checks.slice(firstCheck);
    const violations = domainChecks.filter((check) => check.status === "failed").map((check) => check.name);
    const unverified = domainChecks.filter((check) => check.status === "unverified").map((check) => check.name);
    databaseResults[domain] = { status: !domainChecks.length ? "not-run" : runComplete === true && !violations.length && !unverified.length ? "passed" : "failed",
      violations, unverified, samplingCoverage: coverage };
  }
  if (own(limits, "poolQueuePerQueryMs")) add("poolQueuePerQueryMs", limits.poolQueuePerQueryMs, poolQueuePerQuery(chat), "milliseconds", "sum-counter-delta-queue-time-divided-by-query-count");
  const violations = checks.filter((check) => check.status === "failed").map((check) => check.name);
  const unverified = checks.filter((check) => check.status === "unverified").map((check) => check.name);
  return { status: runComplete === true && !violations.length && !unverified.length ? "passed" : "failed", profileVersion: 1,
    runComplete: runComplete === true, checks, violations, unverified, databaseResults };
}

function clusterDatabaseURL(domain, protocol = "postgres:") {
  if (!domains.includes(domain) || !["postgres:", "ecto:"].includes(protocol)) throw new TypeError("Invalid fixed cluster database");
  return `${protocol}//postgres:postgres@127.0.0.1:55432/${domain}_cluster`;
}

function validateClusterDatabaseURLs() {
  for (const domain of domains) {
    const url = new URL(clusterDatabaseURL(domain));
    if (url.protocol !== "postgres:" || url.hostname !== "127.0.0.1" || url.pathname !== `/${domain}_cluster` || url.search || url.hash) throw new TypeError("Use isolated fixed loopback cluster databases");
  }
}

async function main() {
  const config = stabilityConfiguration(process.argv.slice(2));
  if (process.env.CLUSTER_DATABASE_URL) throw new TypeError("This wrapper uses the default isolated chat/agent cluster databases");
  validateClusterDatabaseURLs();
  await mkdir(config.output, { recursive: true, mode: 0o700 });
  const reportPath = resolve(config.output, "result.json");
  const fingerprint = await acceptanceFingerprint(root);
  const shortRun = config.seconds !== 86400;
  const watchdogMs = stabilityWatchdogMs(config.seconds);
  const report = { startedAt: new Date().toISOString(), status: "running", requestedSeconds: config.seconds, clients: config.clients, sampleMs: config.sampleMs,
    sourceFingerprint: fingerprint, profile: config.profile, runLabel: shortRun ? "short-smoke-correctness-only" : "same-host-24h-run",
    watchdogMs, baselinePersisted: false, workloadStartedAt: null, workloadFinishedAt: null,
    startupSamplesUnavailable: 0, sampleFailures: 0, samples: Object.fromEntries(domains.map((domain) => [domain, []])),
    databaseSampling: Object.fromEntries(domains.map((domain) => [domain, { startupSamplesUnavailable: 0, sampleFailures: 0 }])),
    boundary: "Same-host two-node test with independent chat/agent database gates, not multi-host faults. Configured limits are local gate thresholds, not production SLO verification.",
    productionSLO: "not-verified", stability24h: "not-verified",
    thresholdGate: { status: config.profile ? "running" : "not-run", profileVersion: config.profile?.version ?? null, runComplete: false, checks: [], violations: [], unverified: [], databaseResults: {} } };
  await writeFile(reportPath, JSON.stringify(report, null, 2) + "\n", { flag: "wx", mode: 0o600 });

  let databases = {};
  let log;
  let activeChild;
  let sampling;
  let timer;
  let interruption;
  let completed = false;
  let failure;
  let phase = "initialization";
  const persist = () => writeFile(reportPath, JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
  const interrupt = (reason) => {
    interruption ??= reason;
    process.exitCode = 1;
    if (activeChild) void activeChild.stop().catch(() => {});
  };
  const signal = () => interrupt("signal");
  process.once("SIGINT", signal); process.once("SIGTERM", signal);
  const timeout = setTimeout(() => interrupt("watchdog"), watchdogMs);

  async function sample() {
    if (sampling) return sampling;
    sampling = (async () => Promise.all(domains.map(async (domain) => {
      try {
        const statistics = await databases[domain].query("SELECT pg_database_size(current_database())::text AS database_bytes, (SELECT count(*) FROM sessions)::text AS sessions, (SELECT count(*) FROM idempotency_results)::text AS idempotency_results, (SELECT count(*) FROM oban_jobs)::text AS jobs, (SELECT count(*) FROM fyrlet_runs WHERE status='pending')::text AS pending_runs, (SELECT coalesce(extract(epoch FROM (clock_timestamp()-min(inserted_at))),0) FROM fyrlet_runs WHERE status='pending')::text AS oldest_pending_seconds, (SELECT count(*) FROM fyrlet_effects WHERE resolution_required OR status='unknown')::text AS unresolved_effects, (SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock')::text AS database_lock_waiters");
        report.samples[domain].push({ at: new Date().toISOString(), ...Object.fromEntries(Object.entries(statistics.rows[0]).map(([key, value]) => [key, Number(value)])) });
      } catch {
        const counter = report.samples[domain].length ? "sampleFailures" : "startupSamplesUnavailable";
        report.databaseSampling[domain][counter]++;
        report[counter]++;
      }
    })))();
    try { await sampling; } finally { sampling = undefined; }
  }

  try {
    const { Pool } = createRequire(new URL("../examples/inbox-react/package.json", import.meta.url))("pg");
    for (const domain of domains) {
      databases[domain] = new Pool({ connectionString: clusterDatabaseURL(domain), max: 1,
        connectionTimeoutMillis: 2000, query_timeout: 5000, options: "-c default_transaction_read_only=on" });
      databases[domain].on("error", () => {});
    }
    log = await open(resolve(config.output, "cluster.log"), "wx", 0o600);

    phase = "schema-preparation";
    for (const domain of domains) {
      if (interruption) throw new SafeStabilityError(stabilityInterruptionFailure(interruption));
      const integrationApp = resolve(root, "examples", domain);
      activeChild = launch("mix", ["fyrlet.migrate", "--create", "--quiet"], { cwd: integrationApp,
        env: { ...process.env, CLUSTER_DATABASE_URL: undefined, DATABASE_URL: clusterDatabaseURL(domain, "ecto:"), FYRLET_DOMAIN: domain,
          PHX_SERVER: "true", FYRLET_DOMAIN_INTEGRATION: "1", INTEGRATION_APP: integrationApp, CLUSTER_BASE_PORT: String(config.basePort) },
        stdio: ["ignore", log.fd, log.fd] });
      const exited = await activeChild.finished;
      activeChild = undefined;
      if (interruption) throw new SafeStabilityError(stabilityInterruptionFailure(interruption));
      if (exited.code !== 0) throw new SafeStabilityError(`Stability schema preparation failed for ${domain}`);
    }

    phase = "baseline-sampling";
    await sample();
    if (interruption) throw new SafeStabilityError(stabilityInterruptionFailure(interruption));
    if (domains.some((domain) => report.samples[domain].length !== 1) || report.startupSamplesUnavailable) throw new SafeStabilityError("Stability baseline requires every table in both cluster databases");
    report.baselinePersisted = true;
    report.baselinePersistedAt = new Date().toISOString();
    await persist();
    if (interruption) throw new SafeStabilityError(stabilityInterruptionFailure(interruption));

    phase = "workload";
    report.workloadStartedAt = new Date().toISOString();
    activeChild = launch("bash", ["scripts/cluster.sh", "chat", "agent"], { cwd: root, env: { ...process.env, CLUSTER_DATABASE_URL: undefined,
      CLUSTER_SOAK_SECONDS: String(config.seconds), CLUSTER_CLIENTS: String(config.clients), CLUSTER_BASE_PORT: String(config.basePort), CLUSTER_REPORT_DIR: resolve(config.output, "cluster") },
      stdio: ["ignore", log.fd, log.fd] });
    timer = setInterval(() => { void sample(); }, config.sampleMs);
    const exited = await activeChild.finished;
    report.workloadFinishedAt = new Date().toISOString();
    activeChild = undefined;
    clearInterval(timer); timer = undefined;
    if (interruption) throw new SafeStabilityError(stabilityInterruptionFailure(interruption));
    if (sampling) await sampling;
    await sample();
    if (interruption) throw new SafeStabilityError(stabilityInterruptionFailure(interruption));

    phase = "final-verification";
    report.chat = JSON.parse(await readFile(resolve(config.output, "cluster/chat.json"), "utf8"));
    report.agent = JSON.parse(await readFile(resolve(config.output, "cluster/agent.json"), "utf8"));
    if (exited.code !== 0 || report.chat.soak?.seconds !== config.seconds || !report.baselinePersisted || report.startupSamplesUnavailable || report.sampleFailures ||
      domains.some((domain) => report.samples[domain].length < 2)) throw new SafeStabilityError("Stability run incomplete or failed sampling/correctness");
    if ((await acceptanceFingerprint(root)).digest !== fingerprint.digest) throw new SafeStabilityError("Stability sources changed during verification");
    if (interruption) throw new SafeStabilityError(stabilityInterruptionFailure(interruption));
    completed = true;
  } catch (error) {
    failure = error instanceof SafeStabilityError ? error.message : `Stability ${phase} did not complete; inspect private logs`;
  } finally {
    clearInterval(timer);
    if (activeChild && !activeChild.ended) {
      try { await activeChild.stop(); } catch { failure ??= "Stability child cleanup did not complete"; }
    }
    activeChild = undefined;
    if (sampling) await sampling;
    for (const database of Object.values(databases)) {
      try { await database.end(); } catch { failure ??= "Stability database cleanup did not complete"; }
    }
    if (log) {
      try { await log.close(); } catch { failure ??= "Stability log cleanup did not complete"; }
    }

    const finalize = () => {
      failure ??= stabilityInterruptionFailure(interruption);
      const runComplete = completed && !interruption && report.baselinePersisted && !report.startupSamplesUnavailable && !report.sampleFailures;
      try {
        report.thresholdGate = evaluateStabilityThresholds({ profile: config.profile, samples: report.samples, chat: report.chat,
          runComplete, runWindow: { workloadStartedAt: report.workloadStartedAt, workloadFinishedAt: report.workloadFinishedAt } });
      } catch {
        report.thresholdGate = { status: config.profile ? "failed" : "not-run", profileVersion: config.profile?.version ?? null, runComplete: false,
          checks: [], violations: [], unverified: [], databaseResults: {} };
        failure ??= "Stability threshold evaluation did not complete";
      }
      if (!failure && config.profile && report.thresholdGate.status !== "passed") failure = report.thresholdGate.violations.length ? "Stability threshold limits exceeded" : "Stability threshold gate incomplete or unverified";
      report.status = failure ? "failed" : "passed";
      if (failure) report.failure = failure;
      report.stability24h = "not-verified";
      if (!failure && !shortRun) report.stability24h = config.profile ? "same-host-threshold-gate-passed; production-SLO-unverified" : "same-host-correctness-run-completed; production-resource-SLO-unverified";
      report.finishedAt = new Date().toISOString();
    };

    finalize();
    try {
      await persist();
      if (interruption && report.status === "passed") {
        failure ??= stabilityInterruptionFailure(interruption);
        finalize();
        await persist();
      }
    } catch {
      report.status = "failed";
      report.failure = "Stability final report could not be persisted";
      report.finishedAt = new Date().toISOString();
      process.exitCode = 1;
      console.error("Stability final report could not be persisted");
    }
    clearTimeout(timeout);
    process.removeListener("SIGINT", signal); process.removeListener("SIGTERM", signal);
    console.log(`Stability ${report.status}: ${reportPath}`);
    if (report.status !== "passed") process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await main(); } catch { console.error("Stability run could not start; check configuration and local prerequisites"); process.exitCode = 1; }
}
