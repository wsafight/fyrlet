import test, { before, after } from "node:test";
import assert from "node:assert/strict";
import { createAuth } from "../server/auth.mjs";
import { mockOIDC } from "./oidc-fixture.mjs";

const origin = "http://127.0.0.1:5173";
let oidc;
before(async () => { oidc = await mockOIDC(); });
after(async () => { await oidc.close(); });

async function fixture(context, overrides = {}) {
  const hostOrigin = overrides.publicOrigin ?? origin;
  const issued = [];
  const revoked = [];
  const auth = await createAuth({ publicOrigin: origin, endpoint: "http://127.0.0.1:4000", projectId: "project", providers: oidc.providers, allowLocal: true,
    sessions: {
      async issueSession(input) {
        issued.push(input);
        return { token: `rts_${issued.length}`, project_id: "project", subject_id: `${input.issuer}/${input.external_subject}`, session_id: `session-${issued.length}`, expires_at: new Date(Date.now() + 600_000).toISOString() };
      },
      async revokeSession(identifier) { revoked.push(identifier); },
    }, ...overrides });
  context.after(() => auth.close());
  const request = (path, { method = "GET", cookie = "", headers = {} } = {}) => auth.handle(new Request(`${hostOrigin}${path}`, {
    method, headers: { ...(method === "POST" ? { origin: hostOrigin } : {}), cookie, ...headers },
  }));
  async function login({ provider = "first", subject = "alice", cookie = "", claims = {} } = {}) {
    const start = await request(`/auth/login?provider=${provider}`);
    assert.equal(start.status, 303);
    const flow = start.headers.getSetCookie()[0].split(";")[0];
    const callback = oidc.authorization(start.headers.get("location"), subject, { ...(overrides.now ? { iat: Math.floor(overrides.now() / 1000) } : {}), ...claims });
    const finish = await request(`${callback.pathname}${callback.search}`, { cookie: `${flow}; ${cookie}` });
    return { response: finish, callback, flow, cookie: finish.headers.getSetCookie().find((value) => value.startsWith("fyrlet_host="))?.split(";")[0] };
  }
  return { auth, request, login, issued, revoked };
}

test("OIDC login binds verified identity, caches and renews Fyrlet sessions", async (context) => {
  const { request, login, issued, revoked } = await fixture(context);
  const signedIn = await login();
  assert.equal(signedIn.response.status, 303);
  assert.ok(signedIn.response.headers.getSetCookie().every((value) => value.includes("HttpOnly") && value.includes("SameSite=Lax")));
  assert.equal((await request("/auth/me", { cookie: signedIn.cookie })).status, 200);
  const user = await (await request("/auth/me", { cookie: signedIn.cookie })).json();
  assert.equal(user.user.name, "Alice");
  assert.ok(!JSON.stringify(user).includes("rts_"));
  for (let attempt = 0; attempt < 2; attempt++) assert.equal((await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie })).status, 200);
  assert.deepEqual(issued, [{ issuer: oidc.providers[0].issuer, external_subject: "alice", ttl_seconds: 600 }]);
  const renewed = await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie, headers: { "x-fyrlet-refresh": "1" } });
  assert.equal(renewed.status, 200);
  assert.equal(issued.length, 2);
  assert.deepEqual(revoked, ["session-1"]);
});

test("anonymous, cross-origin and client identity injection are rejected", async (context) => {
  const { request, login, issued } = await fixture(context);
  assert.equal((await request("/api/fyrlet/session", { method: "POST" })).status, 401);
  const signedIn = await login();
  assert.equal((await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie, headers: { origin: "https://attacker.example" } })).status, 403);
  assert.equal((await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie, headers: { "content-length": "30" } })).status, 400);
  assert.equal(issued.length, 0);
});

test("state cookies, one-time codes and PKCE are checked", async (context) => {
  const { request, login } = await fixture(context);
  const signedIn = await login();
  const callback = `${signedIn.callback.pathname}${signedIn.callback.search}`;
  assert.equal((await request(callback, { cookie: signedIn.flow })).status, 400);
  const start = await request("/auth/login");
  const next = oidc.authorization(start.headers.get("location"));
  assert.equal((await request(`${next.pathname}${next.search}`, { cookie: "fyrlet_login=wrong" })).status, 400);
  const badChallenge = new URL(start.headers.get("location"));
  badChallenge.searchParams.set("code_challenge", "wrong");
  const invalidCode = oidc.authorization(badChallenge);
  assert.equal((await request(`${invalidCode.pathname}${invalidCode.search}`, { cookie: start.headers.getSetCookie()[0].split(";")[0] })).status, 401);
});

