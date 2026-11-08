import { execFile } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { chmod, lstat, mkdir, open, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { basename, dirname, isAbsolute, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs, promisify } from "node:util";

const root = fileURLToPath(new URL("../", import.meta.url));
const executeFile = promisify(execFile);
const STATUSES = new Set(["passed", "failed", "not-run"]);
const SECRET_KEY = /(?:authorization|cookie|credential|passwd|password|private[_-]?key|secret|service[_-]?key|api[_-]?key|token|connection[_-]?string|database[_-]?url)/i;
const SECRET_LITERAL = /(?:\brtk_[a-z0-9_-]{8,}|\bBearer\s+[a-z0-9._~+/=-]+|\b(?:password|passwd|secret|token|api[_-]?key|service[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret)\s*[:=]\s*[^\s,;&#]+|(?:postgres(?:ql)?|mysql|rediss?):\/\/)/i;
const URL_CREDENTIAL = /\b[a-z][a-z0-9+.-]*:\/\/[^\s/@]+:[^\s/@]*@/i;
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
const SAFE_LABEL = /^[A-Za-z0-9][A-Za-z0-9_.:/@#-]{0,199}$/;
const ENV_NAME = /^[A-Z_][A-Z0-9_]{0,127}$/;
const ACTIONS = new Set(["get-route", "inspect", "select", "start", "stop"]);

export class ConfigError extends TypeError {}
export class OptInError extends Error {}

function invariant(condition, message) {
  if (!condition) throw new ConfigError(message);
}

function plainObject(value, path, allowed, required = allowed) {
  invariant(value && typeof value === "object" && !Array.isArray(value), `${path} must be an object`);
  for (const key of Object.keys(value)) invariant(allowed.includes(key), `${path} contains an unknown field`);
  for (const key of required) invariant(Object.hasOwn(value, key), `${path} is missing a required field`);
  return value;
}

function text(value, path, maximum = 200) {
  invariant(typeof value === "string" && value.length > 0 && value.length <= maximum && !/[\0\r\n]/.test(value), `${path} must be a nonempty single-line string`);
  invariant(!SECRET_LITERAL.test(value) && !URL_CREDENTIAL.test(value), `${path} must not contain a credential or connection string`);
  return value;
}

function boolean(value, path) {
  invariant(typeof value === "boolean", `${path} must be a boolean`);
  return value;
}

function integer(value, path, minimum, maximum) {
  invariant(Number.isSafeInteger(value) && value >= minimum && value <= maximum, `${path} is outside its allowed range`);
  return value;
}

function identifier(value, path) {
  text(value, path, 64);
  invariant(SAFE_ID.test(value), `${path} has an invalid identifier`);
  return value;
}

function label(value, path) {
  text(value, path, 200);
  invariant(SAFE_LABEL.test(value), `${path} must be a nonsecret identifier or reference label`);
  return value;
}

function environmentName(value, path) {
  text(value, path, 128);
  invariant(ENV_NAME.test(value), `${path} must name an environment variable, not contain its value`);
  return value;
}

function adapterReference(value, path) {
  text(value, path, 300);
  invariant(/^\.\.?\//.test(value) && !value.includes("\\") && !value.includes("?") && !value.includes("#"), `${path} must be a relative module path`);
  return value;
}

export function isLoopbackHostname(hostname) {
  let value = String(hostname).toLowerCase().replace(/\.$/, "");
  if (value.startsWith("[") && value.endsWith("]")) value = value.slice(1, -1);
  if (value === "localhost" || value.endsWith(".localhost") || value === "::1" || /^127(?:\.\d{1,3}){3}$/.test(value)) return true;
  const mappedDecimal = value.match(/^(?:::ffff:|0:0:0:0:0:ffff:)(127(?:\.\d{1,3}){3})$/);
  if (mappedDecimal) return true;
  const mappedHex = value.match(/^(?:::ffff:|0:0:0:0:0:ffff:)([0-9a-f]{1,4}):([0-9a-f]{1,4})$/);
  return Boolean(mappedHex && Number.parseInt(mappedHex[1], 16) >>> 8 === 127);
}

export function validateEndpoint(value, { allowLoopback = false } = {}) {
  text(value, "Endpoint", 2000);
  let url;
  try { url = new URL(value); } catch { throw new ConfigError("Endpoint must be an absolute HTTP(S) URL"); }
  invariant(["http:", "https:"].includes(url.protocol), "Endpoint must use HTTP(S)");
  invariant(!url.username && !url.password && !url.search && !url.hash, "Endpoint must not contain credentials, query parameters or a fragment");
  invariant(url.protocol === "https:" || isLoopbackHostname(url.hostname), "HTTPS is required for every non-loopback endpoint");
  invariant(!isLoopbackHostname(url.hostname) || allowLoopback, "Loopback endpoints require explicit execution.allowLoopbackEndpoints opt-in for an operator-managed tunnel");
  return url.toString().replace(/\/$/, "");
}

function validateFixedArguments(values) {
  invariant(Array.isArray(values) && values.length <= 32, "control.fixedArgs must be a bounded array");
  return values.map((value) => {
    text(value, "control.fixedArgs entry", 256);
    invariant(!ACTIONS.has(value) && !["--node", "--action"].includes(value) && !/^--(?:node|action)=/.test(value), "control.fixedArgs must not override reserved control actions, --node or --action");
    invariant(!/^--\S*(?:token|secret|password|passwd|credential|api[-_]?key|service[-_]?key)(?:=|$)/i.test(value), "Control credentials must not be placed in fixedArgs");
    return value;
  });
}

export function validateConfig(input) {
  plainObject(input, "config", ["schemaVersion", "execution", "project", "attestation", "deployment", "recoveryEndpoint", "nodes", "fault", "control", "workload"]);
  invariant(input.schemaVersion === 1, "config.schemaVersion must be 1");
  const executionInput = plainObject(input.execution, "execution", ["realMultiHostOptIn", "allowLoopbackEndpoints", "timeoutMs", "sessionTtlSeconds"], ["realMultiHostOptIn"]);
  const execution = {
    realMultiHostOptIn: boolean(executionInput.realMultiHostOptIn, "execution.realMultiHostOptIn"),
    allowLoopbackEndpoints: executionInput.allowLoopbackEndpoints === undefined ? false : boolean(executionInput.allowLoopbackEndpoints, "execution.allowLoopbackEndpoints"),
    timeoutMs: integer(executionInput.timeoutMs ?? 15_000, "execution.timeoutMs", 1000, 120_000),
    sessionTtlSeconds: integer(executionInput.sessionTtlSeconds ?? 900, "execution.sessionTtlSeconds", 300, 3600),
  };
  const projectInput = plainObject(input.project, "project", ["projectIdEnv", "serviceKeyEnv"]);
  const project = {
    projectIdEnv: environmentName(projectInput.projectIdEnv, "project.projectIdEnv"),
    serviceKeyEnv: environmentName(projectInput.serviceKeyEnv, "project.serviceKeyEnv"),
  };
  invariant(project.projectIdEnv !== project.serviceKeyEnv, "Project ID and service key must come from different environment variables");
  const attestationInput = plainObject(input.attestation, "attestation", ["operator", "attestedAt", "evidenceRef", "distinctPhysicalHosts", "sharedPostgreSQL", "sameRelease", "sameSchema"]);
  const attestedAt = text(attestationInput.attestedAt, "attestation.attestedAt", 64);
  invariant(/^\d{4}-\d{2}-\d{2}T/.test(attestedAt) && Number.isFinite(Date.parse(attestedAt)), "attestation.attestedAt must be an ISO timestamp");
  const attestation = {
    operator: text(attestationInput.operator, "attestation.operator"),
    attestedAt: new Date(attestedAt).toISOString(),
    evidenceRef: label(attestationInput.evidenceRef, "attestation.evidenceRef"),
    distinctPhysicalHosts: attestationInput.distinctPhysicalHosts,
    sharedPostgreSQL: attestationInput.sharedPostgreSQL,
    sameRelease: attestationInput.sameRelease,
    sameSchema: attestationInput.sameSchema,
  };
  for (const key of ["distinctPhysicalHosts", "sharedPostgreSQL", "sameRelease", "sameSchema"]) {
    invariant(attestation[key] === true, `attestation.${key} must be explicitly attested true`);
  }
  const deploymentInput = plainObject(input.deployment, "deployment", ["release", "schema", "database"]);
  const deployment = {
    release: label(deploymentInput.release, "deployment.release"),
    schema: label(deploymentInput.schema, "deployment.schema"),
    database: label(deploymentInput.database, "deployment.database"),
  };
  invariant(!deployment.database.includes("://") && !deployment.database.includes("@"), "deployment.database must be a nonsecret operator label, never a DSN");
  invariant(Array.isArray(input.nodes) && input.nodes.length >= 2 && input.nodes.length <= 16, "At least two and at most sixteen nodes are required");
  const nodes = input.nodes.map((node, index) => {
    const value = plainObject(node, `nodes[${index}]`, ["id", "endpoint", "physicalHostId", "expectedInstanceId"]);
    return {
      id: identifier(value.id, `nodes[${index}].id`),
      endpoint: validateEndpoint(value.endpoint, { allowLoopback: execution.allowLoopbackEndpoints }),
      physicalHostId: label(value.physicalHostId, `nodes[${index}].physicalHostId`),
      expectedInstanceId: label(value.expectedInstanceId, `nodes[${index}].expectedInstanceId`),
    };
  });
  for (const key of ["id", "endpoint", "expectedInstanceId"]) invariant(new Set(nodes.map((node) => node[key])).size === nodes.length, `Node ${key} values must be unique`);
  invariant(new Set(nodes.map((node) => node.physicalHostId)).size >= 2, "At least two distinct operator-attested physical hosts are required");
  const recoveryEndpoint = validateEndpoint(input.recoveryEndpoint, { allowLoopback: execution.allowLoopbackEndpoints });
  invariant(!nodes.some((node) => node.endpoint === recoveryEndpoint), "recoveryEndpoint must be a separate stable routed endpoint, not a direct node URL");
  const faultInput = plainObject(input.fault, "fault", ["victim", "survivor"]);
  const victim = nodes.find((node) => node.id === faultInput.victim);
  const survivor = nodes.find((node) => node.id === faultInput.survivor);
  invariant(victim && survivor && victim.id !== survivor.id, "fault victim and survivor must reference different configured nodes");
  invariant(victim.physicalHostId !== survivor.physicalHostId, "fault victim and survivor must be attested on different physical hosts");
  const controlInput = plainObject(input.control, "control", ["adapter", "executable", "fixedArgs", "timeoutMs"], ["adapter", "executable"]);
  text(controlInput.executable, "control.executable", 500);
  invariant(isAbsolute(controlInput.executable), "control.executable must be an absolute executable path");
  const control = {
    adapter: adapterReference(controlInput.adapter, "control.adapter"),
    executable: controlInput.executable,
    fixedArgs: validateFixedArguments(controlInput.fixedArgs ?? []),
    timeoutMs: integer(controlInput.timeoutMs ?? 30_000, "control.timeoutMs", 1000, 120_000),
  };
  const workloadInput = plainObject(input.workload, "workload", ["adapter", "kind", "runs"]);
  const workload = {
    adapter: adapterReference(workloadInput.adapter, "workload.adapter"),
    kind: identifier(workloadInput.kind, "workload.kind"),
    runs: boolean(workloadInput.runs, "workload.runs"),
  };
  return { schemaVersion: 1, execution, project, attestation, deployment, recoveryEndpoint, nodes, fault: { victim: victim.id, survivor: survivor.id }, control, workload };
}

export function assertRealOptIn(config, cliOptIn) {
  if (cliOptIn !== true || config.execution.realMultiHostOptIn !== true) {
    throw new OptInError("Real network and fault control require both --execute-real-multihost and execution.realMultiHostOptIn=true");
  }
}

export function redact(value, key = "", seen = new WeakMap()) {
  if (SECRET_KEY.test(key)) return "[REDACTED]";
  if (typeof value === "string") {
    return value
      .replace(/\bBearer\s+[A-Za-z0-9._~+/=-]+/gi, "Bearer [REDACTED]")
      .replace(/\brtk_[A-Za-z0-9_-]+/gi, "[REDACTED]")
      .replace(/\b(?:postgres(?:ql)?|mysql|rediss?):\/\/[^\s,;]+/gi, "[REDACTED]")
      .replace(/\b([a-z][a-z0-9+.-]*:\/\/)[^\s/@]+:[^\s/@]*@/gi, "$1[REDACTED]@")
      .replace(/\b(password|passwd|secret|token|api[_-]?key|service[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret)(\s*[:=]\s*)[^\s,;&#]+/gi, "$1$2[REDACTED]");
  }
  if (!value || typeof value !== "object") return value;
  if (seen.has(value)) return "[Circular]";
  seen.set(value, true);
  if (Array.isArray(value)) return value.map((entry) => redact(entry, "", seen));
  return Object.fromEntries(Object.entries(value).map(([entryKey, entry]) => [entryKey, redact(entry, entryKey, seen)]));
}

export function publicError(error, fallback) {
  let suffix = "";
  if (error && typeof error.code === "string" && /^[A-Z0-9_.-]{1,64}$/i.test(error.code)) suffix += `; code=${redact(error.code)}`;
  if (error && Number.isInteger(error.status) && error.status >= 400 && error.status <= 599) suffix += `; HTTP ${error.status}`;
  return `${fallback}${suffix}`;
}

function scenarioDefinitions(runsRequired = false) {
  return [
    ["configuration", true], ["runtime_prerequisites", true], ["runner_source", true], ["topology", true],
    ["workload_setup", true], ["idempotency", true], ["cross_user_isolation", true], ["runs", runsRequired],
    ["cross_host_subscription_recovery", true], ["writes_after_failure", true], ["node_rejoin", true], ["cleanup", true], ["source_stability", true],
  ];
}

export function createReport(mode = "config-check", runsRequired = false) {
  return {
    schemaVersion: 1,
    tool: "fyrlet-multihost-acceptance",
    drillId: randomUUID(),
    startedAt: new Date().toISOString(),
    mode,
    status: "not-run",
    reason: "Acceptance has not completed; local validation is not external evidence",
    topologyCaveat: "Physical hosts, shared PostgreSQL and deployment identity are operator attestations checked against hook metadata; URLs cannot prove physical topology.",
    scenarios: scenarioDefinitions(runsRequired).map(([name, required]) => ({ name, required, status: "not-run", reason: required ? "Required scenario has not run" : "Optional scenario is not enabled or not supported" })),
    controlEvents: [],
  };
}

export function setScenario(report, name, status, reason, details) {
  invariant(STATUSES.has(status), "Invalid scenario status");
  const scenario = report.scenarios.find((entry) => entry.name === name);
  if (!scenario) throw new Error(`Unknown scenario: ${name}`);
  scenario.status = status;
  scenario.reason = text(reason, "Scenario reason", 500);
  if (details !== undefined) scenario.details = redact(details);
  return scenario;
}

export function summarizeScenarios(scenarios) {
  if (!Array.isArray(scenarios) || scenarios.length === 0 || scenarios.some((scenario) => !STATUSES.has(scenario.status))) return "failed";
  if (scenarios.some((scenario) => scenario.status === "failed")) return "failed";
  if (scenarios.some((scenario) => scenario.required && scenario.status !== "passed")) return "not-run";
  return scenarios.some((scenario) => scenario.required && scenario.status === "passed") ? "passed" : "not-run";
}

export function finalizeReport(report) {
  report.status = summarizeScenarios(report.scenarios);
  report.reason = {
    passed: "All required scenarios passed; any not-run scenarios were optional",
    failed: "One or more scenarios failed; this is not acceptance evidence",
    "not-run": "One or more required scenarios are incomplete; this is not acceptance evidence",
  }[report.status];
  if (report.interrupted && report.status === "passed") {
    report.status = "not-run";
    report.reason = "The drill was interrupted; cleanup evidence does not make an interrupted acceptance complete";
  }
  report.finishedAt = new Date().toISOString();
  return report;
}

export function exitCodeForStatus(status) {
  if (status === "passed") return 0;
  if (status === "failed") return 1;
  if (status === "not-run") return 2;
  return 1;
}

export async function createReportStore(directory) {
  const output = resolve(directory);
  await mkdir(output, { recursive: true, mode: 0o700 });
  const info = await lstat(output);
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error("Report output must be a real directory, not a symbolic link");
  await chmod(output, 0o700);
  const reportPath = resolve(output, "result.json");
  const initial = await open(reportPath, "wx", 0o600);
  await initial.close();
  return {
    path: reportPath,
    async persist(report) {
      const temporary = resolve(output, `.result-${process.pid}-${randomUUID()}.tmp`);
      try {
        await writeFile(temporary, JSON.stringify(redact(report), null, 2) + "\n", { mode: 0o600, flag: "wx" });
        await rename(temporary, reportPath);
      } finally {
        await rm(temporary, { force: true });
      }
    },
  };
}

export function parseArguments(argv) {
  const { values, tokens } = parseArgs({
    args: argv,
    options: {
      config: { type: "string" },
      out: { type: "string" },
      "execute-real-multihost": { type: "boolean" },
      help: { type: "boolean", short: "h" },
    },
    allowPositionals: false,
    tokens: true,
  });
  const names = tokens.filter((token) => token.kind === "option").map((token) => token.name);
  if (new Set(names).size !== names.length) throw new ConfigError("Duplicate CLI options are ambiguous");
  if (values.help) return { help: true };
  invariant(typeof values.config === "string" && values.config.length > 0, "--config is required");
  return { help: false, config: values.config, out: values.out, execute: values["execute-real-multihost"] === true };
}

export async function waitFor(check, timeoutMs = 15_000, intervalMs = 100) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() <= deadline) {
    if (await check()) return;
    if (Date.now() + intervalMs > deadline) break;
    await new Promise((resolveDelay) => setTimeout(resolveDelay, intervalMs));
  }
  throw new Error("Timed out waiting for an acceptance condition");
}

export function validateNodeMetadata(config, node, observed) {
  invariant(observed && typeof observed === "object", "Deployment metadata is missing a configured node");
  invariant(observed.instanceId === node.expectedInstanceId, "Observed instance identity does not match the configured expectation");
  invariant(observed.physicalHostId === node.physicalHostId, "Observed physical-host attestation does not match the configured expectation");
  invariant(observed.release === config.deployment.release && observed.schema === config.deployment.schema, "A node does not run the expected release and schema");
  invariant(observed.database === config.deployment.database, "A node does not report the expected shared PostgreSQL identity");
  return true;
}

export function validateObservedMetadata(config, observations) {
  invariant(Array.isArray(observations) && observations.length === config.nodes.length, "Deployment metadata is incomplete");
  const byNode = new Map(observations.map((entry) => [entry.nodeId, entry]));
  invariant(byNode.size === observations.length, "Deployment metadata contains duplicate node identities");
  for (const node of config.nodes) validateNodeMetadata(config, node, byNode.get(node.id));
  invariant(new Set(observations.map((entry) => entry.instanceId)).size === config.nodes.length, "Observed instance identities must be unique");
  invariant(new Set(observations.map((entry) => entry.physicalHostId)).size >= 2, "Observed metadata must retain at least two attested physical hosts");
  return true;
}

function modulePath(configPath, reference) {
  return pathToFileURL(resolve(dirname(configPath), reference)).href;
}

async function endpointReady(endpoint, timeoutMs) {
  for (const path of ["health", "ready"]) {
    try {
      const response = await fetch(`${endpoint}/${path}`, { cache: "no-store", credentials: "omit", redirect: "error", signal: AbortSignal.timeout(timeoutMs) });
      await response.body?.cancel();
      if (!response.ok) return false;
    } catch { return false; }
  }
  return true;
}

async function collectRunnerSource() {
  const { acceptanceFingerprint } = await import("./acceptance.mjs");
  const fingerprint = await acceptanceFingerprint(root);
  const [{ stdout: revision }, { stdout: status }] = await Promise.all([
    executeFile("git", ["rev-parse", "HEAD"], { cwd: root, maxBuffer: 1024 * 1024 }),
    executeFile("git", ["status", "--porcelain=v1", "--untracked-files=all"], { cwd: root, maxBuffer: 16 * 1024 * 1024 }),
  ]);
  return { fingerprint, revision: revision.trim(), dirty: status.trim().length > 0, node: process.version, scope: "Clean runner checkout plus separately hashed runtime artifacts; deployed release identity is recorded separately" };
}

async function filesUnder(directory, label) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) files.push(...await filesUnder(path, `${label}/${entry.name}`));
    else files.push({ label: `${label}/${entry.name}`, path });
  }
  return files;
}

export async function hashRuntimeFiles(entries) {
  invariant(Array.isArray(entries) && entries.length > 0, "Runtime artifact inventory must not be empty");
  const ordered = [...entries].sort((left, right) => left.label.localeCompare(right.label));
  invariant(new Set(ordered.map((entry) => entry.label)).size === ordered.length, "Runtime artifact labels must be unique");
  const hash = createHash("sha256");
  for (const entry of ordered) {
    const info = await lstat(entry.path);
    if (!info.isFile() && !info.isSymbolicLink()) throw new Error("Runtime artifacts must be files");
    const bytes = await readFile(entry.path);
    hash.update(`${entry.label}\0${info.mode & 0o111}\0${bytes.byteLength}\0`);
    hash.update(bytes);
    hash.update("\0");
  }
  return { algorithm: "sha256", digest: hash.digest("hex"), fileCount: ordered.length };
}

async function collectRuntimeArtifacts(config, configPath) {
  const entries = [
    ...await filesUnder(resolve(root, "sdks/typescript/dist"), "sdk-dist"),
    ...await filesUnder(resolve(root, "sdks/typescript/node_modules/phoenix"), "phoenix-runtime"),
    { label: "control-adapter", path: resolve(dirname(configPath), config.control.adapter) },
    { label: "workload-adapter", path: resolve(dirname(configPath), config.workload.adapter) },
    { label: "control-executable", path: config.control.executable },
  ];
  return {
    ...await hashRuntimeFiles(entries),
    scope: "Fresh SDK dist, installed Phoenix runtime, workload/control adapter entry modules and control executable; custom transitive adapter dependencies remain trusted operator code",
  };
}

async function rebuildSdkRuntime() {
  await rm(resolve(root, "sdks/typescript/dist"), { recursive: true, force: true });
  await executeFile("npm", ["--prefix", "sdks/typescript", "run", "build"], {
    cwd: root, timeout: 120_000, maxBuffer: 1024 * 1024, env: { ...process.env, NODE_ENV: "production" },
  });
}

function publicConfig(config, digest) {
  return {
    sha256: digest,
    schemaVersion: config.schemaVersion,
    workload: { kind: config.workload.kind, runs: config.workload.runs, adapter: basename(config.workload.adapter) },
    control: { adapter: basename(config.control.adapter), executable: basename(config.control.executable), fixedArgumentCount: config.control.fixedArgs.length },
    credentialSources: { projectIdEnv: config.project.projectIdEnv, serviceKeyEnv: config.project.serviceKeyEnv },
  };
}

function recordControl(report, event) {
  if (report.controlEvents.length < 200) report.controlEvents.push(redact(event));
  else report.controlEventsTruncated = true;
}

export function boundedSessionCall(start, timeoutMs) {
  const controller = new AbortController();
  let timer;
  const raw = Promise.resolve().then(() => start(controller.signal));
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      const error = new Error("Session operation timed out");
      error.code = "TIMEOUT";
      controller.abort(error);
      reject(error);
    }, timeoutMs);
  });
  const operation = Promise.race([raw, timeout]).finally(() => clearTimeout(timer));
  return { raw, operation };
}

