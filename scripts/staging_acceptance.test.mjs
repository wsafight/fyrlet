import test from "node:test";
import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readdir, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  comparableProviderMetadata, expectRevokedSession, incompleteRequiredApplicationChecks, isSameOriginLogoutResponse,
  loadStagingConfiguration, persistReport, prepareSdkRuntime, publicMetadata, reportSummary, requireAllowedBrowserOrigin,
  requireAllowedWebSocketDestination, requireCookieValidityMargin, requireLogoutSuccess, requireNetworkOptIn,
  runStagingAcceptance, sdkRuntimeFingerprint, secureURL, sessionFromPayload, StagingAcceptanceError, verifySdkRuntimeBinding,
} from "./staging_acceptance.mjs";

const revision = "a".repeat(40);
const digest = `sha256:${"b".repeat(64)}`;
const secretValues = ["private-service-key", "private-client-secret", "private-password", "private-host-cookie"];

function baseConfiguration() {
  return {
    schemaVersion: 1,
    environmentFile: "./staging.env",
    deployment: {
      id: "inbox-staging", sourceRevision: revision,
      hostArtifactDigest: digest, apiArtifactDigest: digest,
      hostRelease: "host-2026.11.08", apiRelease: "api-2026.11.08",
    },
    timeoutMs: 5000,
    hosts: [{ id: "staging-1", origin: "https://app.example" }],
    revocation: { strategy: "bounded-host-expiry", maxHostSessionSeconds: 3600, maxTokenSeconds: 600, clockSkewSeconds: 5 },
    accounts: {
      primary: {
        provider: "first",
        allowedBrowserOrigins: ["https://app.example", "https://api.example", "https://first-id.example"],
        steps: [
          { action: "fill", selector: "input[name=login]", valueFromEnv: "STAGING_PRIMARY_USERNAME" },
          { action: "fill", selector: "input[name=password]", valueFromEnv: "STAGING_PRIMARY_PASSWORD" },
          { action: "click", selector: "button[type=submit]" },
        ],
      },
    },
  };
}

function baseEnvironment() {
  return {
    PUBLIC_ORIGIN: "https://app.example",
    FYRLET_ENDPOINT: "https://api.example",
    FYRLET_PROJECT_ID: "staging-project",
    FYRLET_SERVICE_KEY: "private-service-key",
    OIDC_PROVIDERS: JSON.stringify([
      { name: "first", label: "First IdP", issuer: "https://first-id.example", clientId: "staging-client", clientSecret: "private-client-secret" },
      { name: "second", label: "Second IdP", issuer: "https://second-id.example", clientId: "staging-client" },
    ]),
    ALLOW_INSECURE_OIDC: "0",
    HOST_INSTANCES: "1",
    STAGING_PRIMARY_USERNAME: "staging-user",
    STAGING_PRIMARY_PASSWORD: "private-password",
  };
}