for (const [name, claims] of [["nonce", { nonce: "wrong" }], ["audience", { aud: "other-client" }], ["issuer", { iss: "https://wrong.example" }], ["authorized party", { azp: "other-client" }], ["expiry", { exp: 1 }]]) {
  test(`invalid ${name} cannot issue a Fyrlet session`, async (context) => {
    const { login, issued } = await fixture(context);
    const signedIn = await login({ claims });
    assert.ok(signedIn.response.status >= 400);
    assert.equal(issued.length, 0);
    assert.equal(signedIn.cookie, undefined);
  });
}

test("logout and explicit revocation close the host and Fyrlet sessions", async (context) => {
  const { request, login, revoked } = await fixture(context);
  for (const path of ["/auth/logout", "/auth/revoke"]) {
    const signedIn = await login();
    await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie });
    const response = await request(path, { method: "POST", cookie: signedIn.cookie });
    assert.deepEqual(await response.json(), { signedOut: true, revoked: true });
    assert.ok(response.headers.getSetCookie()[0].includes("Max-Age=0"));
    assert.equal((await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie })).status, 401);
  }
  assert.deepEqual(revoked, ["session-1", "session-2"]);
});

test("account switching revokes old credentials and equal subjects from distinct issuers stay distinct", async (context) => {
  const { request, login, issued, revoked } = await fixture(context);
  const first = await login();
  await request("/api/fyrlet/session", { method: "POST", cookie: first.cookie });
  const second = await login({ provider: "second", cookie: first.cookie });
  await request("/api/fyrlet/session", { method: "POST", cookie: second.cookie });
  assert.equal(issued[0].external_subject, issued[1].external_subject);
  assert.notEqual(issued[0].issuer, issued[1].issuer);
  assert.deepEqual(revoked, ["session-1"]);
  assert.equal((await request("/api/fyrlet/session", { method: "POST", cookie: first.cookie })).status, 401);
});

test("expired host login cannot renew Fyrlet credentials", async (context) => {
  let clock = Date.now();
  const { request, login, issued } = await fixture(context, { now: () => clock });
  const signedIn = await login();
  clock += 3_700_000;
  assert.equal((await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie })).status, 401);
  assert.equal(issued.length, 0);
});

test("logout racing issuance revokes the late token before exposing it", async (context) => {
  const started = Promise.withResolvers();
  const release = Promise.withResolvers();
  const revoked = [];
  const { request, login } = await fixture(context, { sessions: {
    async issueSession() { started.resolve(); await release.promise; return { token: "rts_late", project_id: "project", session_id: "late", expires_at: new Date(Date.now() + 600_000).toISOString() }; },
    async revokeSession(identifier) { revoked.push(identifier); },
  } });
  const signedIn = await login();
  const flight = request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie });
  await started.promise;
  const logout = request("/auth/logout", { method: "POST", cookie: signedIn.cookie });
  await new Promise((resolve) => setImmediate(resolve));
  release.resolve();
  assert.equal((await flight).status, 401);
  assert.equal((await logout).status, 200);
  assert.ok(revoked.includes("late"));
});

test("untrusted OIDC configuration fails before login", async () => {
  await assert.rejects(createAuth({ publicOrigin: origin, projectId: "project", providers: oidc.providers, sessions: {}, allowLocal: false }), /HTTPS/);
});

test("a mismatched discovery issuer is rejected", async () => {
  await assert.rejects(createAuth({ publicOrigin: origin, projectId: "project", providers: oidc.providers, sessions: {}, allowLocal: true,
    fetcher: async () => Response.json({ issuer: "https://wrong.example" }),
  }), /issuer mismatch/);
});

test("concurrent exchanges use one Fyrlet session", async (context) => {
  const { request, login, issued } = await fixture(context);
  const signedIn = await login();
  const responses = await Promise.all(Array.from({ length: 5 }, () => request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie })));
  assert.ok(responses.every((response) => response.status === 200));
  assert.equal(issued.length, 1);
});

