import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  assertRealOptIn,
  boundedSessionCall,
  ConfigError,
  createReport,
  createSessionLifecycle,
  createReportStore,
  exitCodeForStatus,
  finalizeReport,
  hashRuntimeFiles,
  isLoopbackHostname,
  main,
  OptInError,
  parseArguments,
  publicError,
  redact,
  setScenario,
  summarizeScenarios,
  validateConfig,
  validateEndpoint,
  validateObservedMetadata,
} from "./multihost_acceptance.mjs";
import { controlArguments, controlEnvironment, createControl, parseInspection, parseRoute } from "../deploy/multihost/executable_control.mjs";
import { assertExactChatConvergence, assertSubscriptionDeniedWithoutData } from "../deploy/multihost/chat_workload.mjs";

function fixture() {
  return {
    schemaVersion: 1,
    execution: { realMultiHostOptIn: false, allowLoopbackEndpoints: false, timeoutMs: 5000, sessionTtlSeconds: 900 },
    project: { projectIdEnv: "OFFLINE_MULTIHOST_PROJECT_ID", serviceKeyEnv: "OFFLINE_MULTIHOST_SERVICE_KEY" },
    attestation: {
      operator: "offline-test", attestedAt: "2026-11-08T00:00:00Z", evidenceRef: "OFFLINE-TEST",
      distinctPhysicalHosts: true, sharedPostgreSQL: true, sameRelease: true, sameSchema: true,
    },
    deployment: { release: "chat@sha256:offline", schema: "schema-sha256:offline", database: "postgres-cluster/offline-test" },
    recoveryEndpoint: "https://chat.example.internal",
    nodes: [
      { id: "node-a", endpoint: "https://node-a.example.internal", physicalHostId: "host-a", expectedInstanceId: "instance-a" },
      { id: "node-b", endpoint: "https://node-b.example.internal", physicalHostId: "host-b", expectedInstanceId: "instance-b" },
    ],
    fault: { victim: "node-a", survivor: "node-b" },
    control: { adapter: "./executable_control.mjs", executable: "/offline/operator-control", fixedArgs: ["--deployment", "offline"], timeoutMs: 5000 },
    workload: { adapter: "./chat_workload.mjs", kind: "chat", runs: false },
  };
}

function observations(config) {
  return config.nodes.map((node) => ({
    nodeId: node.id,
    instanceId: node.expectedInstanceId,
    physicalHostId: node.physicalHostId,
    release: config.deployment.release,
    schema: config.deployment.schema,
    database: config.deployment.database,
  }));
}

test("strict validation accepts a complete secret-free multi-host configuration", () => {
  const config = validateConfig(fixture());
  assert.equal(config.nodes.length, 2);
  assert.equal(config.execution.allowLoopbackEndpoints, false);
  assert.equal(config.workload.runs, false);
  assert.equal(config.recoveryEndpoint, "https://chat.example.internal");
});

test("bundled example is valid offline and remains opted out", async () => {
  const example = JSON.parse(await readFile(new URL("../deploy/multihost/chat.example.json", import.meta.url), "utf8"));
  const config = validateConfig(example);
  assert.equal(config.execution.realMultiHostOptIn, false);
  assert.throws(() => assertRealOptIn(config, true), OptInError);
});