export function createSessionLifecycle({ subject, service, revocationService, timeoutMs, sessionTtlSeconds }) {
  const state = {
    client: undefined,
    subject,
    sessionIds: new Set(),
    pendingIssues: new Set(),
    lateRevocations: new Set(),
    unknownSessionOutcomes: 0,
    cleanupStarted: false,
  };
  let session;
  const revoke = (sessionId) => boundedSessionCall(
    (signal) => revocationService.revokeSession(sessionId, signal), timeoutMs,
  ).operation;
  const issue = () => {
    if (state.cleanupStarted) return Promise.reject(new Error("Session issuance is closed during cleanup"));
    const call = boundedSessionCall(
      (signal) => service.issueSession({ external_subject: subject, ttl_seconds: sessionTtlSeconds }, signal),
      timeoutMs,
    );
    let operation;
    operation = call.operation.then(async (issued) => {
      const hasSessionId = typeof issued?.session_id === "string" && issued.session_id.length > 0;
      if (hasSessionId) state.sessionIds.add(issued.session_id);
      if (!hasSessionId || typeof issued?.token !== "string" || issued.token.length === 0) {
        state.unknownSessionOutcomes += 1;
        throw new Error("The session issuance outcome was invalid and requires reconciliation");
      }
      if (state.cleanupStarted) {
        state.unknownSessionOutcomes += 1;
        throw new Error("A session was issued after cleanup started");
      }
      session = issued;
      state.sessionIds.add(issued.session_id);
      return issued;
    }, (error) => {
      state.unknownSessionOutcomes += 1;
      let lateRevocation;
      lateRevocation = call.raw.then(async (late) => {
        if (!late?.session_id) return;
        try { await revoke(late.session_id); } catch { /* The unknown outcome still fails cleanup. */ }
      }).catch(() => {}).finally(() => state.lateRevocations.delete(lateRevocation));
      state.lateRevocations.add(lateRevocation);
      throw error;
    }).finally(() => state.pendingIssues.delete(operation));
    state.pendingIssues.add(operation);
    return operation;
  };
  return {
    state,
    issue,
    async getToken({ forceRefresh }) {
      if (state.cleanupStarted) throw new Error("The drill client is being cleaned up");
      if (forceRefresh || !session) await issue();
      if (state.cleanupStarted || !session) throw new Error("No usable session remains during cleanup");
      return session.token;
    },
    async cleanup() {
      state.cleanupStarted = true;
      await Promise.allSettled([...state.pendingIssues]);
      const failures = [];
      for (const sessionId of state.sessionIds) {
        try { await revoke(sessionId); } catch { failures.push("session"); }
      }
      if (state.unknownSessionOutcomes > 0) failures.push("unknown-session-issuance-outcome");
      if (failures.length > 0) {
        const error = new Error(`Session cleanup failed: ${[...new Set(failures)].join(",")}`);
        error.cleanupFailures = failures;
        throw error;
      }
      return { drillSessionsRevoked: true, unknownSessionIssuanceOutcomes: 0 };
    },
  };
}

