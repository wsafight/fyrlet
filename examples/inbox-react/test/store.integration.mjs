import test, { before, after } from "node:test";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { Pool } from "pg";
import { createPostgresStore, hostStoreScope } from "../server/store.mjs";
import { createAuth } from "../server/auth.mjs";
import { mockOIDC } from "./oidc-fixture.mjs";

const databaseURL = process.env.HOST_STORE_TEST_DATABASE_URL;
const database = databaseURL && new URL(databaseURL);
if (!database || !["postgres:", "postgresql:"].includes(database.protocol) || !["localhost", "127.0.0.1", "[::1]"].includes(database.hostname) || database.search || database.hash || !/^\/[a-z][a-z0-9_]*_host_test$/.test(database.pathname)) throw new Error("Use an isolated local *_host_test database");
const admin = new Pool({ connectionString: databaseURL });
const origin = "http://127.0.0.1:5173";
let oidc;
before(async () => { oidc = await mockOIDC(); });
after(async () => { await oidc.close(); await admin.end(); });

async function fixture(context, overrides = {}) {
  const namespace = randomUUID();
  const key = randomBytes(32).toString("base64url");
  const stores = [];
  const hosts = [];
  const issued = [];
  const revoked = [];
  const sessions = overrides.sessions ?? {
    async issueSession() {
      const identifier = `session-${issued.length}`;
      issued.push(identifier);
      return { session_id: identifier, project_id: "project", token: `rts_${identifier}`, expires_at: new Date(Date.now() + 600000).toISOString() };
    },
    async revokeSession(identifier) { revoked.push(identifier); },
  };
  async function instance(options = {}) {
    const store = await createPostgresStore({ databaseURL, key, namespace, ...options });
    stores.push(store);
    await store.migrate();
    const auth = await createAuth({ publicOrigin: origin, endpoint: "http://127.0.0.1:4000", projectId: "project", providers: oidc.providers,
      sessions, store, allowLocal: true, ...overrides.auth });
    hosts.push(auth);
    return auth;
  }
  context.after(async () => {
    await Promise.allSettled(hosts.map((host) => host.close()));
    await Promise.allSettled(stores.map((store) => store.close()));
    for (const store of stores) assert.equal(store.shared, true);
    const scope = hostStoreScope(namespace, { origin, endpoint: "http://127.0.0.1:4000", projectId: overrides.auth?.projectId ?? "project",
      providers: oidc.providers.map(({ name, issuer, clientId }) => ({ name, issuer, clientId })).sort((left, right) => left.name.localeCompare(right.name)) });
    await admin.query("DELETE FROM fyrlet_host_state_v1 WHERE namespace=$1", [scope]);
  });
  const first = await instance();
  const second = await instance();
  const request = (auth, path, cookie = "", method = "GET", headers = {}) => auth.handle(new Request(`${origin}${path}`, { method, headers: { cookie, ...(method === "POST" ? { origin } : {}), ...headers } }));
  async function start() {
    const response = await request(first, "/auth/login");
    assert.equal(response.status, 303);
    const flow = response.headers.getSetCookie()[0].split(";")[0];
    const callback = oidc.authorization(response.headers.get("location"));
    return { flow, path: `${callback.pathname}${callback.search}` };
  }
  async function login() {
    const attempt = await start();
    const finish = await request(second, attempt.path, attempt.flow);
    assert.equal(finish.status, 303);
    return finish.headers.getSetCookie()[0].split(";")[0];
  }
  return { first, second, instance, stores, start, login, request, issued, revoked, key, namespace };
}

test("two host pools atomically consume one login state and share the resulting identity", async (context) => {
  const setup = await fixture(context);
  const attempt = await setup.start();
  const replies = await Promise.all([setup.request(setup.first, attempt.path, attempt.flow), setup.request(setup.second, attempt.path, attempt.flow)]);
  assert.deepEqual(replies.map((reply) => reply.status).sort(), [303, 400]);
  const cookie = replies.find((reply) => reply.status === 303).headers.getSetCookie()[0].split(";")[0];
  const me = await (await setup.request(setup.second, "/auth/me", cookie)).json();
  assert.equal(me.user.name, "Alice");
  assert.equal(JSON.stringify(me).includes("rts_"), false);
});