test("missing, unknown and ambiguous configuration fails closed", async (context) => {
  const cases = [
    ["unknown field", (config) => { config.unexpected = true; }],
    ["secret in project config", (config) => { config.project.serviceKey = "rtk_offline_secret_value"; }],
    ["one node", (config) => { config.nodes = [config.nodes[0]]; config.fault = { victim: "node-a", survivor: "node-a" }; }],
    ["duplicate node ID", (config) => { config.nodes[1].id = "node-a"; }],
    ["duplicate endpoint", (config) => { config.nodes[1].endpoint = config.nodes[0].endpoint; }],
    ["duplicate instance identity", (config) => { config.nodes[1].expectedInstanceId = "instance-a"; }],
    ["one physical host", (config) => { config.nodes[1].physicalHostId = "host-a"; }],
    ["unknown victim", (config) => { config.fault.victim = "missing"; }],
    ["same victim and survivor", (config) => { config.fault.survivor = "node-a"; }],
    ["routed endpoint equals direct endpoint", (config) => { config.recoveryEndpoint = config.nodes[0].endpoint; }],
    ["missing physical attestation", (config) => { config.attestation.distinctPhysicalHosts = false; }],
    ["missing shared database attestation", (config) => { config.attestation.sharedPostgreSQL = false; }],
    ["missing release attestation", (config) => { config.attestation.sameRelease = false; }],
    ["missing schema attestation", (config) => { config.attestation.sameSchema = false; }],
    ["database DSN", (config) => { config.deployment.database = "postgres://user:password@example.internal/database"; }],
    ["URL credential in attestation", (config) => { config.attestation.evidenceRef = "https://operator:private@example.internal/change"; }],
    ["custom scheme URL credential", (config) => { config.attestation.operator = "vault://operator:private@example.internal/change"; }],
    ["query access token", (config) => { config.attestation.evidenceRef = "change-record?access_token=private-value"; }],
    ["MySQL connection string", (config) => { config.attestation.operator = "mysql://db.example.internal/fyrlet"; }],
    ["Redis connection string", (config) => { config.deployment.database = "redis://cache.example.internal/0"; }],
    ["free-form host identity", (config) => { config.nodes[0].physicalHostId = "host a with a private description"; }],
    ["credential fixed argument", (config) => { config.control.fixedArgs = ["--token=rtk_offline_secret_value"]; }],
    ["reserved fixed argument", (config) => { config.control.fixedArgs = ["--node", "node-b"]; }],
    ["inline reserved fixed argument", (config) => { config.control.fixedArgs = ["--node=node-b"]; }],
    ["action override fixed argument", (config) => { config.control.fixedArgs = ["--action=stop"]; }],
    ["shared credential variable", (config) => { config.project.projectIdEnv = config.project.serviceKeyEnv; }],
    ["relative executable", (config) => { config.control.executable = "./operator-control"; }],
    ["package adapter specifier", (config) => { config.workload.adapter = "some-package"; }],
    ["Runs wrong type", (config) => { config.workload.runs = "supported"; }],
    ["environment value instead of name", (config) => { config.project.serviceKeyEnv = "rtk_offline_secret_value"; }],
  ];
  for (const [name, mutate] of cases) {
    await context.test(name, () => {
      const config = fixture();
      mutate(config);
      assert.throws(() => validateConfig(config), ConfigError);
    });
  }
});

