import { createHash, randomBytes } from "node:crypto";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { createMemoryStore } from "./store.mjs";

const secret = () => randomBytes(32).toString("base64url");
const json = (data, status = 200, headers = {}) => Response.json(data, { status, headers: { "cache-control": "no-store", ...headers } });
const redirect = (location, cookies = []) => {
  const headers = new Headers({ location, "cache-control": "no-store", "referrer-policy": "no-referrer" });
  for (const cookie of cookies) headers.append("set-cookie", cookie);
  return new Response(null, { status: 303, headers });
};
const failure = (status, message) => Object.assign(new Error(message), { status });

function trustedURL(value, allowLocal) {
  const url = new URL(value);
  if (url.username || url.password || url.hash ||
      (url.protocol !== "https:" && !(allowLocal && url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)))) {
    throw new TypeError("OIDC endpoints require HTTPS; local HTTP needs explicit loopback development configuration");
  }
  return url;
}

export async function createAuth({ publicOrigin, endpoint, projectId, providers, sessions, store = createMemoryStore(), allowLocal = false, fetcher = fetch, now = Date.now }) {
  const origin = trustedURL(publicOrigin, allowLocal).origin;
  if (publicOrigin !== origin) throw new TypeError("publicOrigin must be an exact origin without a trailing slash");
  if (!projectId || !Array.isArray(providers) || providers.length < 1 || providers.length > 8) throw new TypeError("Configure a project and 1–8 OIDC providers");
  const cookie = (name, value, age) => `${name}=${value}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${age}${origin.startsWith("https:") ? "; Secure" : ""}`;
  const readCookie = (request, name) => request.headers.get("cookie")?.split(";").map((part) => part.trim()).find((part) => part.startsWith(`${name}=`))?.slice(name.length + 1);
  const configured = new Map();
  for (const provider of providers) {
    if (!/^[a-z][a-z0-9_-]{0,31}$/.test(provider.name) || configured.has(provider.name) || !provider.clientId || typeof provider.issuer !== "string" || provider.issuer.length > 200) throw new TypeError("Invalid OIDC provider configuration");
    trustedURL(provider.issuer, allowLocal);
    const response = await fetcher(`${provider.issuer.replace(/\/$/, "")}/.well-known/openid-configuration`, { signal: AbortSignal.timeout(10_000), redirect: "error" });
    if (!response.ok) throw new Error("OIDC discovery failed");
    const discovery = await response.json();
    if (discovery.issuer !== provider.issuer) throw new Error("OIDC discovery issuer mismatch");
    for (const key of ["authorization_endpoint", "token_endpoint", "jwks_uri"]) trustedURL(discovery[key], allowLocal);
    if (!discovery.code_challenge_methods_supported?.includes("S256")) throw new Error("The OIDC provider must support S256 PKCE");
    const method = provider.clientSecret ? "client_secret_basic" : "none";
    if (discovery.token_endpoint_auth_methods_supported && !discovery.token_endpoint_auth_methods_supported.includes(method)) throw new Error(`The OIDC provider must support ${method}`);
    configured.set(provider.name, { ...provider, discovery, keys: createRemoteJWKSet(new URL(discovery.jwks_uri), { timeoutDuration: 5000 }) });
  }
  try {
    await store.bind({ origin, endpoint, projectId, providers: [...configured.values()].map(({ name, issuer, clientId }) => ({ name, issuer, clientId })).sort((left, right) => left.name.localeCompare(right.name)) });
  } catch (error) { await store.close(); throw error; }
  const cleanup = new Map();
  let cleaning = 0;
  let stopped = false;
  let activeRequests = 0;

  async function revoke(host) {
    host.closed = true;
    if (host.revoking) return host.revoking;
    host.revoking = (async () => {
      if (host.flight) await host.flight.catch(() => {});
      if (host.fyrlet) {
        if (Date.parse(host.fyrlet.expires_at) > now()) await sessions.revokeSession(host.fyrlet.session_id, AbortSignal.timeout(5000));
        host.fyrlet = undefined;
      }
    })();
    try { await host.revoking; } finally { host.revoking = undefined; }
  }

  async function prune() {
    for (const identifier of await store.expired(now(), 8)) {
      const key = typeof identifier === "object" ? identifier.hash : identifier;
      if (cleaning >= 8 || (cleanup.get(key)?.next ?? 0) > now()) continue;
      cleaning++;
      const job = store.withHost(identifier, async (host) => {
        if (host) { await revoke(host); await store.deleteHost(identifier); }
      }).then(() => { cleanup.delete(key); }, () => {}).finally(() => { cleaning--; });
      cleanup.set(key, { next: now() + 10_000, job });
    }
    for (const [key, value] of cleanup) if (value.next <= now() && cleaning === 0) cleanup.delete(key);
  }

  async function current(request) {
    const host = await store.getHost(readCookie(request, "fyrlet_host"));
    if (!host || host.closed || host.expiresAt <= now()) throw failure(401, "请重新登录");
    return host;
  }

  async function token(host, force) {
    if (host.flight) return host.flight;
    if (!force && host.fyrlet && Date.parse(host.fyrlet.expires_at) > now() + 30_000) return host.fyrlet;
    const ttl = Math.min(600, Math.floor((host.expiresAt - now()) / 1000));
    if (host.closed || ttl < 60) throw failure(401, "登录已到期，请重新登录");
    host.flight = (async () => {
      if (host.fyrlet) {
        await sessions.revokeSession(host.fyrlet.session_id, AbortSignal.timeout(5000));
        host.fyrlet = undefined;
      }
      const issued = await sessions.issueSession({ issuer: host.issuer, external_subject: host.subject, ttl_seconds: ttl }, AbortSignal.timeout(5000));
      if (issued.project_id !== projectId) {
        await sessions.revokeSession(issued.session_id, AbortSignal.timeout(5000));
        throw failure(503, "项目配置不一致");
      }
      host.fyrlet = issued;
      let active;
      try { active = !host.closed && await store.isActive(host.identifier, now()) && !stopped; }
      catch (error) {
        host.closed = true;
        await store.markClosed(host.identifier).catch(() => {});
        try { await sessions.revokeSession(issued.session_id, AbortSignal.timeout(5000)); host.fyrlet = undefined; } catch {}
        throw error;
      }
      if (!active) {
        await sessions.revokeSession(issued.session_id, AbortSignal.timeout(5000));
        host.fyrlet = undefined;
        throw failure(401, "请重新登录");
      }
      return issued;
    })();
    try { return await host.flight; } finally { host.flight = undefined; }
  }

  const timer = setInterval(() => { if (!stopped) void prune().catch(() => {}); }, 10_000);
  timer.unref();

  return {
    async handle(request) {
      const url = new URL(request.url);
      if (!url.pathname.startsWith("/auth/") && url.pathname !== "/api/fyrlet/session") return undefined;
      if (url.origin !== origin) return json({ error: "请求来源不正确" }, 403);
      if (request.method === "POST" && request.headers.get("origin") !== origin) return json({ error: "请求来源不正确" }, 403);
      const control = request.method === "POST" && ["/auth/logout", "/auth/revoke"].includes(url.pathname);
      if (activeRequests >= (control ? 72 : 64)) return json({ error: "登录服务繁忙，请稍后重试" }, 503);
      activeRequests++;
      try {
        if (stopped) {
          if (request.method === "GET" && url.pathname === "/auth/me") return json({ user: null, endpoint, projectId, providers: [...configured.values()].map(({ name, label }) => ({ name, label: label || name })) });
          throw failure(503, "登录服务正在关闭");
        }
        await prune();
        if (request.method === "GET" && url.pathname === "/auth/me") {
          let user = null;
          try { const host = await current(request); user = { name: host.name, issuer: host.issuer, revision: host.revision }; } catch (error) { if (error.status !== 401) throw error; }
          return json({ user, endpoint, projectId, providers: [...configured.values()].map(({ name, label }) => ({ name, label: label || name })) });
        }
        if (request.method === "GET" && url.pathname === "/auth/login") {
          const provider = configured.get(url.searchParams.get("provider")) ?? (url.searchParams.has("provider") ? undefined : configured.values().next().value);
          if (!provider) throw failure(400, "未知的登录服务");
          const state = secret();
          const verifier = secret();
          const nonce = secret();
          await store.putPending(state, { provider: provider.name, verifier, nonce, expiresAt: now() + 300_000 }, now());
          const login = new URL(provider.discovery.authorization_endpoint);
          for (const [key, value] of Object.entries({ client_id: provider.clientId, redirect_uri: `${origin}/auth/callback`, response_type: "code", scope: "openid profile", state, nonce,
            code_challenge_method: "S256", code_challenge: createHash("sha256").update(verifier).digest("base64url") })) login.searchParams.set(key, value);
          return redirect(login.toString(), [cookie("fyrlet_login", state, 300)]);
        }
        if (request.method === "GET" && url.pathname === "/auth/callback") {
          const state = url.searchParams.get("state");
          if (!state || state !== readCookie(request, "fyrlet_login") || url.searchParams.getAll("state").length !== 1) throw failure(400, "登录验证失败，请重新登录");
          const attempt = await store.takePending(state, now());
          if (!attempt) throw failure(400, "登录验证失败，请重新登录");
          const code = url.searchParams.get("code");
          if (!code || url.searchParams.getAll("code").length !== 1 || code.length > 4096 || url.searchParams.has("error")) throw failure(400, "登录未完成，请重新登录");
          const { verifier, nonce } = attempt;
          const provider = configured.get(attempt.provider);
          if (!provider) throw failure(400, "登录服务已变更，请重新登录");
          const form = new URLSearchParams({ grant_type: "authorization_code", client_id: provider.clientId, code, redirect_uri: `${origin}/auth/callback`, code_verifier: verifier });
          const headers = { "content-type": "application/x-www-form-urlencoded" };
          if (provider.clientSecret) headers.authorization = `Basic ${Buffer.from(`${encodeURIComponent(provider.clientId)}:${encodeURIComponent(provider.clientSecret)}`).toString("base64")}`;
          const response = await fetcher(provider.discovery.token_endpoint, { method: "POST", headers, body: form, signal: AbortSignal.timeout(10_000), redirect: "error" });
          if (!response.ok) throw failure(401, "登录验证失败，请重新登录");
          const tokens = await response.json();
          const { payload } = await jwtVerify(tokens.id_token, provider.keys, {
            issuer: provider.issuer, audience: provider.clientId, algorithms: ["RS256", "PS256", "ES256", "EdDSA"],
            requiredClaims: ["sub", "exp", "iat"], currentDate: new Date(now()), maxTokenAge: "10m",
          });
          if (payload.nonce !== nonce || typeof payload.sub !== "string" || !payload.sub || payload.sub.length > 200 ||
              (Array.isArray(payload.aud) && payload.aud.length > 1 && payload.azp !== provider.clientId) ||
              (payload.azp !== undefined && payload.azp !== provider.clientId)) throw failure(401, "登录身份不匹配");
          const previous = readCookie(request, "fyrlet_host");
          if (previous) {
            await store.markClosed(previous);
            await store.withHost(previous, async (host) => { if (host) { await revoke(host); await store.deleteHost(previous); } });
          }
          const identifier = secret();
          const name = typeof payload.name === "string" ? payload.name.slice(0, 100) : "随记用户";
          const expiresAt = Math.min(payload.exp * 1000, now() + 3_600_000);
          await store.putHost(identifier, { issuer: provider.issuer, subject: payload.sub, name, revision: secret(), expiresAt, closed: false });
          return redirect("/", [cookie("fyrlet_host", identifier, Math.floor((expiresAt - now()) / 1000)), cookie("fyrlet_login", "", 0)]);
        }
        if (request.method === "POST" && ["/auth/logout", "/auth/revoke"].includes(url.pathname)) {
          const identifier = readCookie(request, "fyrlet_host");
          let status = 200;
          await store.markClosed(identifier);
          try { await store.withHost(identifier ?? "", async (host) => { if (host) { await revoke(host); await store.deleteHost(identifier); } }); } catch { status = 503; }
          return json({ signedOut: true, revoked: status === 200 }, status, { "set-cookie": cookie("fyrlet_host", "", 0) });
        }
        if (request.method === "POST" && url.pathname === "/api/fyrlet/session") {
          if (request.headers.get("content-length") && request.headers.get("content-length") !== "0") throw failure(400, "会话接口不接受客户端身份参数");
          const observed = await current(request);
          const previous = observed.fyrlet?.session_id;
          let session;
          try {
            session = await store.withHost(observed.identifier, async (host) => {
              if (!host || host.closed || host.expiresAt <= now()) throw failure(401, "请重新登录");
              session = await token(host, request.headers.get("x-fyrlet-refresh") === "1" && host.fyrlet?.session_id === previous);
              return session;
            });
          } catch (error) {
            if (session) {
              await store.markClosed(observed.identifier).catch(() => {});
              await sessions.revokeSession(session.session_id, AbortSignal.timeout(5000)).catch(() => {});
            }
            throw error;
          }
          return json({ token: session.token, project_id: session.project_id, expires_at: session.expires_at });
        }
        return json({ error: "接口不存在" }, 404);
      } catch (error) {
        return json({ error: error.status ? error.message : "登录服务暂时不可用，请重试" }, error.status ?? 503);
      } finally { activeRequests--; }
    },
    async close() {
      stopped = true;
      clearInterval(timer);
      if (!store.shared) {
        await Promise.allSettled((await store.expired(Infinity, 1000)).map((identifier) => store.withHost(identifier, revoke)));
      }
      await Promise.allSettled([...cleanup.values()].map((value) => value.job));
      await store.close();
    },
  };
}