test("simultaneous issuance and forced rotation are serialized across independent pools", async (context) => {
  const setup = await fixture(context);
  const cookie = await setup.login();
  const initial = await Promise.all([setup.first, setup.second].map((auth) => setup.request(auth, "/api/fyrlet/session", cookie, "POST")));
  assert.ok(initial.every((response) => response.status === 200));
  assert.equal(setup.issued.length, 1);
  const rotated = await Promise.all([setup.first, setup.second].map((auth) => setup.request(auth, "/api/fyrlet/session", cookie, "POST", { "x-fyrlet-refresh": "1" })));
  assert.ok(rotated.every((response) => response.status === 200));
  assert.equal(setup.issued.length, 2);
  assert.deepEqual(setup.revoked, ["session-0"]);
});

test("logout on another instance closes an in-flight issuance before it can expose the token", async (context) => {
  const started = Promise.withResolvers();
  const release = Promise.withResolvers();
  const revoked = [];
  const setup = await fixture(context, { sessions: {
    async issueSession() { started.resolve(); await release.promise; return { session_id: "late", token: "rts_late", project_id: "project", expires_at: new Date(Date.now() + 600000).toISOString() }; },
    async revokeSession(identifier) { revoked.push(identifier); },
  } });
  context.after(() => release.resolve());
  const cookie = await setup.login();
  const identifier = cookie.split("=")[1];
  const issuance = setup.request(setup.first, "/api/fyrlet/session", cookie, "POST");
  await started.promise;
  const logout = setup.request(setup.second, "/auth/logout", cookie, "POST");
  for (let attempt = 0; attempt < 100 && await setup.stores[0].isActive(identifier, Date.now()); attempt++) await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(await setup.stores[0].isActive(identifier, Date.now()), false);
  release.resolve();
  assert.equal((await issuance).status, 401);
  assert.equal((await logout).status, 200);
  assert.deepEqual(revoked, ["late"]);
  assert.equal((await setup.request(setup.first, "/api/fyrlet/session", cookie, "POST")).status, 401);
});

test("host restart preserves shared sessions and clean shutdown does not sign other instances out", async (context) => {
  const setup = await fixture(context);
  const cookie = await setup.login();
  await setup.request(setup.first, "/api/fyrlet/session", cookie, "POST");
  await setup.first.close();
  const restarted = await setup.instance();
  const response = await setup.request(restarted, "/api/fyrlet/session", cookie, "POST");
  assert.equal(response.status, 200);
  assert.equal(setup.issued.length, 1);
  assert.equal(setup.revoked.length, 0);
});

test("encrypted rows omit bearer cookies and token plaintext, and wrong keys fail closed", async (context) => {
  const setup = await fixture(context);
  const cookie = await setup.login();
  await setup.request(setup.first, "/api/fyrlet/session", cookie, "POST");
  const rows = await admin.query("SELECT identifier,payload FROM fyrlet_host_state_v1 WHERE kind='host'");
  const serialized = JSON.stringify(rows.rows);
  assert.equal(serialized.includes(cookie.split("=")[1]), false);
  assert.equal(serialized.includes("rts_"), false);
  const wrong = await createPostgresStore({ databaseURL, namespace: setup.namespace, key: randomBytes(32).toString("base64url") });
  const auth = await createAuth({ publicOrigin: origin, endpoint: "http://127.0.0.1:4000", projectId: "project", providers: oidc.providers, sessions: {}, store: wrong, allowLocal: true });
  context.after(() => auth.close());
  assert.equal((await setup.request(auth, "/auth/me", cookie)).status, 503);
});

test("database capacity is global, expired pending state frees space and lock waits are bounded", async (context) => {
  const key = randomBytes(32).toString("base64url");
  const namespace = randomUUID();
  const stores = await Promise.all([1, 2].map(() => createPostgresStore({ databaseURL, key, namespace, maxEntries: 1, lockTimeoutMs: 100 })));
  context.after(async () => {
    await Promise.all(stores.map((store) => store.close()));
    await admin.query("DELETE FROM fyrlet_host_state_v1 WHERE namespace=$1", [hostStoreScope(namespace, "capacity")]);
  });
  await stores[0].migrate();
  await Promise.all(stores.map((store) => store.bind("capacity")));
  const attempts = await Promise.allSettled(stores.map((store, index) => store.putPending(`pending-${index}`, { expiresAt: 100 }, 0)));
  assert.equal(attempts.filter((result) => result.status === "fulfilled").length, 1);
  assert.equal(attempts.find((result) => result.status === "rejected").reason.status, 429);
  await stores[0].putPending("fresh", { expiresAt: 200 }, 100);
  assert.equal(await stores[1].takePending("fresh", 200), undefined);
  await stores[0].putHost("host", { expiresAt: Date.now() + 100000, closed: false });
  const started = Promise.withResolvers();
  const release = Promise.withResolvers();
  const held = stores[0].withHost("host", async () => { started.resolve(); await release.promise; });
  await started.promise;
  try { await assert.rejects(stores[1].withHost("host", async () => {}), { status: 503 }); }
  finally { release.resolve(); await held; }
  assert.equal(await stores[1].isActive("host", Date.now()), true);
});