test("HTTPS is mandatory off loopback and loopback requires a separate tunnel opt-in", () => {
  assert.equal(validateEndpoint("https://service.example.internal"), "https://service.example.internal");
  assert.throws(() => validateEndpoint("http://service.example.internal"), /HTTPS is required/);
  assert.throws(() => validateEndpoint("https://user:password@service.example.internal"), /must not contain a credential|must not contain credentials/);
  assert.throws(() => validateEndpoint("https://service.example.internal/?token=secret"), /must not contain a credential|must not contain credentials/);
  assert.throws(() => validateEndpoint("https://service.example.internal/rtk_endpoint_secret"), /must not contain a credential/);
  assert.throws(() => validateEndpoint("http://127.0.0.1:4000"), /allowLoopbackEndpoints/);
  assert.equal(validateEndpoint("http://127.0.0.1:4000", { allowLoopback: true }), "http://127.0.0.1:4000");
  assert.equal(validateEndpoint("http://[::1]:4000", { allowLoopback: true }), "http://[::1]:4000");
  assert.ok(isLoopbackHostname("localhost"));
  assert.ok(isLoopbackHostname("localhost."));
  assert.ok(isLoopbackHostname("service.localhost."));
  assert.ok(isLoopbackHostname("127.0.0.2"));
  assert.ok(isLoopbackHostname("127.0.0.2."));
  assert.ok(isLoopbackHostname("[::ffff:127.0.0.2]"));
  assert.ok(isLoopbackHostname("[::ffff:7f00:2]"));
  assert.ok(isLoopbackHostname("0:0:0:0:0:ffff:7f00:2"));
  assert.ok(!isLoopbackHostname("[::ffff:800:2]"));
  assert.ok(!isLoopbackHostname("10.0.0.2"));
  assert.equal(validateEndpoint("http://localhost.:4000", { allowLoopback: true }), "http://localhost.:4000");
  assert.equal(validateEndpoint("http://[::ffff:7f00:2]:4000", { allowLoopback: true }), "http://[::ffff:7f00:2]:4000");

  const config = fixture();
  config.recoveryEndpoint = "http://127.0.0.1:4000";
  config.nodes[0].endpoint = "http://127.0.0.1:4001";
  config.nodes[1].endpoint = "http://127.0.0.1:4002";
  assert.throws(() => validateConfig(config), /allowLoopbackEndpoints/);
  config.execution.allowLoopbackEndpoints = true;
  assert.equal(validateConfig(config).nodes.length, 2);
});

test("real execution needs both independent opt-ins", () => {
  const config = validateConfig(fixture());
  assert.throws(() => assertRealOptIn(config, false), OptInError);
  assert.throws(() => assertRealOptIn(config, true), OptInError);
  config.execution.realMultiHostOptIn = true;
  assert.throws(() => assertRealOptIn(config, false), OptInError);
  assert.equal(assertRealOptIn(config, true), undefined);
});

test("observed metadata must match every expectation and retain unique identities and hosts", () => {
  const config = validateConfig(fixture());
  assert.equal(validateObservedMetadata(config, observations(config)), true);
  for (const [field, value] of [["instanceId", "wrong"], ["physicalHostId", "wrong"], ["release", "wrong"], ["schema", "wrong"], ["database", "wrong"]]) {
    const changed = observations(config);
    changed[1][field] = value;
    assert.throws(() => validateObservedMetadata(config, changed), ConfigError, field);
  }
  const missing = observations(config).slice(0, 1);
  assert.throws(() => validateObservedMetadata(config, missing), /incomplete/);
  const duplicateNode = observations(config);
  duplicateNode[1].nodeId = "node-a";
  assert.throws(() => validateObservedMetadata(config, duplicateNode), /duplicate node/);
});

test("redaction removes common secret forms recursively without mutating input", () => {
  const input = {
    token: "plain-token",
    nested: { password: "correct horse", authorization: "Bearer abc.def" },
    note: "Bearer abc.def rtk_very_secret_value password=hunter2 access_token=query-secret&next=1 refresh_token=refresh-secret",
    url: "postgres://user:private-password@db.example.internal/fyrlet",
    mysql: "mysql://user:mysql-password@db.example.internal/fyrlet",
    redis: "redis://cache.example.internal/0",
    custom: "vault://user:vault-password@example.internal/secret",
    harmless: "passed",
  };
  const output = redact(input);
  const serialized = JSON.stringify(output);
  for (const secret of ["plain-token", "correct horse", "abc.def", "rtk_very_secret_value", "hunter2", "query-secret", "refresh-secret", "private-password", "mysql-password", "redis://", "vault-password"]) assert.ok(!serialized.includes(secret), secret);
  assert.equal(output.harmless, "passed");
  assert.equal(input.token, "plain-token");
  assert.equal(output.nested.password, "[REDACTED]");
});