test("failed remote revocation is reported while local login is closed", async (context) => {
  const { request, login } = await fixture(context, { sessions: {
    async issueSession() { return { token: "rts_test", project_id: "project", session_id: "remote", expires_at: new Date(Date.now() + 600_000).toISOString() }; },
    async revokeSession() { throw new Error("offline"); },
  } });
  const signedIn = await login();
  await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie });
  const logout = await request("/auth/logout", { method: "POST", cookie: signedIn.cookie });
  assert.equal(logout.status, 503);
  assert.deepEqual(await logout.json(), { signedOut: true, revoked: false });
  assert.equal((await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie })).status, 401);
});

test("HTTPS login cookies are Secure and neither public configuration nor errors disclose credentials", async (context) => {
  const { request, login } = await fixture(context, { publicOrigin: "https://inbox.example", sessions: {
    async issueSession() { throw new Error("backend-secret-must-stay-private"); }, async revokeSession() {},
  } });
  const signedIn = await login();
  assert.equal(signedIn.response.status, 303);
  assert.ok(signedIn.response.headers.getSetCookie().every((value) => value.includes("; Secure")));
  const config = await (await request("/auth/me", { cookie: signedIn.cookie })).text();
  assert.ok(!config.includes("clientSecret") && !config.includes("backend-secret"));
  const failed = await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie });
  assert.equal(failed.status, 503);
  assert.ok(!(await failed.text()).includes("backend-secret"));
});

test("wrong-origin requests and missing POST Origin cannot use a host cookie", async (context) => {
  const { auth, login, issued } = await fixture(context);
  const signedIn = await login();
  for (const request of [
    new Request("https://attacker.example/auth/me", { headers: { cookie: signedIn.cookie } }),
    new Request(`${origin}/api/fyrlet/session`, { method: "POST", headers: { cookie: signedIn.cookie } }),
    new Request(`${origin}/auth/logout`, { method: "POST", headers: { cookie: signedIn.cookie, origin: "null" } }),
  ]) assert.equal((await auth.handle(request)).status, 403);
  assert.equal(issued.length, 0);
});

test("unknown auth routes are 404 while non-auth routes pass to the web host", async (context) => {
  const { request, issued } = await fixture(context);
  assert.equal(await request("/assets/app.js"), undefined);
  assert.equal((await request("/auth/missing")).status, 404);
  assert.equal((await request("/auth/login?provider=untrusted")).status, 400);
  assert.equal(issued.length, 0);
});

for (const [name, change] of [
  ["duplicate state", (callback) => callback.searchParams.append("state", callback.searchParams.get("state"))],
  ["duplicate code", (callback) => callback.searchParams.append("code", callback.searchParams.get("code"))],
  ["missing code", (callback) => callback.searchParams.delete("code")],
  ["oversized code", (callback) => callback.searchParams.set("code", "x".repeat(4097))],
  ["provider denial", (callback) => callback.searchParams.set("error", "access_denied")],
]) {
  test(`a callback with ${name} cannot create a host session`, async (context) => {
    const { request, issued } = await fixture(context);
    const start = await request("/auth/login");
    const cookie = start.headers.getSetCookie()[0].split(";")[0];
    const callback = oidc.authorization(start.headers.get("location"));
    change(callback);
    const response = await request(`${callback.pathname}${callback.search}`, { cookie });
    assert.equal(response.status, 400);
    assert.equal(response.headers.getSetCookie().length, 0);
    assert.equal(issued.length, 0);
  });
}

test("expired login state is rejected at the five-minute boundary", async (context) => {
  let clock = Date.now();
  const { request, issued } = await fixture(context, { now: () => clock });
  const start = await request("/auth/login");
  const callback = oidc.authorization(start.headers.get("location"));
  clock += 300_000;
  const response = await request(`${callback.pathname}${callback.search}`, { cookie: start.headers.getSetCookie()[0].split(";")[0] });
  assert.equal(response.status, 400);
  assert.equal(issued.length, 0);
});

test("pending login capacity is bounded and expiry frees it", async (context) => {
  let clock = Date.now();
  const { request } = await fixture(context, { now: () => clock });
  for (let index = 0; index < 1000; index++) assert.equal((await request("/auth/login")).status, 303);
  assert.equal((await request("/auth/login")).status, 429);
  clock += 300_000;
  assert.equal((await request("/auth/login")).status, 303);
});

