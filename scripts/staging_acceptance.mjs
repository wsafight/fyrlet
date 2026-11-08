import { createHash, randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { chmod, lstat, mkdir, readdir, readFile, realpath, rename, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs, parseEnv, promisify } from "node:util";
import { acceptanceFingerprint } from "./acceptance.mjs";
import { checkDeployment } from "../examples/inbox-react/server/check.mjs";
import { storeConfiguration } from "../examples/inbox-react/server/store.mjs";

const executeFile = promisify(execFile);
const root = fileURLToPath(new URL("../", import.meta.url));
const appPackage = new URL("../examples/inbox-react/package.json", import.meta.url);
const appRequire = createRequire(appPackage);
const sdkRoot = fileURLToPath(new URL("../sdks/typescript/", import.meta.url));
const appSDKPath = fileURLToPath(new URL("../examples/inbox-react/node_modules/@fyrlet/client/", import.meta.url));
const loopback = new Set(["localhost", "127.0.0.1", "[::1]", "::1"]);
const requiredApplicationChecks = [
  "host-configuration", "primary-authentication", "bounded-session-expiry",
  "application-query-mutation-view-confirmation", "session-renewal", "logout-and-revocation", "browser-runtime",
];
const environmentName = /^[A-Za-z_][A-Za-z0-9_]*$/;
const deploymentName = /^[a-z][a-z0-9-]{1,63}$/;
const artifactDigest = /^sha256:[a-f0-9]{64}$/;
const sourceRevision = /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/;

/** An error whose message is deliberately safe for sanitized reports. */
export class StagingAcceptanceError extends Error {}

export function requireCondition(condition, message) {
  if (!condition) throw new StagingAcceptanceError(message);
}

function object(value) {
  return value && typeof value === "object" && !Array.isArray(value);
}

function string(value, maximum = 200) {
  return typeof value === "string" && value.length > 0 && value.length <= maximum;
}

/** Validate a URL without returning credentials, paths, query values or fragments in errors. */
export function secureURL(value, label, { exactOrigin = false, allowLoopback = true, allowFragment = false } = {}) {
  requireCondition(string(value, 2048), `${label} must be a URL`);
  let url;
  try { url = new URL(value); } catch { throw new StagingAcceptanceError(`${label} must be a URL`); }
  const localHTTP = allowLoopback && url.protocol === "http:" && loopback.has(url.hostname);
  requireCondition((url.protocol === "https:" || localHTTP) && !url.username && !url.password && (allowFragment || !url.hash),
    `${label} requires HTTPS without credentials${allowFragment ? "" : " or fragments"} (HTTP is loopback-only)`);
  if (exactOrigin) requireCondition(!url.search && url.pathname === "/" && value === url.origin,
    `${label} must be an exact origin without a trailing slash, path or query`);
  return url;
}

/** Restrict every browser request and login step to the active account's exact origins. */
export function requireAllowedBrowserOrigin(value, allowedOrigins) {
  const url = secureURL(value, "Browser URL", { allowFragment: true });
  const allowed = allowedOrigins instanceof Set ? allowedOrigins : new Set(allowedOrigins);
  requireCondition(allowed.has(url.origin), "Browser navigation or request origin is not allowed for the active account");
  return url.origin;
}

/** Phoenix's native WebSocket transport is allowed only at the configured API socket. */
export function requireAllowedWebSocketDestination(value, endpoint) {
  const base = secureURL(endpoint, "FYRLET_ENDPOINT");
  let url;
  try { url = new URL(value); } catch { throw new StagingAcceptanceError("Browser WebSocket destination must be an absolute URL"); }
  const expected = new URL(base);
  expected.protocol = base.protocol === "https:" ? "wss:" : "ws:";
  requireCondition(url.protocol === expected.protocol && url.origin === expected.origin && url.pathname === "/socket/websocket" &&
    !url.username && !url.password && !url.hash, "Browser WebSocket destination is not the configured API socket");
  return url;
}

function privateFile(path, label, requirePrivate = true) {
  return lstat(path).then((stat) => {
    requireCondition(stat.isFile() && !stat.isSymbolicLink(), `${label} must be a regular, non-symlink file`);
    if (requirePrivate && process.platform !== "win32") requireCondition((stat.mode & 0o077) === 0, `${label} must not be readable by group or other users`);
    return stat;
  }, (error) => {
    if (error instanceof StagingAcceptanceError) throw error;
    throw new StagingAcceptanceError(`${label} is missing or inaccessible`);
  });
}

async function readJSON(path, label, maximumBytes = 1024 * 1024, requirePrivate = true) {
  const stat = await privateFile(path, label, requirePrivate);
  requireCondition(stat.size <= maximumBytes, `${label} is too large`);
  let bytes;
  try { bytes = await readFile(path); } catch { throw new StagingAcceptanceError(`${label} is missing or inaccessible`); }
  try { return { value: JSON.parse(bytes.toString("utf8")), bytes }; }
  catch { throw new StagingAcceptanceError(`${label} must contain valid JSON`); }
}

function validateStorageState(value, publicOrigin) {
  requireCondition(object(value) && Array.isArray(value.cookies) && value.cookies.length <= 100 && Array.isArray(value.origins),
    "Storage state must be a Playwright cookies/origins object");
  requireCondition(value.origins.length === 0, "Storage state must contain cookies only; Inbox does not use local storage");
  for (const cookie of value.cookies) {
    requireCondition(object(cookie) && string(cookie.name, 256) && /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(cookie.name) &&
      typeof cookie.value === "string" && string(cookie.value, 8192) && !/[;\r\n\0]/.test(cookie.value),
      "Storage state contains an invalid cookie");
    requireCondition(!cookie.url || secureURL(cookie.url, "Storage-state cookie URL"), "Storage-state cookie URL is invalid");
    requireCondition(cookie.url || (string(cookie.domain, 512) && string(cookie.path, 2048)), "Storage-state cookies require a URL or domain/path");
    if (!cookie.url && string(cookie.domain, 512) && !loopback.has(cookie.domain.replace(/^\./, ""))) {
      requireCondition(cookie.secure === true, "Non-loopback storage-state cookies must be Secure");
    }
  }
  requireCondition(value.cookies.length === 1, "Storage state must contain exactly one fyrlet_host cookie and no unrelated cookies");
  const cookie = value.cookies[0];
  const application = new URL(publicOrigin);
  requireCondition(cookie.name === "fyrlet_host" && cookie.path === "/" && cookie.httpOnly === true && cookie.sameSite === "Lax" &&
    typeof cookie.secure === "boolean" && Number.isFinite(cookie.expires) && cookie.expires > 0,
    "Storage state must contain one bounded HttpOnly SameSite=Lax fyrlet_host cookie at Path=/");
  requireCondition(!application.protocol.startsWith("https") || cookie.secure, "HTTPS storage state requires a Secure host cookie");
  if (cookie.url) {
    const url = secureURL(cookie.url, "Storage-state cookie URL");
    requireCondition(!cookie.domain && url.origin === publicOrigin && url.pathname === "/" && !url.search && !url.hash,
      "Storage-state host cookie URL must be host-only at PUBLIC_ORIGIN with Path=/");
  } else {
    requireCondition(cookie.domain === application.hostname && !cookie.domain.startsWith("."),
      "Storage-state host cookie must be host-only for PUBLIC_ORIGIN, not a domain cookie");
  }
  return value;
}

function validateSteps(steps, secrets, label) {
  requireCondition(Array.isArray(steps) && steps.length <= 30, `${label} must contain at most 30 browser steps`);
  return steps.map((step, index) => {
    requireCondition(object(step) && ["fill", "click", "check", "uncheck", "press", "wait"].includes(step.action) && string(step.selector, 500),
      `${label} step ${index + 1} has an unsupported action or selector`);
    requireCondition(!Object.hasOwn(step, "value") && !Object.hasOwn(step, "text") && !Object.hasOwn(step, "password"),
      `${label} step ${index + 1} must reference secrets through valueFromEnv`);
    const result = { action: step.action, selector: step.selector };
    if (step.action === "fill") {
      requireCondition(environmentName.test(step.valueFromEnv ?? ""), `${label} fill step ${index + 1} requires valueFromEnv`);
      const value = secrets[step.valueFromEnv];
      requireCondition(string(value, 16384), `${label} is missing environment variable ${step.valueFromEnv}`);
      result.value = value;
    }
    if (step.action === "press") {
      requireCondition(string(step.key, 40) && /^[A-Za-z0-9+_-]+$/.test(step.key), `${label} press step ${index + 1} has an invalid key`);
      result.key = step.key;
    }
    return result;
  });
}

function validateAccount(value, providers, secrets, label, applicationOrigins) {
  requireCondition(object(value) && string(value.provider, 32) && providers.has(value.provider), `${label} must name a configured OIDC provider`);
  requireCondition(Array.isArray(value.allowedBrowserOrigins) && value.allowedBrowserOrigins.length >= applicationOrigins.length && value.allowedBrowserOrigins.length <= 16,
    `${label}.allowedBrowserOrigins must contain the application/API and explicit IdP or redirect origins`);
  const allowedBrowserOrigins = value.allowedBrowserOrigins.map((origin, index) =>
    secureURL(origin, `${label}.allowedBrowserOrigins entry ${index + 1}`, { exactOrigin: true }).origin);
  requireCondition(new Set(allowedBrowserOrigins).size === allowedBrowserOrigins.length && applicationOrigins.every((origin) => allowedBrowserOrigins.includes(origin)),
    `${label}.allowedBrowserOrigins must be unique and include PUBLIC_ORIGIN and FYRLET_ENDPOINT`);
  const account = { provider: value.provider, allowedBrowserOrigins };
  const hasSteps = Object.hasOwn(value, "steps");
  const hasState = Object.hasOwn(value, "storageStateFromEnv");
  requireCondition(hasSteps !== hasState, `${label} must configure exactly one of steps or storageStateFromEnv`);
  if (hasSteps) return { ...account, method: "interactive", steps: validateSteps(value.steps, secrets, label) };
  requireCondition(environmentName.test(value.storageStateFromEnv ?? ""), `${label} storageStateFromEnv must be an environment variable name`);
  const path = secrets[value.storageStateFromEnv];
  requireCondition(string(path, 4096), `${label} is missing environment variable ${value.storageStateFromEnv}`);
  return { ...account, method: "storage-state", storageStatePath: path };
}

function validateDeployment(value) {
  requireCondition(object(value) && deploymentName.test(value.id ?? ""), "deployment.id must be a stable lowercase identifier");
  requireCondition(sourceRevision.test(value.sourceRevision ?? "") && !/^0+$/.test(value.sourceRevision), "deployment.sourceRevision must be a full, non-placeholder lowercase Git revision");
  for (const name of ["hostArtifactDigest", "apiArtifactDigest"]) requireCondition(artifactDigest.test(value[name] ?? "") && !/^sha256:0+$/.test(value[name]), `deployment.${name} must be an exact, non-placeholder SHA-256 digest`);
  for (const name of ["hostRelease", "apiRelease"]) requireCondition(string(value[name], 200) && /^[A-Za-z0-9._/-]+$/.test(value[name]) &&
    !/^(?:latest|replace-with-)/i.test(value[name]), `deployment.${name} must be an immutable, non-placeholder release identifier`);
  return {
    id: value.id, sourceRevision: value.sourceRevision,
    hostArtifactDigest: value.hostArtifactDigest, apiArtifactDigest: value.apiArtifactDigest,
    hostRelease: value.hostRelease, apiRelease: value.apiRelease,
  };
}

function validateRevocation(value) {
  requireCondition(object(value) && value.strategy === "bounded-host-expiry", "revocation.strategy must be bounded-host-expiry");
  const host = value.maxHostSessionSeconds;
  const token = value.maxTokenSeconds;
  const skew = value.clockSkewSeconds ?? 5;
  requireCondition(Number.isSafeInteger(host) && host >= 60 && host <= 3600, "revocation.maxHostSessionSeconds must be between 60 and 3600");
  requireCondition(Number.isSafeInteger(token) && token >= 60 && token <= 600 && token <= host, "revocation.maxTokenSeconds must be between 60 and 600 and no longer than the host bound");
  requireCondition(Number.isSafeInteger(skew) && skew >= 0 && skew <= 30, "revocation.clockSkewSeconds must be between 0 and 30");
  return { strategy: value.strategy, maxHostSessionSeconds: host, maxTokenSeconds: token, clockSkewSeconds: skew };
}

/** Public, selected metadata only. Never stringify the loaded configuration or environment. */
export function publicMetadata(loaded) {
  return {
    configurationDigest: `sha256:${createHash("sha256").update(loaded.configurationBytes).digest("hex")}`,
    deployment: loaded.deployment,
    publicOrigin: loaded.publicOrigin,
    apiOrigin: loaded.endpoint,
    hosts: loaded.hosts,
    revocation: loaded.revocation,
    authentication: Object.fromEntries(Object.entries(loaded.accounts).map(([name, account]) => [name, {
      provider: account.provider, method: account.method, allowedBrowserOrigins: account.allowedBrowserOrigins,
    }])),
  };
}

/** Load and fully validate all network prerequisites. This function performs no network I/O. */
export async function loadStagingConfiguration(configPath, { environment = process.env } = {}) {
  const absolute = resolve(configPath);
  const directory = dirname(absolute);
  const { value: config, bytes: configurationBytes } = await readJSON(absolute, "Staging acceptance configuration", 1024 * 1024, false);
  requireCondition(object(config) && config.schemaVersion === 1, "Staging acceptance schemaVersion must be 1");
  requireCondition(string(config.environmentFile, 4096), "environmentFile is required");
  const environmentPath = resolve(directory, config.environmentFile);
  await privateFile(environmentPath, "Deployment environment file");
  let environmentText;
  try { environmentText = await readFile(environmentPath, "utf8"); } catch { throw new StagingAcceptanceError("Deployment environment file is missing or inaccessible"); }
  let hostEnvironment;
  try { hostEnvironment = parseEnv(environmentText); } catch { throw new StagingAcceptanceError("Deployment environment file is invalid"); }
  const required = ["PUBLIC_ORIGIN", "FYRLET_ENDPOINT", "FYRLET_PROJECT_ID", "FYRLET_SERVICE_KEY", "OIDC_PROVIDERS"];
  const missing = required.filter((name) => !string(hostEnvironment[name], 65536));
  requireCondition(missing.length === 0, `Deployment environment is missing: ${missing.join(", ")}`);
  requireCondition(hostEnvironment.ALLOW_INSECURE_OIDC !== "1", "ALLOW_INSECURE_OIDC must not be enabled for staging acceptance");

  const publicOrigin = secureURL(hostEnvironment.PUBLIC_ORIGIN, "PUBLIC_ORIGIN", { exactOrigin: true }).origin;
  const endpointURL = secureURL(hostEnvironment.FYRLET_ENDPOINT, "FYRLET_ENDPOINT");
  requireCondition(!endpointURL.search && endpointURL.pathname === "/", "FYRLET_ENDPOINT must be an origin with only an optional trailing slash");
  const endpoint = endpointURL.origin;
  let providers;
  try { providers = JSON.parse(hostEnvironment.OIDC_PROVIDERS); } catch { throw new StagingAcceptanceError("OIDC_PROVIDERS must be valid JSON"); }
  requireCondition(Array.isArray(providers) && providers.length >= 1 && providers.length <= 8, "OIDC_PROVIDERS must contain 1–8 providers");
  const providerMap = new Map();
  for (const provider of providers) {
    requireCondition(object(provider) && string(provider.name, 32) && /^[a-z][a-z0-9_-]{0,31}$/.test(provider.name) && !providerMap.has(provider.name) &&
      string(provider.clientId, 512) && string(provider.issuer, 2048), "OIDC_PROVIDERS contains an invalid provider");
    requireCondition(!secureURL(provider.issuer, `OIDC issuer for ${provider.name}`).search, `OIDC issuer for ${provider.name} must not contain a query`);
    providerMap.set(provider.name, { name: provider.name, label: string(provider.label, 100) ? provider.label : provider.name, issuer: provider.issuer });
  }

  let store;
  try { store = storeConfiguration(hostEnvironment); } catch { throw new StagingAcceptanceError("Host session store configuration is invalid"); }
  requireCondition(Array.isArray(config.hosts) && config.hosts.length === store.instances, "hosts must contain exactly HOST_INSTANCES direct host entries");
  const hosts = config.hosts.map((host, index) => {
    requireCondition(object(host) && deploymentName.test(host.id ?? ""), `hosts entry ${index + 1} has an invalid id`);
    return { id: host.id, origin: secureURL(host.origin, `Origin for host ${host.id}`, { exactOrigin: true }).origin };
  });
  requireCondition(new Set(hosts.map((host) => host.id)).size === hosts.length && new Set(hosts.map((host) => host.origin)).size === hosts.length,
    "Host ids and direct origins must be unique; load-balancer aliases are not proof of multiple hosts");
  if (store.instances > 1) requireCondition(store.postgres, "Multiple hosts require the shared PostgreSQL session store");

  const timeoutMs = config.timeoutMs ?? 30_000;
  requireCondition(Number.isSafeInteger(timeoutMs) && timeoutMs >= 1000 && timeoutMs <= 120_000, "timeoutMs must be between 1000 and 120000");
  const secrets = { ...hostEnvironment, ...environment };
  const applicationOrigins = [...new Set([publicOrigin, endpoint])];
  const accounts = {};
  accounts.primary = validateAccount(config.accounts?.primary, providerMap, secrets, "accounts.primary", applicationOrigins);
  if (config.accounts?.secondary !== undefined) accounts.secondary = validateAccount(config.accounts.secondary, providerMap, secrets, "accounts.secondary", applicationOrigins);
  for (const account of Object.values(accounts)) {
    if (account.method !== "storage-state") continue;
    const statePath = resolve(directory, account.storageStatePath);
    const state = await readJSON(statePath, "Playwright storage state");
    account.storageState = validateStorageState(state.value, publicOrigin);
    delete account.storageStatePath;
  }

  return {
    configurationBytes, deployment: validateDeployment(config.deployment), publicOrigin, endpoint,
    projectId: hostEnvironment.FYRLET_PROJECT_ID, environment: hostEnvironment, providers: providerMap,
    hosts, store, timeoutMs, revocation: validateRevocation(config.revocation), accounts,
  };
}

export function requireNetworkOptIn(mode, confirmation, deploymentID) {
  requireCondition(["preflight", "execute"].includes(mode), "Network mode must be preflight or execute");
  requireCondition(typeof confirmation === "string" && confirmation === deploymentID,
    "Real network actions require --confirm to exactly match deployment.id");
}

export function sessionFromPayload(payload, { projectId, now = Date.now(), revocation }) {
  requireCondition(object(payload) && typeof payload.token === "string" && payload.token.startsWith("rts_") && payload.project_id === projectId &&
    typeof payload.expires_at === "string" && Number.isFinite(Date.parse(payload.expires_at)), "Session issuance returned an invalid or wrong-project response");
  const remaining = Date.parse(payload.expires_at) - now;
  requireCondition(remaining >= 1000 && remaining <= (revocation.maxTokenSeconds + revocation.clockSkewSeconds) * 1000,
    "Issued session exceeded the configured bounded-expiry expectation");
  return { token: payload.token, expiresAt: payload.expires_at };
}

export function requireSessionValidityMargin(session, revocation, now = Date.now()) {
  const expiresAt = object(session) && typeof session.expiresAt === "string" ? Date.parse(session.expiresAt) : Number.NaN;
  requireCondition(typeof session?.token === "string" && session.token.startsWith("rts_") && Number.isFinite(expiresAt) &&
    expiresAt - now > revocation.clockSkewSeconds * 1000,
    "Session must remain unexpired beyond the configured clock skew throughout a revocation check");
}

export function requireCookieValidityMargin(cookie, revocation, now = Date.now()) {
  requireCondition(object(cookie) && Number.isFinite(cookie.expires) &&
    cookie.expires * 1000 - now > revocation.clockSkewSeconds * 1000,
    "Host cookie must remain unexpired beyond the configured clock skew throughout logout revocation checks");
}

/** A rejection is revocation evidence only while the full session is still temporally valid. */
export async function expectRevokedSession(session, query, { revocation, now = Date.now() }) {
  requireSessionValidityMargin(session, revocation, now());
  let rejected;
  try { await query(); } catch (error) { rejected = error; }
  requireSessionValidityMargin(session, revocation, now());
  requireCondition(rejected?.code === "UNAUTHENTICATED", "A revoked credential did not fail with UNAUTHENTICATED during a real SDK query");
}

export function sanitizedReason(error) {
  return error instanceof StagingAcceptanceError ? error.message : "Unexpected browser, SDK or transport failure (details suppressed)";
}

export function reportSummary(checks) {
  return {
    passed: checks.filter((check) => check.status === "passed").length,
    failed: checks.filter((check) => check.status === "failed").length,
    notRun: checks.filter((check) => check.status === "not-run").length,
  };
}

export function incompleteRequiredApplicationChecks(checks) {
  return requiredApplicationChecks.filter((name) => {
    const records = checks.filter((check) => check.name === name);
    return records.length !== 1 || records[0].status !== "passed";
  });
}

function finalStatus(report, mode) {
  report.summary = reportSummary(report.checks);
  const incomplete = mode === "execute" && incompleteRequiredApplicationChecks(report.checks).length > 0;
  report.status = report.summary.failed || incomplete ? "failed" : mode === "check" ? "not-run" : report.summary.passed ? "passed" : "not-run";
  report.complete = mode === "execute" && !incomplete && report.summary.failed === 0 && report.summary.notRun === 0;
  report.finishedAt = new Date().toISOString();
  if (mode !== "execute") report.acceptance = { status: "not-run", reason: mode === "preflight" ? "Preflight covers discovery, readiness and storage only; no login or application acceptance was performed." : "Configuration-only mode performs no network actions or acceptance scenarios." };
  else report.acceptance = { status: report.status, complete: report.complete, reason: report.summary.failed ?
    "One or more acceptance checks failed; other passed or not-run records do not establish acceptance." : incomplete ?
      "Every required application check must have exactly one passed record; missing, duplicate, failed or not-run records prevent acceptance." : report.summary.notRun ?
        "Passed checks apply only to the executed scope; not-run checks are explicit and are not passes." : "All recorded acceptance checks passed." };
  return report;
}

async function sourceMetadata(directory) {
  const [{ stdout }, fingerprint, { stdout: status }] = await Promise.all([
    executeFile("git", ["rev-parse", "HEAD"], { cwd: directory, maxBuffer: 1024 * 1024 }),
    acceptanceFingerprint(directory),
    executeFile("git", ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--"], { cwd: directory, maxBuffer: 16 * 1024 * 1024 }),
  ]);
  return { revision: stdout.trim(), clean: status.length === 0, fingerprint };
}

async function runtimeFiles(directory, prefix, hash) {
  const entries = await readdir(directory, { withFileTypes: true });
  entries.sort((left, right) => left.name.localeCompare(right.name));
  let count = 0;
  for (const entry of entries) {
    requireCondition(!entry.isSymbolicLink(), "SDK runtime files must not contain symbolic links");
    const path = resolve(directory, entry.name);
    const logical = `${prefix}/${entry.name}`;
    if (entry.isDirectory()) count += await runtimeFiles(path, logical, hash);
    else {
      requireCondition(entry.isFile(), "SDK runtime paths must be regular files");
      const bytes = await readFile(path);
      hash.update(`${logical}\0${bytes.byteLength}\0`);
      hash.update(bytes);
      count++;
    }
  }
  return count;
}

async function hashRuntimeFile(hash, root, logical) {
  const path = resolve(root, logical);
  const stat = await lstat(path);
  requireCondition(stat.isFile() && !stat.isSymbolicLink(), "SDK runtime dependencies must be regular, non-symlink files");
  const bytes = await readFile(path);
  hash.update(`${logical}\0${bytes.byteLength}\0`);
  hash.update(bytes);
  return bytes;
}

/** Hash the actual ESM runtime, installed Phoenix entry and lock/package integrity metadata. */
export async function sdkRuntimeFingerprint(directory = sdkRoot) {
  const hash = createHash("sha256");
  const packageBytes = await hashRuntimeFile(hash, directory, "package.json");
  const lockBytes = await hashRuntimeFile(hash, directory, "package-lock.json");
  let manifest;
  let lock;
  try { manifest = JSON.parse(packageBytes.toString("utf8")); lock = JSON.parse(lockBytes.toString("utf8")); }
  catch { throw new StagingAcceptanceError("SDK package metadata is invalid"); }
  const dependencies = Object.keys(manifest.dependencies ?? {}).sort();
  requireCondition(manifest.name === "@fyrlet/client" && dependencies.length === 1 && dependencies[0] === "phoenix",
    "SDK runtime dependency set changed; extend integrity binding before acceptance");
  const phoenixManifestBytes = await hashRuntimeFile(hash, directory, "node_modules/phoenix/package.json");
  let phoenix;
  try { phoenix = JSON.parse(phoenixManifestBytes.toString("utf8")); }
  catch { throw new StagingAcceptanceError("Phoenix package metadata is invalid"); }
  const locked = lock.packages?.["node_modules/phoenix"];
  requireCondition(phoenix.name === "phoenix" && phoenix.version === manifest.dependencies.phoenix && locked?.version === phoenix.version &&
    typeof locked.integrity === "string" && locked.integrity.startsWith("sha") && phoenix.exports?.import === "./priv/static/phoenix.mjs" &&
    Object.keys(phoenix.dependencies ?? {}).length === 0 && Object.keys(phoenix.optionalDependencies ?? {}).length === 0,
    "Installed Phoenix runtime does not match the locked, integrity-bound dependency");
  await hashRuntimeFile(hash, directory, "node_modules/phoenix/priv/static/phoenix.mjs");
  const distCount = await runtimeFiles(resolve(directory, "dist"), "dist", hash);
  requireCondition(distCount > 0, "SDK build produced an empty runtime dist");
  return {
    algorithm: "sha256", digest: hash.digest("hex"), fileCount: distCount + 4,
    scope: "Rebuilt TypeScript SDK dist, package lock/metadata and resolved Phoenix ESM runtime",
    dependencies: [{ name: "phoenix", version: phoenix.version, entry: "priv/static/phoenix.mjs" }],
  };
}

async function buildTypeScriptSDK(directory) {
  try {
    await executeFile("npm", ["--offline", "run", "build"], {
      cwd: directory, maxBuffer: 1024 * 1024,
      env: { ...process.env, npm_config_offline: "true", npm_config_audit: "false", npm_config_fund: "false", npm_config_update_notifier: "false" },
    });
  } catch { throw new StagingAcceptanceError("Offline TypeScript SDK rebuild failed (details suppressed)"); }
}

/** Bind only the real default browser execution; injected offline runners never invoke this build. */
export async function prepareSdkRuntime({ sdkDirectory = sdkRoot, applicationSDKPath = appSDKPath, build = buildTypeScriptSDK } = {}) {
  const [resolvedSDK, resolvedApplicationSDK] = await Promise.all([realpath(sdkDirectory), realpath(applicationSDKPath)]);
  requireCondition(resolvedSDK === resolvedApplicationSDK, "Inbox SDK resolution does not select the rebuilt TypeScript SDK");
  await rm(resolve(sdkDirectory, "dist"), { recursive: true, force: true });
  await build(sdkDirectory);
  return sdkRuntimeFingerprint(sdkDirectory);
}

export async function verifySdkRuntimeBinding(expected, { sdkDirectory = sdkRoot, applicationSDKPath = appSDKPath } = {}) {
  const [resolvedSDK, resolvedApplicationSDK] = await Promise.all([realpath(sdkDirectory), realpath(applicationSDKPath)]);
  requireCondition(resolvedSDK === resolvedApplicationSDK, "Inbox SDK resolution changed during staging acceptance");
  const current = await sdkRuntimeFingerprint(sdkDirectory);
  requireCondition(current.digest === expected.digest, "SDK runtime or Phoenix dependency changed during staging acceptance");
  return current;
}

async function appModules() {
  const { chromium, expect } = appRequire("@playwright/test");
  // The SDK intentionally exports only ESM. Resolve its installed file dependency
  // from the Inbox app rather than asking createRequire for an import-only export.
  const { createClient } = await import(new URL("../examples/inbox-react/node_modules/@fyrlet/client/dist/index.js", import.meta.url).href);
  return { chromium, expect, createClient };
}

function checkRecord(checks, name, status, reason, extra = {}) {
  const record = { name, status, reason, ...extra };
  checks.push(record);
  return record;
}

async function responseJSON(response, label) {
  requireCondition(response.status === 200, `${label} did not return HTTP 200`);
  try { return await response.json(); } catch { throw new StagingAcceptanceError(`${label} returned invalid JSON`); }
}

export function comparableProviderMetadata(providers) {
  return providers.map((provider) => ({ name: provider?.name, label: provider?.label }))
    .sort((left, right) => String(left.name).localeCompare(String(right.name)));
}

export function isSameOriginLogoutResponse(response, publicOrigin) {
  try {
    const url = new URL(response.url());
    return response.request().method() === "POST" && url.origin === publicOrigin && url.pathname === "/auth/logout" && !url.search && !url.hash;
  } catch { return false; }
}

export async function requireLogoutSuccess(response) {
  requireCondition(response.status === 200, "Application logout did not return HTTP 200");
  let body;
  try { body = await response.json(); } catch { throw new StagingAcceptanceError("Application logout returned invalid JSON"); }
  requireCondition(object(body) && body.signedOut === true && body.revoked === true,
    "Application logout did not confirm both signedOut and revoked");
}

function hostCookieHeader(cookie) {
  return cookie ? `${cookie.name}=${cookie.value}` : "";
}

/**
 * Browser/application acceptance. All URLs come from validated configuration; response bodies,
 * credentials, cookies, page errors and storage state are never added to check records.
 */
async function executeBrowserAcceptance(loaded, dependencies = {}) {
  const modules = dependencies.modules ?? await appModules();
  const { chromium, expect, createClient } = modules;
  const fetcher = dependencies.fetcher ?? fetch;
  const checks = [];
  let failed = false;
  let browser;
  let context;
  let page;
  let currentCookie;
  let cleanupCookie;
  let currentToken;
  let primaryIdentity;
  let primaryIssuer;
  let secondaryIssuer;
  let marker;
  let javascriptErrors = 0;
  const timeoutMs = loaded.timeoutMs;
  const applicationBrowserOrigins = new Set([loaded.publicOrigin, loaded.endpoint]);
  let activeBrowserOrigins = applicationBrowserOrigins;

  const record = (name, status, reason, extra) => {
    checkRecord(checks, name, status, reason, extra);
    return dependencies.onCheck?.(checks);
  };
  const skip = (name, reason, extra) => record(name, "not-run", reason, extra);
  const check = async (name, operation, extra) => {
    if (failed) { await skip(name, "Not run because an earlier required check failed"); return; }
    try { const reason = await operation(); await record(name, "passed", reason, extra); }
    catch (error) { failed = true; await record(name, "failed", sanitizedReason(error), extra); }
  };

  async function requestHost(host, path, { method = "GET", cookie, force = false } = {}) {
    requireCondition(method === "GET" || method === "POST", "Unsupported host request");
    const headers = {};
    if (cookie) headers.cookie = hostCookieHeader(cookie);
    if (method === "POST") headers.origin = loaded.publicOrigin;
    if (force) headers["x-fyrlet-refresh"] = "1";
    try {
      return await fetcher(`${host.origin}${path}`, { method, headers, redirect: "error", signal: AbortSignal.timeout(timeoutMs) });
    } catch { throw new StagingAcceptanceError("A staging host request failed (details suppressed)"); }
  }

  async function hostMe(host, cookie) {
    const body = await responseJSON(await requestHost(host, "/auth/me", { cookie }), "Host identity configuration");
    requireCondition(object(body) && Array.isArray(body.providers) && typeof body.projectId === "string" && typeof body.endpoint === "string",
      "Host identity configuration returned an invalid response");
    return body;
  }

  async function findHostCookie() {
    const cookies = await context.cookies(loaded.publicOrigin);
    const matching = cookies.filter((candidate) => candidate.name === "fyrlet_host");
    requireCondition(matching.length === 1, "Login must expose exactly one unambiguous host cookie for the public origin");
    const cookie = matching[0];
    requireCondition(cookie.httpOnly && cookie.sameSite === "Lax" && cookie.expires > 0, "Login did not create a bounded HttpOnly SameSite=Lax host cookie");
    if (loaded.publicOrigin.startsWith("https:")) requireCondition(cookie.secure, "HTTPS login did not create a Secure host cookie");
    const remaining = cookie.expires * 1000 - Date.now();
    requireCondition(remaining > 0 && remaining <= (loaded.revocation.maxHostSessionSeconds + loaded.revocation.clockSkewSeconds) * 1000,
      "Host cookie exceeded the configured external-IdP revocation bound");
    return cookie;
  }

  async function issueSession(host, cookie, force = false) {
    const response = await requestHost(host, "/api/fyrlet/session", { method: "POST", cookie, force });
    let payload;
    try { payload = await response.json(); } catch { throw new StagingAcceptanceError("Session issuance returned invalid JSON"); }
    requireCondition(response.status === 200, `Session issuance returned HTTP ${response.status}`);
    return sessionFromPayload(payload, { projectId: loaded.projectId, revocation: loaded.revocation });
  }

  async function sdkQuery(token) {
    let identity;
    let client;
    let subscription;
    try {
      client = createClient({
        endpoint: loaded.endpoint, projectId: loaded.projectId, timeoutMs, getToken: () => token,
        fetch: async (url, init) => {
          requireCondition(secureURL(url, "SDK request URL").origin === loaded.endpoint, "SDK request origin is not the configured API");
          const response = await fetcher(url, { ...init, redirect: "error" });
          if (response.ok && new URL(url).pathname === "/api/v1/identity") {
            const body = await response.clone().json();
            identity = body?.data;
          }
          return response;
        },
      });
      subscription = client.subscribe("inbox.recent", { limit: 50, include_archived: true });
      await expect.poll(() => subscription.getState().status, { timeout: timeoutMs }).toSatisfy((status) => ["ready", "error"].includes(status));
      const state = subscription.getState();
      if (state.status === "error") {
        const error = new StagingAcceptanceError("SDK query was rejected");
        error.code = state.error?.code;
        throw error;
      }
      requireCondition(object(identity) && identity.project_id === loaded.projectId && string(identity.subject_id, 512) && Array.isArray(state.data),
        "SDK query returned invalid identity or view data");
      return { identity, items: state.data };
    } catch (error) {
      if (error instanceof StagingAcceptanceError) throw error;
      throw new StagingAcceptanceError("SDK query failed (details suppressed)");
    } finally {
      subscription?.unsubscribe();
      client?.close();
    }
  }

  async function expectRevoked(session) {
    await expectRevokedSession(session, () => sdkQuery(session.token), { revocation: loaded.revocation });
  }

  async function runSteps(account) {
    for (const step of account.steps) {
      // Check immediately before every action, including every credential fill.
      requireAllowedBrowserOrigin(page.url(), activeBrowserOrigins);
      const locator = page.locator(step.selector);
      if (step.action === "fill") {
        requireAllowedBrowserOrigin(page.url(), activeBrowserOrigins);
        await locator.fill(step.value, { timeout: timeoutMs });
      } else if (step.action === "click") await locator.click({ timeout: timeoutMs });
      else if (step.action === "check") await locator.check({ timeout: timeoutMs });
      else if (step.action === "uncheck") await locator.uncheck({ timeout: timeoutMs });
      else if (step.action === "press") await locator.press(step.key, { timeout: timeoutMs });
      else await locator.waitFor({ state: "visible", timeout: timeoutMs });
    }
  }

  async function authenticate(account, { applyState = false } = {}) {
    activeBrowserOrigins = new Set(account.allowedBrowserOrigins);
    if (applyState && account.method === "storage-state") await context.addCookies(account.storageState.cookies);
    await page.goto(loaded.publicOrigin, { waitUntil: "domcontentloaded", timeout: timeoutMs });
    requireAllowedBrowserOrigin(page.url(), activeBrowserOrigins);
    if (account.method === "interactive") {
      requireCondition(new URL(page.url()).origin === loaded.publicOrigin, "Interactive login must start at PUBLIC_ORIGIN");
      const provider = loaded.providers.get(account.provider);
      await page.getByRole("link", { name: `使用 ${provider.label} 登录`, exact: true }).click({ timeout: timeoutMs });
      await runSteps(account);
    }
    await page.waitForURL((url) => url.origin === loaded.publicOrigin && url.pathname === "/", { timeout: timeoutMs });
    requireAllowedBrowserOrigin(page.url(), activeBrowserOrigins);
    await expect(page.getByRole("status")).toHaveText("实时同步中", { timeout: timeoutMs });
    await expect(page.getByRole("heading", { name: "随记", exact: true })).toBeVisible({ timeout: timeoutMs });
    const me = await hostMe({ origin: loaded.publicOrigin }, await findHostCookie());
    requireCondition(object(me.user) && me.user.issuer === loaded.providers.get(account.provider).issuer && string(me.user.revision, 512),
      "Authenticated issuer did not match the selected OIDC provider");
    currentCookie = await findHostCookie();
    cleanupCookie = currentCookie;
    activeBrowserOrigins = applicationBrowserOrigins;
    return { issuer: me.user.issuer, method: account.method };
  }

  async function signOutUI() {
    requireAllowedBrowserOrigin(page.url(), applicationBrowserOrigins);
    const responseWait = page.waitForResponse((response) => isSameOriginLogoutResponse(response, loaded.publicOrigin), { timeout: timeoutMs });
    const [logoutResponse] = await Promise.all([
      responseWait,
      page.getByRole("button", { name: "退出 / 切换账号", exact: true }).click({ timeout: timeoutMs }),
    ]);
    await requireLogoutSuccess(logoutResponse);
    await expect(page.getByRole("heading", { name: "打开你的随记。" })).toBeVisible({ timeout: timeoutMs });
    await expect(page.getByText(marker ?? "a-marker-that-cannot-exist", { exact: true })).toHaveCount(0, { timeout: timeoutMs });
  }

  try {
    await check("host-configuration", async () => {
      const expectedProviders = comparableProviderMetadata([...loaded.providers.values()]);
      const baseline = await hostMe(loaded.hosts[0]);
      requireCondition(baseline.endpoint.replace(/\/$/, "") === loaded.endpoint && baseline.projectId === loaded.projectId &&
        JSON.stringify(comparableProviderMetadata(baseline.providers)) === JSON.stringify(expectedProviders),
        "Direct host did not serve the expected API endpoint, project and configured provider metadata");
      for (const host of loaded.hosts) {
        const observed = await hostMe(host);
        requireCondition(observed.endpoint.replace(/\/$/, "") === loaded.endpoint && observed.projectId === loaded.projectId &&
          JSON.stringify(comparableProviderMetadata(observed.providers)) === JSON.stringify(expectedProviders),
          "Direct hosts disagree with the configured endpoint, project or provider metadata");
      }
      return `Verified non-authenticated identity and configured provider metadata on ${loaded.hosts.length} direct host(s); artifact digests remain operator-declared metadata.`;
    });

    await check("primary-authentication", async () => {
      browser = await chromium.launch({ headless: true, timeout: timeoutMs });
      context = await browser.newContext({
        viewport: { width: 1280, height: 900 }, serviceWorkers: "block",
        ...(loaded.accounts.primary.method === "storage-state" ? { storageState: loaded.accounts.primary.storageState } : {}),
      });
      context.setDefaultTimeout(timeoutMs);
      await context.route("**/*", async (route) => {
        try { requireAllowedBrowserOrigin(route.request().url(), activeBrowserOrigins); await route.continue(); }
        catch { await route.abort("blockedbyclient"); }
      });
      // Keep Phoenix on its native WebSocket transport while preventing other destinations.
      await context.addInitScript(({ endpoint }) => {
        const NativeWebSocket = globalThis.WebSocket;
        if (typeof NativeWebSocket !== "function") return;
        const expected = new URL(endpoint);
        expected.protocol = expected.protocol === "https:" ? "wss:" : "ws:";
        class StagingWebSocket extends NativeWebSocket {
          constructor(url, protocols) {
            const target = new URL(url);
            if (target.protocol !== expected.protocol || target.origin !== expected.origin || target.pathname !== "/socket/websocket" ||
                target.username || target.password || target.hash) throw new DOMException("WebSocket destination is not allowed", "SecurityError");
            if (protocols === undefined) super(url);
            else super(url, protocols);
          }
        }
        Object.defineProperty(globalThis, "WebSocket", { value: StagingWebSocket, configurable: true, writable: true });
      }, { endpoint: loaded.endpoint });
      page = await context.newPage();
      page.on("pageerror", () => { javascriptErrors++; });
      const authenticated = await authenticate(loaded.accounts.primary);
      primaryIssuer = authenticated.issuer;
      return loaded.accounts.primary.method === "interactive" ?
        "A real OIDC redirect/login flow authenticated the deployed application." :
        "A supplied storage state authenticated the deployed application; interactive IdP authorization was not exercised.";
    }, { method: loaded.accounts.primary.method });

    if (loaded.accounts.primary.method === "storage-state") await skip("interactive-idp-login", "Not run: primary authentication used supplied storage state, not a new interactive IdP login");
    else if (failed) await skip("interactive-idp-login", "Not run because primary authentication failed");
    else await record("interactive-idp-login", "passed", "The configured selectors completed a real same-tab IdP login and returned to the application");

    await check("bounded-session-expiry", async () => {
      currentCookie = await findHostCookie();
      currentToken = await issueSession(loaded.hosts[0], currentCookie);
      const query = await sdkQuery(currentToken.token);
      primaryIdentity = query.identity.subject_id;
      return "Observed host-cookie and short-session lifetimes within configured bounds; this is not continuous IdP introspection.";
    });

    await check("application-query-mutation-view-confirmation", async () => {
      marker = `Staging acceptance ${randomUUID()}`;
      await page.getByLabel("有什么需要记下来？").fill(marker);
      await page.getByRole("button", { name: "记下来", exact: true }).click();
      await expect(page.locator(".feedback")).toHaveText("已保存并同步", { timeout: timeoutMs });
      await expect(page.getByRole("listitem").filter({ hasText: marker })).toHaveCount(1, { timeout: timeoutMs });
      const independent = await context.newPage();
      try {
        independent.on("pageerror", () => { javascriptErrors++; });
        await independent.goto(loaded.publicOrigin, { waitUntil: "domcontentloaded", timeout: timeoutMs });
        await expect(independent.getByRole("status")).toHaveText("实时同步中", { timeout: timeoutMs });
        await expect(independent.getByText(marker, { exact: true })).toBeVisible({ timeout: timeoutMs });
      } finally { await independent.close(); }
      const query = await sdkQuery(currentToken.token);
      requireCondition(query.items.some((item) => item?.text === marker), "The SDK query did not return the confirmed acceptance mutation");
      return "A real Inbox mutation reached authoritative view confirmation and was returned by independent browser and SDK queries; the note remains in staging.";
    });

    await check("session-renewal", async () => {
      const previous = currentToken;
      const target = loaded.hosts.length > 1 ? loaded.hosts[1] : loaded.hosts[0];
      currentToken = await issueSession(target, currentCookie, true);
      requireCondition(previous.token !== currentToken.token, "Forced renewal returned the same credential");
      await expectRevoked(previous);
      const query = await sdkQuery(currentToken.token);
      requireCondition(query.identity.subject_id === primaryIdentity && query.items.some((item) => item?.text === marker),
        "Renewal changed identity or lost the confirmed application view");
      return loaded.hosts.length > 1 ?
        "Forced renewal on a second direct host revoked the old credential and preserved identity and the real query view." :
        "Forced renewal revoked the old credential and preserved identity and the real query view on one host.";
    }, { crossHost: loaded.hosts.length > 1 });

    if (loaded.hosts.length < 2) await skip("multi-host-shared-store", "Not run: configure at least two distinct direct hosts and shared PostgreSQL storage");
    else if (failed) await skip("multi-host-shared-store", "Not run because cross-host renewal did not complete");
    else await record("multi-host-shared-store", "passed", "One host cookie renewed through a second direct host, proving shared host state for this lifecycle path");

    await check("logout-and-revocation", async () => {
      const revokedToken = currentToken;
      const revokedCookie = currentCookie;
      requireCookieValidityMargin(revokedCookie, loaded.revocation);
      await signOutUI();
      currentCookie = undefined;
      currentToken = undefined;
      const oldHost = await requestHost(loaded.hosts.at(-1), "/api/fyrlet/session", { method: "POST", cookie: revokedCookie });
      requireCondition(oldHost.status === 401, "The old host cookie still issued a session after logout");
      requireCookieValidityMargin(revokedCookie, loaded.revocation);
      await expectRevoked(revokedToken);
      return "Application logout returned confirmed signedOut/revoked success, cleared private UI state, closed the unexpired old host session and revoked its unexpired API credential.";
    });

    if (!loaded.accounts.secondary) await skip("account-switch-and-issuer-subject-isolation", "Not run: accounts.secondary is not configured");
    else if (loaded.accounts.primary.method !== "interactive") await skip("account-switch-and-issuer-subject-isolation", "Not run: returning to the primary account after a switch requires a fresh interactive primary login");
    else await check("account-switch-and-issuer-subject-isolation", async () => {
      await context.clearCookies();
      await authenticate(loaded.accounts.secondary, { applyState: true });
      secondaryIssuer = (await hostMe({ origin: loaded.publicOrigin }, currentCookie)).user.issuer;
      await expect(page.getByText(marker, { exact: true })).toHaveCount(0, { timeout: timeoutMs });
      const secondaryToken = await issueSession(loaded.hosts[0], currentCookie);
      const secondaryQuery = await sdkQuery(secondaryToken.token);
      requireCondition(secondaryQuery.identity.subject_id !== primaryIdentity && !secondaryQuery.items.some((item) => item?.text === marker),
        "The secondary identity was not isolated from primary subject data");
      await signOutUI();
      await expectRevoked(secondaryToken);
      await context.clearCookies();
      const returned = await authenticate(loaded.accounts.primary);
      requireCondition(returned.issuer === primaryIssuer, "Primary issuer changed after account switching");
      currentToken = await issueSession(loaded.hosts[0], currentCookie);
      const returnedQuery = await sdkQuery(currentToken.token);
      requireCondition(returnedQuery.identity.subject_id === primaryIdentity && returnedQuery.items.some((item) => item?.text === marker),
        "The primary identity or private data was not restored after switching back");
      await expect(page.getByText(marker, { exact: true })).toBeVisible({ timeout: timeoutMs });
      return secondaryIssuer === primaryIssuer ?
        "Same-issuer account switching preserved a stable primary subject and isolated distinct subjects and their data." :
        "Cross-issuer account switching preserved a stable primary subject and isolated distinct issuer/subject identities and their data.";
    }, { sameIssuer: loaded.accounts.secondary ? loaded.providers.get(loaded.accounts.primary.provider).issuer === loaded.providers.get(loaded.accounts.secondary.provider).issuer : undefined });

    await skip("external-idp-revocation", "Not run: no generic IdP revocation API is attempted; consult bounded-session-expiry and logout-and-revocation for their independent results");

    await check("browser-runtime", async () => {
      requireCondition(javascriptErrors === 0, "The browser reported JavaScript errors (messages suppressed)");
      return "No browser page JavaScript errors were observed; messages were not retained.";
    });
  } finally {
    // Attempt every direct host even when one fails; never retain transport/response details.
    if (context) {
      let cookie;
      try { cookie = (await context.cookies(loaded.publicOrigin)).find((candidate) => candidate.name === "fyrlet_host") ?? cleanupCookie; }
      catch { cookie = cleanupCookie; }
      if (cookie) {
        let cleanupFailures = 0;
        for (const host of loaded.hosts) {
          try { await requireLogoutSuccess(await requestHost(host, "/auth/logout", { method: "POST", cookie })); }
          catch { cleanupFailures++; }
        }
        await record("cleanup-logout", cleanupFailures ? "failed" : "passed", cleanupFailures ?
          `Best-effort direct-host logout cleanup failed on ${cleanupFailures} host(s); transport and response details suppressed` :
          `Confirmed signedOut/revoked logout cleanup on all ${loaded.hosts.length} direct host(s)`);
      } else if (!checks.some((entry) => entry.name === "cleanup-logout")) {
        await record("cleanup-logout", "not-run", "No current host cookie was available for direct-host cleanup");
      }
    }
    await context?.close().catch(() => {});
    await browser?.close().catch(() => {});
  }
  return { checks, browserVersion: browser?.version() };
}

/** Run configuration, preflight or real acceptance. Only the latter two can reach the network. */
export async function runStagingAcceptance({
  configPath, mode = "check", confirmation, environment = process.env,
}, dependencies = {}) {
  requireCondition(["check", "preflight", "execute"].includes(mode), "Mode must be check, preflight or execute");
  const loaded = await loadStagingConfiguration(configPath, { environment });
  const metadata = dependencies.sourceMetadata ?? await sourceMetadata(root);
  const report = {
    kind: mode === "execute" ? "staging-acceptance" : mode === "preflight" ? "staging-preflight" : "staging-configuration",
    startedAt: new Date().toISOString(), status: "not-run", source: metadata,
    ...publicMetadata(loaded), checks: [],
    boundaries: [
      "Deployment release/artifact fields are exact operator declarations; this runner does not introspect an orchestrator.",
      "No credentials, cookies, tokens, subjects, usernames, response bodies, page errors, screenshots, traces or storage state are recorded.",
      "External IdP revocation is bounded by host/session expiry; no continuous IdP introspection is claimed.",
    ],
  };
  const update = async () => { await dependencies.onUpdate?.(report); };
  await update();

  if (metadata.revision !== loaded.deployment.sourceRevision) {
    checkRecord(report.checks, "source-and-configuration", "failed", "Current Git revision does not match deployment.sourceRevision; network actions were not attempted");
    return finalStatus(report, mode);
  }
  if (mode !== "check" && metadata.clean !== true) {
    checkRecord(report.checks, "source-and-configuration", "failed", "Real staging modes require a clean tracked and non-ignored source checkout; configuration-only mode remains available for dirty checkouts");
    await update();
    return finalStatus(report, mode);
  }
  checkRecord(report.checks, "source-and-configuration", "passed", mode === "check" ?
    "Configuration, credentials, HTTPS URLs, immutable metadata and shared-store shape validated without requiring a clean checkout" :
    "Configuration, credentials, HTTPS URLs, immutable metadata, clean source checkout and shared-store shape validated before network access");
  await update();
  if (mode === "check") return finalStatus(report, mode);
  requireNetworkOptIn(mode, confirmation, loaded.deployment.id);

  let preflight;
  try {
    const checker = dependencies.preflightChecker ?? checkDeployment;
    preflight = await checker(loaded.environment, dependencies.fetcher ?? fetch);
  } catch {
    checkRecord(report.checks, "deployment-preflight", "failed", "Deployment preflight failed (transport and configuration details suppressed)");
    await update();
    return finalStatus(report, mode);
  }
  checkRecord(report.checks, "deployment-preflight", preflight?.verified ? "passed" : "failed",
    preflight?.verified ? "OIDC discovery, session storage/schema and API readiness passed; this is not login acceptance" : "Deployment preflight reported an unverified configuration or dependency",
    { checks: Array.isArray(preflight?.checks) ? preflight.checks.map((check) => ({ name: String(check.name), status: String(check.status), ...(Array.isArray(check.variables) ? { variables: check.variables.map(String) } : {}) })) : [] });
  await update();
  if (!preflight?.verified || mode === "preflight") return finalStatus(report, mode);

  let sdkRuntime;
  if (!dependencies.browserRunner) {
    try {
      sdkRuntime = await (dependencies.sdkRuntimePreparer ?? prepareSdkRuntime)();
      const dependency = sdkRuntime?.dependencies?.[0];
      requireCondition(object(sdkRuntime) && sdkRuntime.algorithm === "sha256" && /^[a-f0-9]{64}$/.test(sdkRuntime.digest) &&
        Number.isSafeInteger(sdkRuntime.fileCount) && sdkRuntime.fileCount > 0 && sdkRuntime.dependencies?.length === 1 &&
        dependency?.name === "phoenix" && /^[A-Za-z0-9._-]{1,100}$/.test(dependency.version) && dependency.entry === "priv/static/phoenix.mjs",
        "SDK runtime binding returned invalid public metadata");
      report.sdkRuntime = {
        algorithm: "sha256", digest: sdkRuntime.digest, fileCount: sdkRuntime.fileCount,
        scope: "Clean offline TypeScript SDK rebuild, dist, package locks and resolved Phoenix ESM runtime",
        dependencies: [{ name: "phoenix", version: dependency.version, entry: dependency.entry }],
      };
      checkRecord(report.checks, "sdk-runtime-binding", "passed", "Cleanly rebuilt the TypeScript SDK offline and bound the exact SDK/Phoenix runtime digest before browser loading");
    } catch (error) {
      checkRecord(report.checks, "sdk-runtime-binding", "failed", sanitizedReason(error));
      await update();
      return finalStatus(report, mode);
    }
    await update();
  }

  const browserStart = report.checks.length;
  try {
    const runner = dependencies.browserRunner ?? executeBrowserAcceptance;
    const result = await runner(loaded, {
      ...dependencies,
      onCheck: async (current) => {
        report.checks.length = browserStart;
        report.checks.push(...current);
        await update();
      },
    });
    if (!Array.isArray(result?.checks) || result.checks.some((check) => !string(check.name, 200) || !["passed", "failed", "not-run"].includes(check.status) || !string(check.reason, 1000))) {
      throw new StagingAcceptanceError("Browser acceptance returned an invalid result");
    }
    report.checks.length = browserStart;
    report.checks.push(...result.checks);
    if (string(result.browserVersion, 100)) report.browser = { engine: "chromium", version: result.browserVersion };
  } catch (error) {
    checkRecord(report.checks, "browser-acceptance", "failed", sanitizedReason(error));
  }
  for (const name of requiredApplicationChecks) {
    if (!report.checks.some((check) => check.name === name)) checkRecord(report.checks, name, "failed", "Required acceptance check was not reported; completeness cannot be inferred");
  }
  const incomplete = incompleteRequiredApplicationChecks(report.checks);
  checkRecord(report.checks, "application-completeness", incomplete.length ? "failed" : "passed", incomplete.length ?
    `Required application checks must each have exactly one passed record: ${incomplete.join(", ")}` :
    "Every required application check has exactly one passed record; optional not-run scenarios remain separate");
  await update();

  try {
    const fingerprint = dependencies.finalFingerprint ? await dependencies.finalFingerprint() : (await acceptanceFingerprint(root));
    const digest = typeof fingerprint === "string" ? fingerprint : fingerprint.digest;
    requireCondition(digest === metadata.fingerprint.digest, "Sources changed during staging acceptance; rerun with frozen sources");
    checkRecord(report.checks, "source-stability", "passed", "Source fingerprint remained unchanged throughout execution");
  } catch (error) {
    checkRecord(report.checks, "source-stability", "failed", sanitizedReason(error));
  }
  if (sdkRuntime) {
    try {
      await (dependencies.sdkRuntimeVerifier ?? verifySdkRuntimeBinding)(sdkRuntime);
      checkRecord(report.checks, "sdk-runtime-stability", "passed", "SDK and Phoenix runtime digest and resolution remained unchanged throughout execution");
    } catch (error) {
      checkRecord(report.checks, "sdk-runtime-stability", "failed", sanitizedReason(error));
    }
  }
  await update();
  return finalStatus(report, mode);
}

async function requirePrivateOutputDirectory(output) {
  await mkdir(output, { recursive: true, mode: 0o700 });
  const stat = await lstat(output);
  requireCondition(stat.isDirectory() && !stat.isSymbolicLink(), "Report output must be a real directory, not a symbolic link");
  if (process.platform !== "win32") {
    requireCondition((stat.mode & 0o077) === 0, "Report output directory must not be accessible by group or other users");
    if (typeof process.getuid === "function") requireCondition(stat.uid === process.getuid(), "Report output directory must be owned by the current user");
  }
}

/** Persist only sanitized reports using a private directory and random exclusive temporary file. */
export async function persistReport(output, report) {
  await requirePrivateOutputDirectory(output);
  const serialized = JSON.stringify(report, null, 2) + "\n";
  const temporary = resolve(output, `.result-${process.pid}-${randomUUID()}.tmp`);
  await writeFile(temporary, serialized, { mode: 0o600, flag: "wx" });
  if (process.platform !== "win32") await chmod(temporary, 0o600);
  await rename(temporary, resolve(output, "result.json"));
}

async function main() {
  const { values } = parseArgs({ options: {
    config: { type: "string" }, out: { type: "string" }, confirm: { type: "string" },
    preflight: { type: "boolean" }, execute: { type: "boolean" }, help: { type: "boolean" },
  } });
  if (values.help) {
    console.log("node scripts/staging_acceptance.mjs --config FILE [--out DIRECTORY]\n" +
      "node scripts/staging_acceptance.mjs --config FILE --preflight --confirm DEPLOYMENT_ID [--out DIRECTORY]\n" +
      "node scripts/staging_acceptance.mjs --config FILE --execute --confirm DEPLOYMENT_ID [--out DIRECTORY]\n" +
      "Default mode is configuration-only and performs no network I/O. Reports contain no secrets.");
    return;
  }
  if (!values.config || (values.preflight && values.execute)) throw new StagingAcceptanceError("Provide --config and at most one of --preflight or --execute");
  const mode = values.execute ? "execute" : values.preflight ? "preflight" : "check";
  const output = resolve(values.out ?? resolve(root, ".local/staging-acceptance", `${mode}-${Date.now()}-${randomUUID()}`));
  await mkdir(output, { recursive: true, mode: 0o700 });
  let report = { kind: `staging-${mode}`, status: "not-run", checks: [], reason: "Runner initialization did not complete" };
  try {
    report = await runStagingAcceptance({ configPath: values.config, mode, confirmation: values.confirm }, {
      onUpdate: async (current) => { report = current; await persistReport(output, current); },
    });
    await persistReport(output, report);
    console.log(`Staging report: ${resolve(output, "result.json")}`);
    if (report.status === "failed" || (mode !== "check" && report.status !== "passed")) process.exitCode = 1;
  } catch (error) {
    const reason = sanitizedReason(error);
    const failure = { ...report, status: "failed", finishedAt: new Date().toISOString(), failure: reason };
    await persistReport(output, failure);
    console.error(reason);
    console.error(`Staging report: ${resolve(output, "result.json")}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await main(); } catch { console.error("Staging acceptance could not start (details suppressed)"); process.exitCode = 1; }
}