test("public errors discard raw messages and retain only bounded protocol facts", () => {
  const reason = publicError(Object.assign(new Error("rtk_do_not_record_this_secret"), { code: "FORBIDDEN", status: 403 }), "Scenario failed");
  assert.equal(reason, "Scenario failed; code=FORBIDDEN; HTTP 403");
  assert.ok(!reason.includes("rtk_"));
  assert.equal(publicError(new Error("private details"), "Scenario failed"), "Scenario failed");
  const codedSecret = publicError(Object.assign(new Error("hidden"), { code: "RTK_SECRETVALUE" }), "Scenario failed");
  assert.ok(!codedSecret.includes("RTK_SECRETVALUE"));
});

test("status aggregation distinguishes passed, failed and incomplete required scenarios", () => {
  const report = createReport("config-check", false);
  setScenario(report, "configuration", "passed", "Offline schema validation passed");
  finalizeReport(report);
  assert.equal(report.status, "not-run");
  assert.equal(exitCodeForStatus(report.status), 2);
  assert.match(report.reason, /incomplete/);

  for (const scenario of report.scenarios) if (scenario.required) setScenario(report, scenario.name, "passed", "Offline status-helper test");
  finalizeReport(report);
  assert.equal(report.status, "passed");
  assert.equal(report.scenarios.find((scenario) => scenario.name === "runs").status, "not-run");
  assert.equal(exitCodeForStatus(report.status), 0);

  setScenario(report, "runs", "failed", "Optional but attempted scenario failed");
  finalizeReport(report);
  assert.equal(report.status, "failed");
  assert.equal(exitCodeForStatus(report.status), 1);
  assert.equal(summarizeScenarios([]), "failed");
  assert.throws(() => setScenario(report, "runs", "skipped", "Invalid status"), ConfigError);
});

test("required Runs change aggregation, while unsupported unrequested Runs stay optional", () => {
  const withoutRuns = createReport("config-check", false);
  assert.equal(withoutRuns.scenarios.find((scenario) => scenario.name === "runs").required, false);
  const withRuns = createReport("config-check", true);
  assert.equal(withRuns.scenarios.find((scenario) => scenario.name === "runs").required, true);
});

test("an interrupted drill can never aggregate to passed even if cleanup completed", () => {
  const report = createReport("real-multi-host", false);
  for (const scenario of report.scenarios) if (scenario.required) setScenario(report, scenario.name, "passed", "Offline interruption aggregation setup");
  report.interrupted = true;
  finalizeReport(report);
  assert.equal(report.status, "not-run");
  assert.match(report.reason, /interrupted/);
  assert.equal(exitCodeForStatus(report.status), 2);
});

test("private report creation is non-overwriting, redacted and mode 0600 in a mode 0700 directory", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "fyrlet-multihost-report-test-"));
  try {
    const directory = join(temporary, "report");
    const store = await createReportStore(directory);
    const report = createReport();
    report.privateTestValue = "rtk_report_secret_must_not_survive";
    await store.persist(report);
    const serialized = await readFile(store.path, "utf8");
    assert.ok(!serialized.includes("rtk_report_secret_must_not_survive"));
    assert.equal(JSON.parse(serialized).status, "not-run");
    assert.equal((await stat(store.path)).mode & 0o777, 0o600);
    assert.equal((await stat(directory)).mode & 0o777, 0o700);
    await assert.rejects(createReportStore(directory), { code: "EEXIST" });
  } finally { await rm(temporary, { recursive: true, force: true }); }
});

