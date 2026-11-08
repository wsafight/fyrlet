import { createServer } from "node:http";
import { createHash, randomUUID } from "node:crypto";
import { once } from "node:events";
import { exportJWK, generateKeyPair, SignJWT } from "jose";

export async function mockOIDC() {
  const { privateKey, publicKey } = await generateKeyPair("ES256");
  const key = { ...await exportJWK(publicKey), kid: "test-key", alg: "ES256", use: "sig" };
  const codes = new Map();
  const forms = new Map();
  let origin;
  function authorization(location, subject = "alice", claims = {}) {
    const url = new URL(location);
    const code = randomUUID();
    codes.set(code, { subject, claims, issuer: `${origin}/${url.pathname.split("/")[1]}`,
      nonce: url.searchParams.get("nonce"), challenge: url.searchParams.get("code_challenge"), audience: url.searchParams.get("client_id"), redirect: url.searchParams.get("redirect_uri") });
    const callback = new URL(url.searchParams.get("redirect_uri"));
    callback.searchParams.set("state", url.searchParams.get("state"));
    callback.searchParams.set("code", code);
    return callback;
  }
  const server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url, origin);
      if (url.pathname.endsWith("/.well-known/openid-configuration")) {
        const issuer = `${origin}/${url.pathname.split("/")[1]}`;
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify({ issuer, authorization_endpoint: `${issuer}/authorize`, token_endpoint: `${origin}/token`, jwks_uri: `${origin}/jwks`,
          code_challenge_methods_supported: ["S256"], token_endpoint_auth_methods_supported: ["none", "client_secret_basic"] }));
      } else if (url.pathname === "/jwks") {
        response.setHeader("content-type", "application/json"); response.end(JSON.stringify({ keys: [key] }));
      } else if (url.pathname === "/token" && request.method === "POST") {
        let body = "";
        for await (const chunk of request) body += chunk;
        const input = new URLSearchParams(body);
        const stored = codes.get(input.get("code"));
        codes.delete(input.get("code"));
        if (!stored || createHash("sha256").update(input.get("code_verifier") || "").digest("base64url") !== stored.challenge ||
            input.get("redirect_uri") !== stored.redirect || input.get("client_id") !== stored.audience) {
          response.writeHead(400); response.end("invalid code"); return;
        }
        const jwt = await new SignJWT({ nonce: stored.nonce, name: stored.subject === "bob" ? "Bob" : "Alice", ...stored.claims })
          .setProtectedHeader({ alg: "ES256", kid: key.kid }).setIssuer(stored.claims.iss || stored.issuer).setSubject(stored.subject)
          .setAudience(stored.claims.aud || stored.audience).setIssuedAt(stored.claims.iat ?? Math.floor(Date.now() / 1000)).setExpirationTime(stored.claims.exp ?? "1h").sign(privateKey);
        response.setHeader("content-type", "application/json"); response.end(JSON.stringify({ id_token: jwt, token_type: "Bearer" }));
      } else if (url.pathname.endsWith("/authorize")) {
        const identifier = randomUUID(); forms.set(identifier, url.toString());
        response.setHeader("content-type", "text/html; charset=utf-8");
        response.end(`<html><body><h1>Test identity provider</h1><form method="POST" action="/approve"><input type="hidden" name="request" value="${identifier}"><button name="user" value="alice">Sign in as Alice</button><button name="user" value="bob">Sign in as Bob</button></form></body></html>`);
      } else if (url.pathname === "/approve" && request.method === "POST") {
        let body = "";
        for await (const chunk of request) body += chunk;
        const input = new URLSearchParams(body);
        const location = forms.get(input.get("request")); forms.delete(input.get("request"));
        if (!location || !["alice", "bob"].includes(input.get("user"))) { response.writeHead(400); response.end(); return; }
        response.writeHead(303, { location: authorization(location, input.get("user")).toString() }); response.end();
      } else { response.writeHead(404); response.end(); }
    } catch { response.writeHead(500); response.end(); }
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  origin = `http://127.0.0.1:${server.address().port}`;
  return {
    origin, authorization,
    providers: ["first", "second"].map((name) => ({ name, label: `Test ${name}`, issuer: `${origin}/${name}`, clientId: "inbox-test" })),
    async close() { server.closeAllConnections(); await new Promise((resolve) => server.close(resolve)); },
  };
}