async function runReal(report, config, configPath, store) {
  let control;
  let workload;
  let sourceBefore;
  let runtimeBefore;
  const users = [];
  const projectId = process.env[config.project.projectIdEnv];
  const serviceKey = process.env[config.project.serviceKeyEnv];
  if (!projectId || !serviceKey || !serviceKey.startsWith("rtk_")) {
    setScenario(report, "runtime_prerequisites", "failed", "Credential environment is missing or invalid; no adapter, network or control action was attempted");
    await store.persist(report);
    return;
  }

  try {
    sourceBefore = await collectRunnerSource();
    if (sourceBefore.dirty) throw new Error("Real acceptance requires a clean source checkout");
    report.runnerSource = { ...sourceBefore };
    setScenario(report, "runner_source", "passed", "Exact runner revision and source fingerprint were recorded on a clean checkout");
    await store.persist(report);
  } catch (error) {
    setScenario(report, "runner_source", "failed", publicError(error, "Real acceptance requires a clean, readable source checkout"));
    await store.persist(report);
    return;
  }

  try {
    await rebuildSdkRuntime();
    runtimeBefore = await collectRuntimeArtifacts(config, configPath);
    report.runtimeArtifacts = { ...runtimeBefore };
    const [clientModule, serverModule, controlModule, workloadModule] = await Promise.all([
      import(pathToFileURL(resolve(root, "sdks/typescript/dist/index.js")).href),
      import(pathToFileURL(resolve(root, "sdks/typescript/dist/server.js")).href),
      import(modulePath(configPath, config.control.adapter)),
      import(modulePath(configPath, config.workload.adapter)),
    ]);
    if (typeof controlModule.createControl !== "function" || typeof workloadModule.createWorkload !== "function") throw new Error("Adapter exports are incomplete");
    const sdk = { createClient: clientModule.createClient, createSessionService: serverModule.createSessionService };
    control = await controlModule.createControl(config.control, {
      onEvent: (event) => recordControl(report, event),
      environment: process.env,
      deniedEnvironmentNames: [config.project.projectIdEnv, config.project.serviceKeyEnv],
    });
    const context = {
      config,
      drillId: report.drillId,
      control,
      waitFor: (check) => waitFor(check, config.execution.timeoutMs),
      isReady: (nodeId) => {
        const node = config.nodes.find((entry) => entry.id === nodeId);
        return node ? endpointReady(node.endpoint, Math.min(config.execution.timeoutMs, 5000)) : false;
      },
      verifyNode: async (nodeId) => {
        const node = config.nodes.find((entry) => entry.id === nodeId);
        if (!node) throw new Error("Unknown node");
        const metadata = await control.inspect(node.id);
        validateNodeMetadata(config, node, metadata);
        return metadata;
      },
      createUser: async ({ nodeId, routed = false, subject = randomUUID(), capabilities = { runs: 1, append: 1 } } = {}) => {
        const node = config.nodes.find((entry) => entry.id === nodeId);
        if (!routed && !node) throw new Error("A direct user requires a configured node");
        const endpoint = routed ? config.recoveryEndpoint : node.endpoint;
        const lifecycle = createSessionLifecycle({
          subject,
          service: sdk.createSessionService({ endpoint, serviceKey }),
          revocationService: sdk.createSessionService({ endpoint: config.recoveryEndpoint, serviceKey }),
          timeoutMs: config.execution.timeoutMs,
          sessionTtlSeconds: config.execution.sessionTtlSeconds,
        });
        users.push(lifecycle);
        await lifecycle.issue();
        lifecycle.state.client = sdk.createClient({
          endpoint,
          projectId,
          capabilities,
          timeoutMs: config.execution.timeoutMs,
          retryDelayMs: () => 100,
          getToken: lifecycle.getToken,
        });
        return { client: lifecycle.state.client, subject };
      },
    };
    workload = await workloadModule.createWorkload(context);
    if (!workload || workload.kind !== config.workload.kind || typeof workload.supportsRuns !== "boolean") throw new Error("Workload identity or capabilities are invalid");
    for (const method of ["setup", "idempotency", "crossUserIsolation", "crossHostSubscriptionRecovery", "writesAfterFailure", "rejoin", "cleanup", "recoveryRequired"]) {
      if (typeof workload[method] !== "function") throw new Error("Workload adapter methods are incomplete");
    }
    if (config.workload.runs && (!workload.supportsRuns || typeof workload.runs !== "function")) throw new Error("Runs were required but the workload does not support them");
    setScenario(report, "runtime_prerequisites", "passed", "The SDK was rebuilt from clean sources, runtime artifacts were hashed, and adapter contracts were loaded without a control action");
    await store.persist(report);
  } catch (error) {
    setScenario(report, "runtime_prerequisites", "failed", publicError(error, "Runtime prerequisites failed; verify the clean SDK build, runtime artifact inventory, credentials and adapters"));
    await store.persist(report);
    return;
  }

  const attempt = async (name, operation, passedReason = "Scenario assertions passed") => {
    const allowedDuringInterrupt = ["node_rejoin", "cleanup", "source_stability"].includes(name);
    if (report.interrupted && !allowedDuringInterrupt) {
      setScenario(report, name, "not-run", "Interrupted before this scenario; rejoin and cleanup remain eligible to run");
      await store.persist(report);
      return false;
    }
    try {
      const details = await operation();
      if (report.interrupted && !allowedDuringInterrupt) {
        setScenario(report, name, "not-run", "Interrupted before scenario completion could be accepted; rejoin and cleanup remain eligible to run");
        await store.persist(report);
        return false;
      }
      setScenario(report, name, "passed", passedReason, details);
      await store.persist(report);
      return true;
    } catch (error) {
      setScenario(report, name, "failed", publicError(error, `${name} failed; inspect the deployment independently without exposing private payloads`));
      await store.persist(report);
      return false;
    }
  };
  const block = (name) => setScenario(report, name, "not-run", "Blocked by an earlier failed or incomplete scenario");

  const topologyPassed = await attempt("topology", async () => {
    const observations = [];
    report.deployment = {
      expected: config.deployment,
      attestation: config.attestation,
      evidenceSource: "Operator attestation and allowlisted control-hook metadata; not independent physical-topology proof",
      nodes: config.nodes.map((node) => ({ ...node, observed: null })),
      recoveryEndpoint: config.recoveryEndpoint,
    };
    for (const node of config.nodes) {
      if (!(await endpointReady(node.endpoint, config.execution.timeoutMs))) throw new Error("A direct node is not healthy and ready");
      const metadata = await control.inspect(node.id);
      observations.push({ nodeId: node.id, ...metadata });
      report.deployment.nodes.find((entry) => entry.id === node.id).observed = metadata;
    }
    if (!(await endpointReady(config.recoveryEndpoint, config.execution.timeoutMs))) throw new Error("The recovery endpoint is not healthy and ready");
    validateObservedMetadata(config, observations);
    return { uniqueInstanceIdentities: true, sharedDatabaseExpectationMatched: true, releaseAndSchemaExpectationsMatched: true, directAndRoutedReadiness: true };
  }, "Direct/routed readiness and expected instance, host, release, schema and shared-database metadata matched");
  if (!topologyPassed) return;

  let setupAttempted = false;
  let faultAttempted = false;
  let healthy = true;
  try {
    setupAttempted = true;
    healthy = await attempt("workload_setup", () => workload.setup(), "Drill-only users/resources and cross-host subscriptions were established");
    for (const [name, method] of [["idempotency", "idempotency"], ["cross_user_isolation", "crossUserIsolation"], ["runs", "runs"]]) {
      if (name === "runs" && !config.workload.runs) continue;
      if (!healthy) { block(name); continue; }
      healthy = await attempt(name, () => workload[method]());
    }
    if (healthy) {
      faultAttempted = true;
      healthy = await attempt("cross_host_subscription_recovery", () => workload.crossHostSubscriptionRecovery(), "The routed SDK subscription recovered on the survivor with a new generation and retained pre-fault facts");
    } else block("cross_host_subscription_recovery");
    if (healthy) healthy = await attempt("writes_after_failure", () => workload.writesAfterFailure(), "Durable idempotency and new writes were correct on the surviving host and recovered subscription");
    else block("writes_after_failure");
    if (faultAttempted && workload.recoveryRequired()) {
      await attempt("node_rejoin", () => workload.rejoin(), "The stopped instance was started, direct readiness returned and deployment identity was reconfirmed");
    } else if (faultAttempted) {
      setScenario(report, "node_rejoin", "passed", "The workload reports that no stopped instance remains to rejoin");
    } else block("node_rejoin");
  } finally {
    if (setupAttempted) {
      await attempt("cleanup", async () => {
        const failures = [];
        try { await workload.cleanup(); } catch { failures.push("workload"); }
        for (const lifecycle of users.splice(0)) {
          lifecycle.state.cleanupStarted = true;
          try { lifecycle.state.client?.close(); } catch { failures.push("client"); }
          try { await lifecycle.cleanup(); }
          catch (error) { failures.push(...(error.cleanupFailures ?? ["session"])); }
        }
        if (failures.length) throw new Error(`Cleanup failed: ${[...new Set(failures)].join(",")}`);
        return { drillClientsClosed: true, drillSessionsRevoked: true, unknownSessionIssuanceOutcomes: 0, workloadCleanupCompleted: true };
      }, "Only drill-created workload state was cleaned; clients and drill-issued sessions were closed or revoked");
    }
    if (sourceBefore) {
      await attempt("source_stability", async () => {
        const after = await collectRunnerSource();
        const runtimeAfter = await collectRuntimeArtifacts(config, configPath);
        report.runnerSource.finalFingerprint = after.fingerprint.digest;
        report.runnerSource.finalRevision = after.revision;
        report.runnerSource.finalDirty = after.dirty;
        report.runtimeArtifacts.finalDigest = runtimeAfter.digest;
        if (after.dirty) throw new Error("The runner checkout became dirty");
        if (after.revision !== sourceBefore.revision) throw new Error("The runner Git revision changed");
        if (after.fingerprint.digest !== sourceBefore.fingerprint.digest) throw new Error("Runner sources changed");
        if (runtimeAfter.digest !== runtimeBefore.digest) throw new Error("Runtime artifacts changed during execution");
        return { sourceRevisionUnchanged: true, sourceFingerprintUnchanged: true, workingTreeRemainedClean: true, runtimeArtifactsUnchanged: true };
      }, "The exact runner revision, clean source fingerprint and hashed runtime artifacts remained unchanged during the drill");
    }
  }
}