test("runtime artifact hashes are order-independent and bind labels, contents and file types", async (context) => {
  const temporary = await mkdtemp(join(tmpdir(), "fyrlet-runtime-hash-test-"));
  context.after(async () => { await rm(temporary, { recursive: true, force: true }); });
  const first = join(temporary, "first.js");
  const second = join(temporary, "second.js");
  await writeFile(first, "export const first = 1;\n");
  await writeFile(second, "export const second = 2;\n");
  const entries = [{ label: "z/second", path: second }, { label: "a/first", path: first }];
  const hashed = await hashRuntimeFiles(entries);
  assert.equal(hashed.algorithm, "sha256");
  assert.equal(hashed.fileCount, 2);
  assert.match(hashed.digest, /^[a-f0-9]{64}$/);
  assert.deepEqual(await hashRuntimeFiles([...entries].reverse()), hashed);
  await writeFile(first, "export const first = 3;\n");
  assert.notEqual((await hashRuntimeFiles(entries)).digest, hashed.digest);
  assert.notEqual((await hashRuntimeFiles([{ label: "renamed", path: second }, entries[1]])).digest, hashed.digest);
  await assert.rejects(hashRuntimeFiles([entries[0], entries[0]]), /labels must be unique/);
  await assert.rejects(hashRuntimeFiles([{ label: "directory", path: temporary }]), /must be files/);
  await assert.rejects(hashRuntimeFiles([]), /must not be empty/);
});

test("bounded session calls abort on timeout without losing the raw late outcome", async () => {
  let finish;
  let signal;
  const call = boundedSessionCall((receivedSignal) => {
    signal = receivedSignal;
    return new Promise((resolve) => { finish = resolve; });
  }, 5);
  await assert.rejects(call.operation, { code: "TIMEOUT" });
  assert.equal(signal.aborted, true);
  assert.equal(signal.reason.code, "TIMEOUT");
  finish({ session_id: "late-session" });
  assert.deepEqual(await call.raw, { session_id: "late-session" });

  const successful = boundedSessionCall(async (receivedSignal) => {
    assert.equal(receivedSignal.aborted, false);
    return { session_id: "issued-session" };
  }, 1000);
  assert.deepEqual(await successful.operation, { session_id: "issued-session" });
});

test("session lifecycle refreshes tokens, revokes every known session and closes issuance", async () => {
  const issuedInputs = [];
  const revoked = [];
  let sequence = 0;
  const lifecycle = createSessionLifecycle({
    subject: "subject-a",
    sessionTtlSeconds: 900,
    timeoutMs: 1000,
    service: {
      issueSession: async (input) => {
        issuedInputs.push(input);
        sequence += 1;
        return { session_id: `session-${sequence}`, token: `token-${sequence}` };
      },
    },
    revocationService: { revokeSession: async (sessionId) => { revoked.push(sessionId); } },
  });
  await lifecycle.issue();
  assert.equal(await lifecycle.getToken({ forceRefresh: false }), "token-1");
  assert.equal(await lifecycle.getToken({ forceRefresh: true }), "token-2");
  assert.deepEqual(issuedInputs, [
    { external_subject: "subject-a", ttl_seconds: 900 },
    { external_subject: "subject-a", ttl_seconds: 900 },
  ]);
  assert.deepEqual(await lifecycle.cleanup(), { drillSessionsRevoked: true, unknownSessionIssuanceOutcomes: 0 });
  assert.deepEqual(revoked.sort(), ["session-1", "session-2"]);
  await assert.rejects(lifecycle.issue(), /closed during cleanup/);
  await assert.rejects(lifecycle.getToken({ forceRefresh: false }), /cleaned up/);
});