test("an ID token with several audiences requires a matching authorized party", async (context) => {
  const { login, request, issued } = await fixture(context);
  const rejected = await login({ claims: { aud: ["inbox-test", "other-client"] } });
  assert.equal(rejected.response.status, 401);
  const accepted = await login({ claims: { aud: ["inbox-test", "other-client"], azp: "inbox-test" } });
  assert.equal(accepted.response.status, 303);
  assert.equal((await request("/api/fyrlet/session", { method: "POST", cookie: accepted.cookie })).status, 200);
  assert.equal(issued.length, 1);
});

for (const subject of ["", "x".repeat(201)]) {
  test(`a subject with length ${subject.length} is refused before session issuance`, async (context) => {
    const { login, issued } = await fixture(context);
    const result = await login({ subject });
    assert.ok(result.response.status >= 400);
    assert.equal(issued.length, 0);
  });
}

for (const mode of ["signature", "missing token"]) {
  test(`OIDC ${mode} failure never establishes a host login`, async (context) => {
    const { login, issued } = await fixture(context, { fetcher: async (url, init) => {
      const response = await fetch(url, init);
      if (!String(url).endsWith("/token")) return response;
      const body = await response.json();
      if (mode === "signature") {
        const parts = body.id_token.split(".");
        parts[2] = `${parts[2][0] === "A" ? "B" : "A"}${parts[2].slice(1)}`;
        body.id_token = parts.join(".");
      } else delete body.id_token;
      return Response.json(body);
    } });
    const signedIn = await login();
    assert.ok(signedIn.response.status >= 400);
    assert.equal(signedIn.cookie, undefined);
    assert.equal(issued.length, 0);
  });
}

for (const [name, changes] of [
  ["duplicate provider name", { providers: (providers) => [providers[0], providers[0]] }],
  ["no providers", { providers: () => [] }],
  ["too many providers", { providers: (providers) => Array.from({ length: 9 }, (_, index) => ({ ...providers[0], name: `provider${index}` })) }],
  ["invalid provider name", { providers: (providers) => [{ ...providers[0], name: "../untrusted" }] }],
  ["origin path", { publicOrigin: `${origin}/nested` }],
  ["origin credentials", { publicOrigin: "https://user:password@inbox.example" }],
]) {
  test(`invalid configuration: ${name}`, async () => {
    const options = { ...changes, ...(changes.providers ? { providers: changes.providers(oidc.providers) } : {}) };
    await assert.rejects(createAuth({ publicOrigin: origin, endpoint: origin, projectId: "project", providers: oidc.providers, allowLocal: true, sessions: {}, ...options }));
  });
}

for (const [name, changes] of [
  ["missing S256", { code_challenge_methods_supported: ["plain"] }],
  ["unsupported token authentication", { token_endpoint_auth_methods_supported: ["client_secret_post"] }],
  ["non-loopback HTTP token endpoint", { token_endpoint: "http://untrusted.example/token" }],
  ["JWKS credentials", { jwks_uri: "https://user:password@identity.example/jwks" }],
  ["authorization fragment", { authorization_endpoint: "https://identity.example/authorize#unexpected" }],
]) {
  test(`discovery rejects ${name}`, async () => {
    await assert.rejects(createAuth({ publicOrigin: origin, projectId: "project", providers: oidc.providers, allowLocal: true, sessions: {},
      fetcher: async (url, init) => Response.json({ ...await (await fetch(url, init)).json(), ...changes }),
    }));
  });
}

test("failed discovery never starts an authorization flow", async () => {
  await assert.rejects(createAuth({ publicOrigin: origin, projectId: "project", providers: oidc.providers, allowLocal: true, sessions: {},
    fetcher: async () => new Response(null, { status: 503 }),
  }), /discovery failed/);
});

test("confidential clients authenticate the code exchange without exposing their secret", async (context) => {
  const clientSecret = "secret with:/+ characters";
  const authorizations = [];
  const { login, request } = await fixture(context, { providers: [{ ...oidc.providers[0], clientSecret }], fetcher: async (url, init) => {
    if (String(url).endsWith("/token")) authorizations.push(init.headers.authorization);
    return fetch(url, init);
  } });
  const signedIn = await login();
  assert.equal(signedIn.response.status, 303);
  assert.deepEqual(authorizations, [`Basic ${Buffer.from(`${encodeURIComponent("inbox-test")}:${encodeURIComponent(clientSecret)}`).toString("base64")}`]);
  assert.ok(!(await (await request("/auth/me", { cookie: signedIn.cookie })).text()).includes(clientSecret));
});