export async function main(argv = process.argv.slice(2)) {
  let args;
  try { args = parseArguments(argv); } catch (error) {
    console.error(error instanceof ConfigError ? error.message : "Invalid command line");
    return 1;
  }
  if (args.help) {
    console.log("node scripts/multihost_acceptance.mjs --config FILE [--out PRIVATE_DIRECTORY] [--execute-real-multihost]\nWithout --execute-real-multihost: offline validation only; report status is not-run and exit code is 2.");
    return 0;
  }
  const output = resolve(args.out ?? resolve(root, ".local/readiness", `multihost-${Date.now()}`));
  let report = createReport("config-check");
  let store;
  try { store = await createReportStore(output); } catch {
    console.error("Could not create a private, non-overwriting report directory");
    return 1;
  }
  let config;
  let configPath;
  let executionPhase = "configuration";
  try {
    configPath = resolve(args.config);
    const bytes = await readFile(configPath);
    if (bytes.byteLength > 1024 * 1024) throw new ConfigError("Configuration exceeds the 1 MiB limit");
    let parsed;
    try { parsed = JSON.parse(bytes.toString("utf8")); } catch { throw new ConfigError("Configuration is not valid JSON"); }
    config = validateConfig(parsed);
    report = createReport(args.execute ? "real-multi-host" : "config-check", config.workload.runs);
    report.config = publicConfig(config, createHash("sha256").update(bytes).digest("hex"));
    setScenario(report, "configuration", "passed", "Strict offline schema, endpoint, topology-attestation and common credential-pattern checks passed");
    await store.persist(report);
    if (!args.execute) {
      for (const scenario of report.scenarios) {
        if (scenario.name !== "configuration") scenario.reason = scenario.required ? "Not run: offline configuration validation never performs real acceptance" : scenario.reason;
      }
    } else {
      assertRealOptIn(config, args.execute);
      executionPhase = "real-execution";
      const interrupt = () => { report.interrupted = true; };
      process.once("SIGINT", interrupt);
      process.once("SIGTERM", interrupt);
      try { await runReal(report, config, configPath, store); }
      finally {
        process.removeListener("SIGINT", interrupt);
        process.removeListener("SIGTERM", interrupt);
      }
    }
  } catch (error) {
    if (error instanceof OptInError) {
      report.optIn = error.message;
      for (const scenario of report.scenarios) {
        if (!["configuration"].includes(scenario.name) && scenario.status === "not-run") scenario.reason = "Not run: explicit real-execution opt-in is incomplete";
      }
    } else if (executionPhase === "real-execution") {
      report.runnerFailure = "The runner stopped unexpectedly during real execution; no raw error or secret payload was recorded";
      if (!report.scenarios.some((scenario) => scenario.status === "failed")) {
        setScenario(report, "source_stability", "failed", "The real execution phase ended unexpectedly; inspect the private deployment and runner state");
      }
    } else if (!report.scenarios.some((scenario) => scenario.status === "failed")) {
      const reason = error instanceof ConfigError ? `Configuration failed closed: ${error.message}` : "Configuration could not be read or validated; no network or control action was attempted";
      setScenario(report, "configuration", "failed", reason);
    } else {
      report.runnerFailure = "The runner stopped unexpectedly; no raw error or secret payload was recorded";
    }
  } finally {
    finalizeReport(report);
    try { await store.persist(report); } catch {
      console.error("Could not persist the private acceptance report");
      return 1;
    }
  }
  console.log(`Multi-host acceptance ${report.status}: ${store.path}`);
  return exitCodeForStatus(report.status);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = await main();
}