test("a timed-out session issue fails cleanup even when its late success is revoked", async () => {
  let finishIssue;
  const revoked = [];
  const lifecycle = createSessionLifecycle({
    subject: "subject-late",
    sessionTtlSeconds: 900,
    timeoutMs: 5,
    service: { issueSession: () => new Promise((resolve) => { finishIssue = resolve; }) },
    revocationService: { revokeSession: async (sessionId) => { revoked.push(sessionId); } },
  });
  await assert.rejects(lifecycle.issue(), { code: "TIMEOUT" });
  await assert.rejects(lifecycle.cleanup(), (error) => {
    assert.ok(error.cleanupFailures.includes("unknown-session-issuance-outcome"));
    return true;
  });
  finishIssue({ session_id: "late-session", token: "late-token" });
  for (let attempt = 0; attempt < 100 && revoked.length === 0; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  assert.deepEqual(revoked, ["late-session"]);
  assert.equal(lifecycle.state.unknownSessionOutcomes, 1);
});

test("a session issued after cleanup starts is revoked but never reported as clean", async () => {
  let finishIssue;
  const revoked = [];
  const lifecycle = createSessionLifecycle({
    subject: "subject-race",
    sessionTtlSeconds: 900,
    timeoutMs: 1000,
    service: { issueSession: () => new Promise((resolve) => { finishIssue = resolve; }) },
    revocationService: { revokeSession: async (sessionId) => { revoked.push(sessionId); } },
  });
  const issuing = lifecycle.issue();
  await Promise.resolve();
  const cleaning = lifecycle.cleanup();
  finishIssue({ session_id: "racing-session", token: "racing-token" });
  await assert.rejects(issuing, /after cleanup started/);
  await assert.rejects(cleaning, (error) => {
    assert.ok(error.cleanupFailures.includes("unknown-session-issuance-outcome"));
    return true;
  });
  assert.deepEqual(revoked, ["racing-session"]);
});

test("a malformed issuance response remains an unknown outcome and fails cleanup", async () => {
  const revoked = [];
  const lifecycle = createSessionLifecycle({
    subject: "subject-malformed",
    sessionTtlSeconds: 900,
    timeoutMs: 1000,
    service: { issueSession: async () => ({ session_id: "malformed-session" }) },
    revocationService: { revokeSession: async (sessionId) => { revoked.push(sessionId); } },
  });
  await assert.rejects(lifecycle.issue(), /invalid and requires reconciliation/);
  await assert.rejects(lifecycle.cleanup(), (error) => {
    assert.ok(error.cleanupFailures.includes("unknown-session-issuance-outcome"));
    return true;
  });
  assert.deepEqual(revoked, ["malformed-session"]);
});

function subscriptionFixture(initialState) {
  let state = initialState;
  let listening = false;
  let unsubscribed = false;
  return {
    getState: () => state,
    onChange: (listener) => { listening = true; listener(state); return () => { listening = false; }; },
    unsubscribe: () => { unsubscribed = true; },
    get listening() { return listening; },
    get unsubscribed() { return unsubscribed; },
  };
}

test("outsider subscription assertions require authorization errors and no data exposure", async () => {
  const waitFor = async (check) => { assert.ok(await check(), "Condition was not observed"); };
  for (const code of ["FORBIDDEN", "NOT_FOUND"]) {
    const subscription = subscriptionFixture({ status: "error", data: undefined, error: { code } });
    await assertSubscriptionDeniedWithoutData(subscription, waitFor);
    assert.equal(subscription.listening, false);
    assert.equal(subscription.unsubscribed, true);
  }
  for (const state of [
    { status: "error", data: undefined, error: { code: "NETWORK_ERROR" } },
    { status: "error", data: undefined, error: { code: "UNAUTHORIZED" } },
    { status: "ready", data: [{ id: "private-message" }], error: undefined },
    { status: "error", data: [{ id: "private-message" }], error: { code: "FORBIDDEN" } },
  ]) {
    const subscription = subscriptionFixture(state);
    await assert.rejects(assertSubscriptionDeniedWithoutData(subscription, waitFor));
    assert.equal(subscription.listening, false);
    assert.equal(subscription.unsubscribed, true);
  }
});

test("chat convergence requires exactly the ordered durable pre/post-fault writes", () => {
  const before = { id: "before-id", text: "before-text" };
  const after = { id: "after-id", text: "after-text" };
  const stream = (items) => ({ getState: () => ({ data: items }) });
  const valid = { recovered: stream([before, after]), surviving: stream([before, after]), history: { items: [before, after] }, beforeId: before.id, afterId: after.id, beforeText: before.text, afterText: after.text };
  assert.equal(assertExactChatConvergence(valid), undefined);
  for (const items of [[before], [before, after, after], [after, before], [before, after, { id: "unexpected", text: "unexpected" }]]) {
    assert.throws(() => assertExactChatConvergence({ ...valid, recovered: stream(items) }), /gap, duplicate or unexpected/);
    assert.throws(() => assertExactChatConvergence({ ...valid, surviving: stream(items) }), /gap, duplicate or unexpected/);
    assert.throws(() => assertExactChatConvergence({ ...valid, history: { items } }), /gap, duplicate or unexpected/);
  }
});

test("control adapter uses executable plus fixed argv and allowlists JSON without an offline process", async () => {
  const config = validateConfig(fixture()).control;
  const calls = [];
  const events = [];
  const metadata = { instanceId: "instance-a", physicalHostId: "host-a", release: "release", schema: "schema", database: "database", ignoredSecret: "rtk_not_returned" };
  const control = createControl(config, {
    onEvent: (event) => events.push(event),
    environment: {
      PATH: "/offline/bin", CONTROL_REGION: "test-region",
      OFFLINE_MULTIHOST_PROJECT_ID: "project-id", OFFLINE_MULTIHOST_SERVICE_KEY: "rtk_hook_environment_secret",
      AWS_SECRET_ACCESS_KEY: "unrelated-secret", DATABASE_URL: "postgres://private-db",
    },
    deniedEnvironmentNames: ["OFFLINE_MULTIHOST_PROJECT_ID", "OFFLINE_MULTIHOST_SERVICE_KEY"],
    execute: async (executable, args, options) => {
      calls.push({ executable, args, options });
      const action = args[config.fixedArgs.length];
      if (action === "inspect") return { stdout: JSON.stringify(metadata) };
      if (action === "get-route") return { stdout: JSON.stringify({ nodeId: "node-b", token: "not-returned" }) };
      return { stdout: "sensitive output that must be discarded" };
    },
  });
  assert.deepEqual(await control.inspect("node-a"), { instanceId: "instance-a", physicalHostId: "host-a", release: "release", schema: "schema", database: "database" });
  assert.equal(await control.getRoute(), "node-b");
  await control.select("node-b");
  await control.stop("node-a");
  await control.start("node-a");
  assert.equal(calls.length, 5);
  for (const call of calls) {
    assert.equal(call.executable, "/offline/operator-control");
    assert.equal(call.options.shell, false);
    assert.equal(call.options.maxBuffer, 64 * 1024);
    assert.deepEqual(call.options.env, { PATH: "/offline/bin", CONTROL_REGION: "test-region" });
    assert.ok(!JSON.stringify(call).includes("sensitive output"));
  }
  assert.deepEqual(calls[0].args, ["--deployment", "offline", "inspect", "--node", "node-a"]);
  assert.deepEqual(calls[1].args, ["--deployment", "offline", "get-route"]);
  assert.deepEqual(calls[2].args, ["--deployment", "offline", "select", "--node", "node-b"]);
  assert.ok(events.every((event) => event.status === "passed"));
  assert.ok(!JSON.stringify(events).includes("rtk_not_returned"));
  assert.throws(() => controlArguments(config, "stop", "--malicious"), /safe configured node/);
  assert.throws(() => controlArguments(config, "restart", "node-a"), /Unsupported/);
  assert.throws(() => parseRoute("{not-json"), /valid JSON/);
  assert.throws(() => parseInspection(JSON.stringify({ ...metadata, database: "postgres://user:password@host/db" })), /unsafe/);
});

test("control failures and output never leak hook secrets into errors or events", async () => {
  const events = [];
  const control = createControl(validateConfig(fixture()).control, {
    onEvent: (event) => events.push(event),
    execute: async () => { throw Object.assign(new Error("rtk_hook_failure_secret"), { code: 1, stdout: "password=hook-secret", stderr: "Bearer hook-secret" }); },
  });
  await assert.rejects(control.stop("node-a"), (error) => {
    assert.ok(!error.message.includes("rtk_"));
    assert.ok(!error.message.includes("hook-secret"));
    return true;
  });
  assert.equal(events.length, 1);
  assert.equal(events[0].status, "failed");
  assert.equal(events[0].exitCode, 1);
  assert.ok(!JSON.stringify(events).includes("hook-secret"));
});

test("CLI rejects duplicate or ambiguous options", () => {
  assert.throws(() => parseArguments(["--config", "a.json", "--config", "b.json"]), /Duplicate/);
  assert.throws(() => parseArguments([]), /--config is required/);
  assert.equal(parseArguments(["--help"]).help, true);
  assert.equal(parseArguments(["--config", "a.json", "--execute-real-multihost"]).execute, true);
});

test("offline main validation never imports adapters, calls hooks or reports acceptance passed", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "fyrlet-multihost-main-test-"));
  const originalLog = console.log;
  try {
    console.log = () => {};
    const configPath = join(temporary, "config.json");
    const config = fixture();
    config.workload.adapter = "./does-not-exist-workload.mjs";
    config.control.adapter = "./does-not-exist-control.mjs";
    await writeFile(configPath, JSON.stringify(config));
    const output = join(temporary, "check-report");
    assert.equal(await main(["--config", configPath, "--out", output]), 2);
    const check = JSON.parse(await readFile(join(output, "result.json"), "utf8"));
    assert.equal(check.mode, "config-check");
    assert.equal(check.status, "not-run");
    assert.equal(check.scenarios.find((scenario) => scenario.name === "configuration").status, "passed");
    assert.equal(check.scenarios.find((scenario) => scenario.name === "runtime_prerequisites").status, "not-run");

    const gatedOutput = join(temporary, "gated-report");
    assert.equal(await main(["--config", configPath, "--out", gatedOutput, "--execute-real-multihost"]), 2);
    const gated = JSON.parse(await readFile(join(gatedOutput, "result.json"), "utf8"));
    assert.equal(gated.status, "not-run");
    assert.match(gated.optIn, /require both/);
    assert.equal(gated.scenarios.find((scenario) => scenario.name === "runtime_prerequisites").status, "not-run");
  } finally {
    console.log = originalLog;
    await rm(temporary, { recursive: true, force: true });
  }
});