async function fixture(context, mutate = () => {}) {
  const directory = await mkdtemp(join(tmpdir(), "fyrlet-staging-test-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const config = baseConfiguration();
  const environment = baseEnvironment();
  mutate(config, environment);
  const configPath = join(directory, "acceptance.json");
  await writeFile(configPath, JSON.stringify(config), { mode: 0o644 });
  await writeFile(join(directory, "staging.env"), Object.entries(environment).map(([name, value]) => `${name}=${value}`).join("\n"), { mode: 0o600 });
  return { directory, configPath, config, environment };
}

function source(overrides = {}) {
  return { revision, clean: true, fingerprint: { algorithm: "sha256", digest: "offline-source-digest", fileCount: 1, scope: "offline-test" }, ...overrides };
}

function hostCookie(overrides = {}) {
  return {
    name: "fyrlet_host", value: "private-host-cookie", domain: "app.example", path: "/",
    httpOnly: true, secure: true, sameSite: "Lax", expires: 2_000_000_000, ...overrides,
  };
}

const passingPreflight = { verified: true, checks: [{ name: "oidc-discovery-and-session-store", status: "passed" }] };
const passingBrowserChecks = () => [
  "host-configuration", "primary-authentication", "bounded-session-expiry",
  "application-query-mutation-view-confirmation", "session-renewal", "logout-and-revocation", "browser-runtime",
].map((name) => ({ name, status: "passed", reason: "offline fixture" }));

test("HTTPS is mandatory except for explicit loopback HTTP", () => {
  assert.equal(secureURL("https://app.example", "origin", { exactOrigin: true }).origin, "https://app.example");
  assert.equal(secureURL("http://127.0.0.1:8080", "origin", { exactOrigin: true }).origin, "http://127.0.0.1:8080");
  for (const value of ["http://app.example", "https://user:password@app.example", "https://app.example/path", "https://app.example/?next=private"]) {
    assert.throws(() => secureURL(value, "origin", { exactOrigin: true }), StagingAcceptanceError);
  }
});

test("configuration validates locally and public metadata excludes every credential", async (context) => {
  const { configPath } = await fixture(context);
  const loaded = await loadStagingConfiguration(configPath, { environment: {} });
  assert.equal(loaded.accounts.primary.steps[1].value, "private-password");
  assert.equal(loaded.hosts.length, 1);
  const metadata = JSON.stringify(publicMetadata(loaded));
  assert.match(metadata, /inbox-staging/);
  assert.match(metadata, /sha256:/);
  for (const secret of secretValues) assert.ok(!metadata.includes(secret), `metadata exposed ${secret}`);
  assert.ok(!metadata.includes("staging-user"));
});

test("missing deployment configuration fails closed and names only variables", async (context) => {
  const { configPath } = await fixture(context, (_config, environment) => {
    delete environment.FYRLET_SERVICE_KEY;
    delete environment.OIDC_PROVIDERS;
  });
  await assert.rejects(loadStagingConfiguration(configPath, { environment: {} }), (error) => {
    assert.match(error.message, /FYRLET_SERVICE_KEY, OIDC_PROVIDERS/);
    for (const secret of secretValues) assert.ok(!error.message.includes(secret));
    return true;
  });
});

test("login values cannot be embedded in configuration and missing secret references fail", async (context) => {
  const literal = await fixture(context, (config) => { config.accounts.primary.steps[0] = { action: "fill", selector: "#login", value: "literal-secret" }; });
  await assert.rejects(loadStagingConfiguration(literal.configPath, { environment: {} }), /valueFromEnv/);
  const missing = await fixture(context, (_config, environment) => { delete environment.STAGING_PRIMARY_PASSWORD; });
  await assert.rejects(loadStagingConfiguration(missing.configPath, { environment: {} }), /STAGING_PRIMARY_PASSWORD/);
});

test("storage state is private, cookie-only, secure and never copied into public metadata", async (context) => {
  const fixtureValue = await fixture(context, (config, environment) => {
    config.accounts.primary = {
      provider: "first", storageStateFromEnv: "STAGING_PRIMARY_STATE",
      allowedBrowserOrigins: ["https://app.example", "https://api.example"],
    };
    environment.STAGING_PRIMARY_STATE = "./state.json";
  });
  const state = { cookies: [hostCookie()], origins: [] };
  await writeFile(join(fixtureValue.directory, "state.json"), JSON.stringify(state), { mode: 0o600 });
  const loaded = await loadStagingConfiguration(fixtureValue.configPath, { environment: {} });
  assert.equal(loaded.accounts.primary.method, "storage-state");
  assert.ok(!JSON.stringify(publicMetadata(loaded)).includes("private-host-cookie"));
  await writeFile(join(fixtureValue.directory, "state.json"), JSON.stringify({ ...state, cookies: [hostCookie({ secure: false })] }), { mode: 0o600 });
  await assert.rejects(loadStagingConfiguration(fixtureValue.configPath, { environment: {} }), /Secure/);
});

test("storage state permissions and local-storage payloads are rejected", async (context) => {
  const { configPath, directory } = await fixture(context, (config, environment) => {
    config.accounts.primary = {
      provider: "first", storageStateFromEnv: "STAGING_PRIMARY_STATE",
      allowedBrowserOrigins: ["https://app.example", "https://api.example"],
    };
    environment.STAGING_PRIMARY_STATE = "./state.json";
  });
  const path = join(directory, "state.json");
  await writeFile(path, JSON.stringify({ cookies: [], origins: [{ origin: "https://app.example", localStorage: [{ name: "token", value: "private" }] }] }), { mode: 0o600 });
  await assert.rejects(loadStagingConfiguration(configPath, { environment: {} }), /cookies only/);
  await writeFile(path, JSON.stringify({ cookies: [], origins: [] }), { mode: 0o600 });
  await chmod(path, 0o644);
  if (process.platform !== "win32") await assert.rejects(loadStagingConfiguration(configPath, { environment: {} }), /group or other/);
});

test("multiple hosts require shared PostgreSQL and exact direct-host metadata", async (context) => {
  const missingStore = await fixture(context, (config, environment) => {
    environment.HOST_INSTANCES = "2";
    config.hosts = [{ id: "staging-1", origin: "https://one.example" }, { id: "staging-2", origin: "https://two.example" }];
  });
  await assert.rejects(loadStagingConfiguration(missingStore.configPath, { environment: {} }), /session store configuration/i);

  const mismatched = await fixture(context, (config, environment) => {
    environment.HOST_INSTANCES = "2";
    environment.HOST_STORE_DATABASE_URL = "postgresql://db.example/staging";
    environment.HOST_STORE_KEY = "A".repeat(43);
  });
  await assert.rejects(loadStagingConfiguration(mismatched.configPath, { environment: {} }), /exactly HOST_INSTANCES/);

  const aliases = await fixture(context, (config, environment) => {
    environment.HOST_INSTANCES = "2";
    environment.HOST_STORE_DATABASE_URL = "postgresql://db.example/staging";
    environment.HOST_STORE_KEY = "A".repeat(43);
    config.hosts = [{ id: "staging-1", origin: "https://same.example" }, { id: "staging-2", origin: "https://same.example" }];
  });
  await assert.rejects(loadStagingConfiguration(aliases.configPath, { environment: {} }), /not proof of multiple hosts/);
});

test("revocation expectations reject unbounded or over-long sessions", async (context) => {
  for (const revocation of [
    { strategy: "continuous-introspection", maxHostSessionSeconds: 3600, maxTokenSeconds: 600 },
    { strategy: "bounded-host-expiry", maxHostSessionSeconds: 7200, maxTokenSeconds: 600 },
    { strategy: "bounded-host-expiry", maxHostSessionSeconds: 3600, maxTokenSeconds: 900 },
  ]) {
    const { configPath } = await fixture(context, (config) => { config.revocation = revocation; });
    await assert.rejects(loadStagingConfiguration(configPath, { environment: {} }), StagingAcceptanceError);
  }
});

test("session parsing enforces project, shape and the configured short TTL without echoing tokens", () => {
  const now = Date.parse("2026-11-08T00:00:00Z");
  const revocation = { maxTokenSeconds: 600, clockSkewSeconds: 5 };
  const valid = { token: "rts_private-session-token", project_id: "project", expires_at: new Date(now + 60_000).toISOString() };
  assert.equal(sessionFromPayload(valid, { projectId: "project", now, revocation }).token, valid.token);
  for (const payload of [
    { ...valid, project_id: "other" },
    { ...valid, expires_at: new Date(now + 900_000).toISOString() },
    { ...valid, expires_at: new Date(now - 1000).toISOString() },
    { ...valid, token: "not-a-session" },
  ]) {
    assert.throws(() => sessionFromPayload(payload, { projectId: "project", now, revocation }), (error) => {
      assert.ok(!error.message.includes(valid.token));
      return true;
    });
  }
});

test("placeholder revisions, artifact digests and mutable release names fail closed", async (context) => {
  for (const mutate of [
    (config) => { config.deployment.sourceRevision = "0".repeat(40); },
    (config) => { config.deployment.hostArtifactDigest = `sha256:${"0".repeat(64)}`; },
    (config) => { config.deployment.hostRelease = "latest"; },
    (config) => { config.deployment.apiRelease = "replace-with-api-release"; },
  ]) {
    const { configPath } = await fixture(context, mutate);
    await assert.rejects(loadStagingConfiguration(configPath, { environment: {} }), /non-placeholder|immutable/);
  }
});

test("network opt-in requires an exact deployment confirmation", () => {
  assert.doesNotThrow(() => requireNetworkOptIn("execute", "inbox-staging", "inbox-staging"));
  for (const confirmation of [undefined, "", "production", "INBOX-STAGING"]) {
    assert.throws(() => requireNetworkOptIn("preflight", confirmation, "inbox-staging"), /--confirm/);
  }
});

test("default configuration mode performs no preflight, browser or final network work", async (context) => {
  const { configPath } = await fixture(context);
  let calls = 0;
  const report = await runStagingAcceptance({ configPath, environment: {} }, {
    sourceMetadata: source({ clean: false }),
    preflightChecker: async () => { calls++; throw new Error("network forbidden"); },
    browserRunner: async () => { calls++; throw new Error("network forbidden"); },
  });
  assert.equal(calls, 0);
  assert.equal(report.kind, "staging-configuration");
  assert.equal(report.status, "not-run");
  assert.equal(report.acceptance.status, "not-run");
  assert.equal(report.checks[0].status, "passed");
});

test("preflight and execution reject missing/wrong confirmation before any network action", async (context) => {
  for (const mode of ["preflight", "execute"]) {
    const { configPath } = await fixture(context);
    let calls = 0;
    await assert.rejects(runStagingAcceptance({ configPath, mode, confirmation: "wrong", environment: {} }, {
      sourceMetadata: source(), preflightChecker: async () => { calls++; }, browserRunner: async () => { calls++; },
    }), /--confirm/);
    assert.equal(calls, 0);
  }
});

test("successful preflight explicitly leaves full acceptance not run", async (context) => {
  const { configPath } = await fixture(context);
  let browserCalls = 0;
  const report = await runStagingAcceptance({ configPath, mode: "preflight", confirmation: "inbox-staging", environment: {} }, {
    sourceMetadata: source(), preflightChecker: async () => passingPreflight,
    browserRunner: async () => { browserCalls++; },
  });
  assert.equal(report.status, "passed");
  assert.equal(report.kind, "staging-preflight");
  assert.equal(report.acceptance.status, "not-run");
  assert.match(report.acceptance.reason, /no login/i);
  assert.equal(browserCalls, 0);
});

test("failed preflight stops browser execution and suppresses sensitive transport errors", async (context) => {
  const { configPath } = await fixture(context);
  let browserCalls = 0;
  const report = await runStagingAcceptance({ configPath, mode: "execute", confirmation: "inbox-staging", environment: {} }, {
    sourceMetadata: source(), preflightChecker: async () => { throw new Error("private-service-key private-client-secret"); },
    browserRunner: async () => { browserCalls++; },
  });
  assert.equal(report.status, "failed");
  assert.equal(report.acceptance.status, "failed");
  assert.match(report.acceptance.reason, /do not establish acceptance/);
  assert.equal(browserCalls, 0);
  assert.equal(report.checks.at(-1).name, "deployment-preflight");
  for (const secret of secretValues) assert.ok(!JSON.stringify(report).includes(secret));
});

test("a source revision mismatch blocks all real network actions", async (context) => {
  const { configPath } = await fixture(context);
  let calls = 0;
  const report = await runStagingAcceptance({ configPath, mode: "execute", confirmation: "inbox-staging", environment: {} }, {
    sourceMetadata: source({ revision: "c".repeat(40) }),
    preflightChecker: async () => { calls++; }, browserRunner: async () => { calls++; },
  });
  assert.equal(report.status, "failed");
  assert.equal(calls, 0);
  assert.match(report.checks[0].reason, /does not match/);
});

test("executed passes coexist with explicit not-run scenarios without claiming complete coverage", async (context) => {
  const { configPath } = await fixture(context);
  const report = await runStagingAcceptance({ configPath, mode: "execute", confirmation: "inbox-staging", environment: {} }, {
    sourceMetadata: source(), finalFingerprint: async () => "offline-source-digest", preflightChecker: async () => passingPreflight,
    browserRunner: async () => ({ browserVersion: "offline-test", checks: [
      ...passingBrowserChecks(),
      { name: "multi-host-shared-store", status: "not-run", reason: "one host configured" },
      { name: "external-idp-revocation", status: "not-run", reason: "no generic IdP revocation API" },
    ] }),
  });
  assert.equal(report.status, "passed");
  assert.equal(report.complete, false);
  assert.equal(report.summary.notRun, 2);
  assert.equal(report.checks.find((check) => check.name === "multi-host-shared-store").status, "not-run");
  assert.match(report.acceptance.reason, /not a pass|not passes|not-run/i);
});

test("missing required browser records cannot be inferred as a successful acceptance", async (context) => {
  const { configPath } = await fixture(context);
  const report = await runStagingAcceptance({ configPath, mode: "execute", confirmation: "inbox-staging", environment: {} }, {
    sourceMetadata: source(), finalFingerprint: async () => "offline-source-digest", preflightChecker: async () => passingPreflight,
    browserRunner: async () => ({ checks: [{ name: "primary-authentication", status: "passed", reason: "incomplete fixture" }] }),
  });
  assert.equal(report.status, "failed");
  assert.ok(report.checks.some((check) => check.name === "logout-and-revocation" && check.status === "failed"));
});

test("unexpected browser failures are failed, never fake passes, and are redacted", async (context) => {
  const { configPath } = await fixture(context);
  const report = await runStagingAcceptance({ configPath, mode: "execute", confirmation: "inbox-staging", environment: {} }, {
    sourceMetadata: source(), finalFingerprint: async () => "offline-source-digest", preflightChecker: async () => passingPreflight,
    browserRunner: async () => { throw new Error("private-host-cookie and private-password"); },
  });
  assert.equal(report.status, "failed");
  assert.equal(report.checks.find((check) => check.name === "browser-acceptance").status, "failed");
  for (const secret of secretValues) assert.ok(!JSON.stringify(report).includes(secret));
});

test("source changes during execution invalidate acceptance", async (context) => {
  const { configPath } = await fixture(context);
  const report = await runStagingAcceptance({ configPath, mode: "execute", confirmation: "inbox-staging", environment: {} }, {
    sourceMetadata: source(), finalFingerprint: async () => "changed-source-digest", preflightChecker: async () => passingPreflight,
    browserRunner: async () => ({ checks: passingBrowserChecks() }),
  });
  assert.equal(report.status, "failed");
  assert.equal(report.checks.at(-1).name, "source-stability");
  assert.match(report.checks.at(-1).reason, /frozen sources/);
});

test("summary counts only explicit passed/failed/not-run records", () => {
  assert.deepEqual(reportSummary([{ status: "passed" }, { status: "failed" }, { status: "not-run" }]), { passed: 1, failed: 1, notRun: 1 });
});

test("reports are persisted with private permissions", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "fyrlet-staging-report-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const report = { status: "not-run", checks: [], acceptance: { status: "not-run", reason: "offline test" } };
  await persistReport(directory, report);
  const result = join(directory, "result.json");
  assert.deepEqual(JSON.parse(await readFile(result, "utf8")), report);
  if (process.platform !== "win32") assert.equal((await stat(result)).mode & 0o777, 0o600);
  assert.deepEqual(await readdir(directory), ["result.json"]);
});

test("browser origin and native WebSocket destination checks fail closed", () => {
  const allowed = ["https://app.example", "https://api.example", "https://id.example"];
  assert.equal(requireAllowedBrowserOrigin("https://id.example/login?next=private", allowed), "https://id.example");
  for (const url of ["https://evil.example", "https://app.example.evil.example", "http://id.example", "https://user:password@id.example"]) {
    assert.throws(() => requireAllowedBrowserOrigin(url, allowed), StagingAcceptanceError);
  }
  const socket = requireAllowedWebSocketDestination("wss://api.example/socket/websocket?token=private", "https://api.example");
  assert.equal(socket.pathname, "/socket/websocket");
  for (const url of ["wss://evil.example/socket/websocket", "wss://api.example/other", "ws://api.example/socket/websocket", "wss://user:password@api.example/socket/websocket"]) {
    assert.throws(() => requireAllowedWebSocketDestination(url, "https://api.example"), (error) => {
      assert.ok(!error.message.includes("password"));
      return true;
    });
  }
});

test("each account requires unique exact application, API and explicit IdP browser origins", async (context) => {
  for (const mutate of [
    (config) => { delete config.accounts.primary.allowedBrowserOrigins; },
    (config) => { config.accounts.primary.allowedBrowserOrigins = ["https://app.example", "https://first-id.example"]; },
    (config) => { config.accounts.primary.allowedBrowserOrigins.push("http://redirect.example"); },
    (config) => { config.accounts.primary.allowedBrowserOrigins.push("https://api.example"); },
  ]) {
    const { configPath } = await fixture(context, mutate);
    await assert.rejects(loadStagingConfiguration(configPath, { environment: {} }), /allowedBrowserOrigins|HTTPS/);
  }
});

test("storage state accepts only one host-only secure application host cookie", async (context) => {
  const fixtureValue = await fixture(context, (config, environment) => {
    config.accounts.primary = {
      provider: "first", storageStateFromEnv: "STAGING_PRIMARY_STATE",
      allowedBrowserOrigins: ["https://app.example", "https://api.example"],
    };
    environment.STAGING_PRIMARY_STATE = "./state.json";
  });
  const path = join(fixtureValue.directory, "state.json");
  const writeState = (cookies) => writeFile(path, JSON.stringify({ cookies, origins: [] }), { mode: 0o600 });
  for (const cookies of [
    [hostCookie(), hostCookie({ name: "unrelated" })],
    [hostCookie({ domain: ".app.example" })],
    [hostCookie({ domain: "other.example" })],
    [hostCookie({ path: "/auth" })],
    [hostCookie({ httpOnly: false })],
    [hostCookie({ sameSite: "None" })],
    [hostCookie({ secure: false })],
    [hostCookie({ domain: undefined, url: "https://other.example/" })],
  ]) {
    await writeState(cookies);
    await assert.rejects(loadStagingConfiguration(fixtureValue.configPath, { environment: {} }), StagingAcceptanceError);
  }
  await writeState([hostCookie({ domain: undefined, url: "https://app.example/" })]);
  const loaded = await loadStagingConfiguration(fixtureValue.configPath, { environment: {} });
  assert.equal(loaded.accounts.primary.storageState.cookies[0].name, "fyrlet_host");
});

test("revocation evidence requires an unexpired full session before and after rejection", async () => {
  const revocation = { clockSkewSeconds: 5 };
  const start = Date.parse("2026-11-08T00:00:00Z");
  let now = start;
  let calls = 0;
  const session = { token: "rts_private-session-token", expiresAt: new Date(start + 10_000).toISOString() };
  await expectRevokedSession(session, async () => {
    calls++;
    const error = new StagingAcceptanceError("SDK query was rejected");
    error.code = "UNAUTHENTICATED";
    throw error;
  }, { revocation, now: () => now });
  assert.equal(calls, 1);

  now = start;
  calls = 0;
  await assert.rejects(expectRevokedSession({ ...session, expiresAt: new Date(start + 5000).toISOString() }, async () => { calls++; }, {
    revocation, now: () => now,
  }), /unexpired/);
  assert.equal(calls, 0);

  now = start;
  await assert.rejects(expectRevokedSession({ ...session, expiresAt: new Date(start + 7000).toISOString() }, async () => {
    now += 2001;
    const error = new StagingAcceptanceError("SDK query was rejected");
    error.code = "UNAUTHENTICATED";
    throw error;
  }, { revocation, now: () => now }), /unexpired/);

  const cookie = { expires: (start + 10_000) / 1000 };
  assert.doesNotThrow(() => requireCookieValidityMargin(cookie, revocation, start));
  assert.throws(() => requireCookieValidityMargin(cookie, revocation, start + 5001), /unexpired/);
});

test("logout waits for exact same-origin POST and confirmed response body success", async () => {
  const response = (url, method = "POST") => ({ url: () => url, request: () => ({ method: () => method }) });
  assert.equal(isSameOriginLogoutResponse(response("https://app.example/auth/logout"), "https://app.example"), true);
  for (const candidate of [
    response("https://evil.example/auth/logout"), response("https://app.example/auth/logout", "GET"),
    response("https://app.example/auth/logout?next=private"), response("https://app.example/auth/other"),
  ]) assert.equal(isSameOriginLogoutResponse(candidate, "https://app.example"), false);

  await requireLogoutSuccess({ status: 200, json: async () => ({ signedOut: true, revoked: true }) });
  for (const candidate of [
    { status: 503, json: async () => ({ signedOut: true, revoked: false }) },
    { status: 200, json: async () => ({ signedOut: true, revoked: false, detail: "private-response-body" }) },
    { status: 200, json: async () => { throw new Error("private-response-body"); } },
  ]) {
    await assert.rejects(requireLogoutSuccess(candidate), (error) => {
      assert.ok(!error.message.includes("private-response-body"));
      return true;
    });
  }
});

test("host provider comparison is anchored to configured names and labels", () => {
  const configured = [{ name: "first", label: "First IdP" }, { name: "second", label: "Second IdP" }];
  const expected = comparableProviderMetadata(configured);
  assert.deepEqual(comparableProviderMetadata([...configured].reverse()), expected);
  assert.notDeepEqual(comparableProviderMetadata([{ ...configured[0], label: "Unexpected" }, configured[1]]), expected);
  assert.notDeepEqual(comparableProviderMetadata([configured[0]]), expected);
  assert.notDeepEqual(comparableProviderMetadata([...configured, { name: "extra", label: "Extra" }]), expected);
});

test("preflight and execution reject dirty source checkouts before network activity", async (context) => {
  for (const mode of ["preflight", "execute"]) {
    const { configPath } = await fixture(context);
    let calls = 0;
    const report = await runStagingAcceptance({ configPath, mode, confirmation: "inbox-staging", environment: {} }, {
      sourceMetadata: source({ clean: false }),
      preflightChecker: async () => { calls++; }, browserRunner: async () => { calls++; },
      sdkRuntimePreparer: async () => { calls++; },
    });
    assert.equal(report.status, "failed");
    assert.equal(calls, 0);
    assert.match(report.checks[0].reason, /clean tracked and non-ignored/);
  }
});

async function sdkFixture(context) {
  const directory = await mkdtemp(join(tmpdir(), "fyrlet-staging-sdk-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  await mkdir(join(directory, "dist"), { recursive: true });
  await mkdir(join(directory, "node_modules/phoenix/priv/static"), { recursive: true });
  await writeFile(join(directory, "package.json"), JSON.stringify({ name: "@fyrlet/client", dependencies: { phoenix: "1.8.16" } }));
  await writeFile(join(directory, "package-lock.json"), JSON.stringify({
    packages: { "node_modules/phoenix": { version: "1.8.16", integrity: "sha512-offline-fixture" } },
  }));
  await writeFile(join(directory, "node_modules/phoenix/package.json"), JSON.stringify({
    name: "phoenix", version: "1.8.16", exports: { import: "./priv/static/phoenix.mjs" },
  }));
  await writeFile(join(directory, "node_modules/phoenix/priv/static/phoenix.mjs"), "export const phoenix = 'original';\n");
  await writeFile(join(directory, "dist/index.js"), "export const stale = true;\n");
  return directory;
}

test("SDK runtime binding cleans and rebuilds offline, hashes dist and detects dependency tampering", async (context) => {
  const directory = await sdkFixture(context);
  let builds = 0;
  const binding = await prepareSdkRuntime({
    sdkDirectory: directory, applicationSDKPath: directory,
    build: async (root) => {
      builds++;
      await assert.rejects(readFile(join(root, "dist/index.js"), "utf8"));
      await mkdir(join(root, "dist"), { recursive: true });
      await writeFile(join(root, "dist/index.js"), "export const rebuilt = true;\n");
    },
  });
  assert.equal(builds, 1);
  assert.equal(binding.algorithm, "sha256");
  assert.match(binding.digest, /^[a-f0-9]{64}$/);
  assert.equal(binding.dependencies[0].version, "1.8.16");
  assert.ok(!JSON.stringify(binding).includes(directory));
  await verifySdkRuntimeBinding(binding, { sdkDirectory: directory, applicationSDKPath: directory });

  const original = await sdkRuntimeFingerprint(directory);
  await writeFile(join(directory, "dist/extra.js"), "export const tampered = true;\n");
  assert.notEqual((await sdkRuntimeFingerprint(directory)).digest, original.digest);
  await assert.rejects(verifySdkRuntimeBinding(binding, { sdkDirectory: directory, applicationSDKPath: directory }), /changed/);
  await rm(join(directory, "dist/extra.js"));
  await verifySdkRuntimeBinding(binding, { sdkDirectory: directory, applicationSDKPath: directory });

  await writeFile(join(directory, "node_modules/phoenix/priv/static/phoenix.mjs"), "export const phoenix = 'tampered';\n");
  await assert.rejects(verifySdkRuntimeBinding(binding, { sdkDirectory: directory, applicationSDKPath: directory }), /changed/);
});

test("injected browser runners never build or bind the real SDK", async (context) => {
  const { configPath } = await fixture(context);
  let builds = 0;
  const report = await runStagingAcceptance({ configPath, mode: "execute", confirmation: "inbox-staging", environment: {} }, {
    sourceMetadata: source(), finalFingerprint: async () => "offline-source-digest", preflightChecker: async () => passingPreflight,
    sdkRuntimePreparer: async () => { builds++; throw new Error("offline tests must not build"); },
    browserRunner: async () => ({ checks: passingBrowserChecks() }),
  });
  assert.equal(builds, 0);
  assert.equal(report.sdkRuntime, undefined);
  assert.equal(report.status, "passed");
});

test("duplicate or not-run required application checks fail completeness while remaining visible", async (context) => {
  for (const variation of ["duplicate", "not-run"]) {
    const { configPath } = await fixture(context);
    const checks = passingBrowserChecks();
    if (variation === "duplicate") checks.push({ name: "host-configuration", status: "passed", reason: "duplicate offline fixture" });
    else checks.find((check) => check.name === "host-configuration").status = "not-run";
    const report = await runStagingAcceptance({ configPath, mode: "execute", confirmation: "inbox-staging", environment: {} }, {
      sourceMetadata: source(), finalFingerprint: async () => "offline-source-digest", preflightChecker: async () => passingPreflight,
      browserRunner: async () => ({ checks }),
    });
    assert.equal(report.status, "failed");
    assert.equal(report.complete, false);
    assert.equal(report.checks.find((check) => check.name === "application-completeness").status, "failed");
    assert.ok(incompleteRequiredApplicationChecks(report.checks).includes("host-configuration"));
    assert.equal(report.checks.filter((check) => check.name === "host-configuration").length, variation === "duplicate" ? 2 : 1);
    if (variation === "not-run") assert.equal(report.checks.find((check) => check.name === "host-configuration").status, "not-run");
  }
});

test("report persistence rejects public directories and output symlinks", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "fyrlet-staging-output-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const report = { status: "not-run", checks: [] };
  if (process.platform !== "win32") {
    const publicDirectory = join(directory, "public");
    await mkdir(publicDirectory, { mode: 0o755 });
    await chmod(publicDirectory, 0o755);
    await assert.rejects(persistReport(publicDirectory, report), /group or other/);

    const target = join(directory, "target");
    const link = join(directory, "linked-output");
    await mkdir(target, { mode: 0o700 });
    await symlink(target, link, "dir");
    await assert.rejects(persistReport(link, report), /symbolic link/);
    assert.deepEqual(await readdir(target), []);
  }
});

test("concurrent report updates use exclusive random temporary files", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "fyrlet-staging-concurrent-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  await Promise.all([
    persistReport(directory, { status: "not-run", sequence: 1 }),
    persistReport(directory, { status: "not-run", sequence: 2 }),
  ]);
  assert.deepEqual(await readdir(directory), ["result.json"]);
  const persisted = JSON.parse(await readFile(join(directory, "result.json"), "utf8"));
  assert.ok([1, 2].includes(persisted.sequence));
  if (process.platform !== "win32") assert.equal((await stat(join(directory, "result.json"))).mode & 0o777, 0o600);
});
