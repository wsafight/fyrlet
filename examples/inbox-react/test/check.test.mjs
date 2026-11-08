import test from "node:test";
import assert from "node:assert/strict";
import { checkDeployment } from "../server/check.mjs";

const environment = { PUBLIC_ORIGIN: "https://app.example", FYRLET_ENDPOINT: "https://api.example", FYRLET_PROJECT_ID: "project",
  FYRLET_SERVICE_KEY: "secret-service-key", OIDC_PROVIDERS: JSON.stringify([{ name: "first", clientId: "client", clientSecret: "secret-client", issuer: "https://id.example" }]) };
const discovery = { issuer: "https://id.example", authorization_endpoint: "https://id.example/authorize",
  token_endpoint: "https://id.example/token", jwks_uri: "https://id.example/keys", code_challenge_methods_supported: ["S256"] };

test("deployment checks name missing configuration without exposing values", async () => {
  const report = await checkDeployment({ FYRLET_SERVICE_KEY: "secret" });
  assert.equal(report.verified, false);
  assert.ok(report.checks[0].variables.includes("OIDC_PROVIDERS"));
  assert.ok(!JSON.stringify(report).includes("secret"));
});

test("deployment checks fail closed for insecure URLs and unshared multi-instance state", async () => {
  for (const changes of [{ PUBLIC_ORIGIN: "http://app.example" }, { FYRLET_ENDPOINT: "https://user:password@api.example" },
    { PUBLIC_ORIGIN: "https://app.example/path" }, { PUBLIC_ORIGIN: "https://app.example/" },
    { HOST_INSTANCES: "2" }, { HOST_INSTANCES: "NaN" }, { ALLOW_INSECURE_OIDC: "1" }]) {
    const report = await checkDeployment({ ...environment, ...changes }, () => { throw new Error("Must not contact services"); });
    assert.equal(report.verified, false);
  }
});

test("deployment checks only fetch discovery and readiness without credentials", async () => {
  const urls = [];
  const report = await checkDeployment(environment, async (url, options) => {
    assert.equal(options.redirect, "error");
    assert.equal(options.headers, undefined);
    urls.push(url);
    return Response.json(url.endsWith("/ready") ? { data: { status: "ready" } } : discovery);
  });
  assert.equal(report.verified, true);
  assert.equal(urls.length, 2);
  assert.ok(report.boundary.includes("no login"));
  assert.ok(!JSON.stringify(report).includes("secret"));
});

test("discovery failures and readiness errors stay unverified and redact error details", async () => {
  const report = await checkDeployment(environment, async () => { throw new Error("secret-network-error"); });
  assert.equal(report.verified, false);
  assert.ok(!JSON.stringify(report).includes("secret-network-error"));
  const unavailable = await checkDeployment(environment, async (url) => url.endsWith("/ready") ? new Response(null, { status: 503 }) : Response.json(discovery));
  assert.equal(unavailable.verified, false);
  const malformed = await checkDeployment({ ...environment, OIDC_PROVIDERS: "invalid-json" }, async () => Response.json({}));
  assert.equal(malformed.verified, false);
});