test("real opt-in still fails before adapter import or network when credential environment is absent", async () => {
  const temporary = await mkdtemp(join(tmpdir(), "fyrlet-multihost-prerequisite-test-"));
  const originalLog = console.log;
  try {
    console.log = () => {};
    const config = fixture();
    config.execution.realMultiHostOptIn = true;
    config.project.projectIdEnv = "DEFINITELY_ABSENT_OFFLINE_PROJECT_ID_8F42D4";
    config.project.serviceKeyEnv = "DEFINITELY_ABSENT_OFFLINE_SERVICE_KEY_8F42D4";
    delete process.env[config.project.projectIdEnv];
    delete process.env[config.project.serviceKeyEnv];
    config.workload.adapter = "./does-not-exist-workload.mjs";
    config.control.adapter = "./does-not-exist-control.mjs";
    const configPath = join(temporary, "config.json");
    await writeFile(configPath, JSON.stringify(config));
    const output = join(temporary, "report");
    assert.equal(await main(["--config", configPath, "--out", output, "--execute-real-multihost"]), 1);
    const report = JSON.parse(await readFile(join(output, "result.json"), "utf8"));
    assert.equal(report.status, "failed");
    assert.equal(report.scenarios.find((scenario) => scenario.name === "runtime_prerequisites").status, "failed");
    assert.equal(report.scenarios.find((scenario) => scenario.name === "topology").status, "not-run");
    assert.equal(report.controlEvents.length, 0);
  } finally {
    console.log = originalLog;
    await rm(temporary, { recursive: true, force: true });
  }
});