test("credentials issued for another project are revoked before reaching the browser", async (context) => {
  const revoked = [];
  const { request, login } = await fixture(context, { sessions: {
    async issueSession() { return { token: "rts_wrong_project", project_id: "other", session_id: "wrong-project" }; },
    async revokeSession(identifier) { revoked.push(identifier); },
  } });
  const signedIn = await login();
  const response = await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie });
  assert.equal(response.status, 503);
  assert.deepEqual(revoked, ["wrong-project"]);
  assert.ok(!(await response.text()).includes("rts_wrong_project"));
});

test("failed issuance releases the shared flight so the same login can retry", async (context) => {
  let attempts = 0;
  const { request, login } = await fixture(context, { sessions: {
    async issueSession() {
      if (++attempts === 1) throw new Error("offline");
      return { token: "rts_recovered", project_id: "project", session_id: "recovered", expires_at: new Date(Date.now() + 600_000).toISOString() };
    }, async revokeSession() {},
  } });
  const signedIn = await login();
  assert.equal((await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie })).status, 503);
  const next = await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie });
  assert.equal(next.status, 200);
  assert.equal((await next.json()).token, "rts_recovered");
  assert.equal(attempts, 2);
});

test("concurrent forced refreshes revoke once and issue one replacement", async (context) => {
  const { request, login, issued, revoked } = await fixture(context);
  const signedIn = await login();
  await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie });
  const results = await Promise.all(Array.from({ length: 8 }, () => request("/api/fyrlet/session", {
    method: "POST", cookie: signedIn.cookie, headers: { "x-fyrlet-refresh": "1" },
  })));
  assert.ok(results.every((response) => response.status === 200));
  const tokens = await Promise.all(results.map(async (response) => (await response.json()).token));
  assert.equal(new Set(tokens).size, 1);
  assert.equal(issued.length, 2);
  assert.deepEqual(revoked, ["session-1"]);
});

test("host expiry caps issued credentials and refuses renewal in its final minute", async (context) => {
  let clock = Date.now();
  const { request, login, issued } = await fixture(context, { now: () => clock });
  const signedIn = await login({ claims: { exp: Math.floor(clock / 1000) + 120 } });
  assert.equal((await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie })).status, 200);
  assert.ok(issued[0].ttl_seconds <= 120 && issued[0].ttl_seconds >= 119);
  clock += 61_000;
  const renewed = await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie, headers: { "x-fyrlet-refresh": "1" } });
  assert.equal(renewed.status, 401);
  assert.equal(issued.length, 1);
});

test("expired Fyrlet tokens do not trigger redundant remote revocation on logout", async (context) => {
  const revoked = [];
  const { request, login } = await fixture(context, { sessions: {
    async issueSession() { return { token: "rts_expired", project_id: "project", session_id: "expired", expires_at: new Date(Date.now() - 1000).toISOString() }; },
    async revokeSession(identifier) { revoked.push(identifier); },
  } });
  const signedIn = await login();
  await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie });
  assert.equal((await request("/auth/logout", { method: "POST", cookie: signedIn.cookie })).status, 200);
  assert.deepEqual(revoked, []);
});

test("expired hosts stop serving private data while background revocation is limited to eight", async (context) => {
  let clock = Date.now();
  const release = Promise.withResolvers();
  context.after(() => release.resolve());
  const revoked = [];
  const { request, login } = await fixture(context, { now: () => clock, sessions: {
    async issueSession() { return { token: "rts_test", project_id: "project", session_id: crypto.randomUUID(), expires_at: new Date(clock + 600_000).toISOString() }; },
    async revokeSession(identifier) { revoked.push(identifier); await release.promise; },
  } });
  const cookies = [];
  for (let index = 0; index < 9; index++) {
    const signedIn = await login({ claims: { exp: Math.floor(clock / 1000) + 120 } });
    cookies.push(signedIn.cookie);
    await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie });
  }
  clock += 121_000;
  assert.equal((await (await request("/auth/me", { cookie: cookies[0] })).json()).user, null);
  assert.equal(revoked.length, 8);
  await request("/auth/me");
  assert.equal(revoked.length, 8);
  release.resolve();
  await new Promise((resolve) => setImmediate(resolve));
  await request("/auth/me");
  assert.equal(revoked.length, 9);
});