test("expiry cleanup can decrypt and revoke a persisted token without storing its cookie", async (context) => {
  const setup = await fixture(context);
  const cookie = await setup.login();
  await setup.request(setup.first, "/api/fyrlet/session", cookie, "POST");
  await setup.stores[0].markClosed(cookie.split("=")[1]);
  const expired = await setup.stores[1].expired(Date.now(), 8);
  assert.ok(expired.length > 0);
  await setup.stores[1].withHost(expired[0], async (host) => {
    assert.equal(host.fyrlet.session_id, "session-0");
    await setup.stores[1].deleteHost(host.identifier);
  });
  assert.equal(await setup.stores[0].getHost(cookie.split("=")[1]), undefined);
});

test("a killed host process releases its database lock without losing a concurrent logout tombstone", { timeout: 15000 }, async (context) => {
  const setup = await fixture(context);
  const cookie = await setup.login();
  const identifier = cookie.split("=")[1];
  const scope = { origin, endpoint: "http://127.0.0.1:4000", projectId: "project", providers: oidc.providers.map(({ name, issuer, clientId }) => ({ name, issuer, clientId })) };
  const worker = spawn(process.execPath, [new URL("./store-worker.mjs", import.meta.url).pathname], { env: { ...process.env, HOST_STORE_TEST_DATABASE_URL: databaseURL,
    HOST_STORE_KEY: setup.key, HOST_STORE_NAMESPACE: setup.namespace, HOST_STORE_TEST_SCOPE: JSON.stringify(scope), HOST_STORE_TEST_IDENTIFIER: identifier }, stdio: ["ignore", "ignore", "ignore", "ipc"] });
  context.after(() => { if (worker.exitCode === null && worker.signalCode === null) worker.kill("SIGKILL"); });
  let timer;
  try {
    const [message] = await Promise.race([once(worker, "message"), once(worker, "exit").then(() => { throw new Error("Worker exited before locking"); }), new Promise((_resolve, reject) => { timer = setTimeout(() => reject(new Error("Worker lock timeout")), 5000); })]);
    assert.equal(message.locked, true);
  } finally { clearTimeout(timer); }
  await setup.stores[1].markClosed(identifier);
  assert.equal(await setup.stores[1].isActive(identifier, Date.now()), false);
  const exited = once(worker, "exit"); worker.kill("SIGKILL"); await exited;
  await setup.stores[1].withHost(identifier, async (host) => { assert.equal(host.closed, true); });
});

test("the same database and encryption key do not allow cookies to cross project boundaries", async (context) => {
  const setup = await fixture(context);
  const cookie = await setup.login();
  const store = await createPostgresStore({ databaseURL, key: setup.key, namespace: setup.namespace });
  const auth = await createAuth({ publicOrigin: origin, endpoint: "http://127.0.0.1:4000", projectId: "other", providers: oidc.providers, sessions: {}, store, allowLocal: true });
  context.after(() => auth.close());
  assert.equal((await setup.request(auth, "/api/fyrlet/session", cookie, "POST")).status, 401);
});

test("more independent issuers than pool connections do not deadlock nested activity checks", { timeout: 10000 }, async (context) => {
  const setup = await fixture(context);
  const cookies = [];
  for (let index = 0; index < 10; index++) cookies.push(await setup.login());
  const replies = await Promise.all(cookies.map((cookie) => setup.request(setup.first, "/api/fyrlet/session", cookie, "POST")));
  assert.ok(replies.every((reply) => reply.status === 200));
  assert.equal(setup.issued.length, 10);
});