test("failed background revocation respects retry spacing and keeps the host closed", async (context) => {
  let clock = Date.now();
  let attempts = 0;
  const { request, login } = await fixture(context, { now: () => clock, sessions: {
    async issueSession() { return { token: "rts_test", project_id: "project", session_id: "retry", expires_at: new Date(clock + 600_000).toISOString() }; },
    async revokeSession() { if (++attempts === 1) throw new Error("offline"); },
  } });
  const signedIn = await login({ claims: { exp: Math.floor(clock / 1000) + 120 } });
  await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie });
  clock += 121_000;
  await request("/auth/me");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(attempts, 1);
  clock += 9999;
  assert.equal((await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie })).status, 401);
  assert.equal(attempts, 1);
  clock++;
  await request("/auth/me");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(attempts, 2);
});

test("host session capacity is bounded and expired entries free capacity", { timeout: 30_000 }, async (context) => {
  let clock = Date.now();
  const { request, login, issued } = await fixture(context, { now: () => clock });
  for (let index = 0; index < 1000; index++) {
    const signedIn = await login({ claims: { exp: Math.floor(clock / 1000) + 120 } });
    assert.equal(signedIn.response.status, 303);
  }
  const overflow = await login();
  assert.equal(overflow.response.status, 429);
  assert.equal(overflow.cookie, undefined);
  assert.equal(issued.length, 0);
  clock += 121_000;
  for (let index = 0; index < 126; index++) await request("/auth/me");
  assert.equal((await login()).response.status, 303);
});

test("host shutdown waits for in-flight issuance and revokes the late credential", async (context) => {
  const started = Promise.withResolvers();
  const release = Promise.withResolvers();
  context.after(() => release.resolve());
  const revoked = [];
  const { auth, request, login } = await fixture(context, { sessions: {
    async issueSession() {
      started.resolve();
      await release.promise;
      return { token: "rts_late", project_id: "project", session_id: "late", expires_at: new Date(Date.now() + 600_000).toISOString() };
    }, async revokeSession(identifier) { revoked.push(identifier); },
  } });
  const signedIn = await login();
  const pending = request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie });
  await started.promise;
  const closing = auth.close();
  release.resolve();
  const response = await pending;
  await closing;
  assert.equal(response.status, 401);
  assert.deepEqual(revoked, ["late"]);
  assert.equal((await (await request("/auth/me", { cookie: signedIn.cookie })).json()).user, null);
});

test("a failed rotation revocation issues nothing and a later force refresh can recover", async (context) => {
  let attempts = 0;
  let issued = 0;
  const { request, login } = await fixture(context, { sessions: {
    async issueSession() {
      issued++;
      return { token: `rts_${issued}`, project_id: "project", session_id: `session-${issued}`, expires_at: new Date(Date.now() + 600_000).toISOString() };
    }, async revokeSession() { if (++attempts === 1) throw new Error("revocation unavailable"); },
  } });
  const signedIn = await login();
  await request("/api/fyrlet/session", { method: "POST", cookie: signedIn.cookie });
  const options = { method: "POST", cookie: signedIn.cookie, headers: { "x-fyrlet-refresh": "1" } };
  assert.equal((await request("/api/fyrlet/session", options)).status, 503);
  assert.equal(issued, 1);
  const recovered = await request("/api/fyrlet/session", options);
  assert.equal(recovered.status, 200);
  assert.equal((await recovered.json()).token, "rts_2");
  assert.equal(issued, 2);
  assert.equal(attempts, 2);
});

for (const [name, offset] of [["stale", -601], ["future", 3600]]) {
  test(`an ID token with a ${name} issued-at claim cannot establish a session`, async (context) => {
    const { login, issued } = await fixture(context);
    const signedIn = await login({ claims: { iat: Math.floor(Date.now() / 1000) + offset } });
    assert.ok(signedIn.response.status >= 400);
    assert.equal(signedIn.cookie, undefined);
    assert.equal(issued.length, 0);
  });
}
