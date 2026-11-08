import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createAuth } from "./auth.mjs";
import { storeConfiguration, storeFromEnvironment } from "./store.mjs";

export async function checkDeployment(environment, fetcher = fetch) {
  const required = ["PUBLIC_ORIGIN", "FYRLET_ENDPOINT", "FYRLET_PROJECT_ID", "FYRLET_SERVICE_KEY", "OIDC_PROVIDERS"];
  const missing = required.filter((name) => !environment[name]);
  if (missing.length) return { verified: false, checks: [{ name: "configuration", status: "missing", variables: missing }] };
  const checks = [];
  for (const name of ["PUBLIC_ORIGIN", "FYRLET_ENDPOINT"]) {
    let valid = false;
    try {
      const url = new URL(environment[name]);
      valid = url.protocol === "https:" && !url.username && !url.password && !url.search && !url.hash && url.pathname === "/" &&
        (name !== "PUBLIC_ORIGIN" || environment[name] === url.origin);
    } catch {}
    checks.push({ name, status: valid ? "passed" : "failed" });
  }
  try { storeConfiguration(environment); checks.push({ name: "session-store-configuration", status: "passed" }); }
  catch { checks.push({ name: "session-store-configuration", status: "failed" }); }
  checks.push({ name: "secure-oidc", status: environment.ALLOW_INSECURE_OIDC === "1" ? "failed" : "passed" });
  if (checks.some((check) => check.status !== "passed")) return { verified: false, checks };
  let auth;
  let store;
  try {
    store = await storeFromEnvironment(environment);
    auth = await createAuth({ publicOrigin: environment.PUBLIC_ORIGIN, endpoint: environment.FYRLET_ENDPOINT,
      projectId: environment.FYRLET_PROJECT_ID, providers: JSON.parse(environment.OIDC_PROVIDERS), sessions: {}, fetcher, store });
    checks.push({ name: "oidc-discovery-and-session-store", status: "passed" });
  } catch {
    checks.push({ name: "oidc-discovery-and-session-store", status: "failed" });
  } finally { if (auth) await auth.close(); else await store?.close(); }
  try {
    const response = await fetcher(`${environment.FYRLET_ENDPOINT.replace(/\/$/, "")}/ready`,
      { redirect: "error", signal: AbortSignal.timeout(5000) });
    const body = response.status === 200 ? await response.json() : undefined;
    checks.push({ name: "database-readiness", status: body?.data?.status === "ready" ? "passed" : "failed" });
  } catch { checks.push({ name: "database-readiness", status: "failed" }); }
  return { verified: checks.every((check) => check.status === "passed"), checks,
    boundary: "Configuration, discovery and storage/schema access only: no login, session issuance, revocation or external IdP acceptance was performed." };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const report = await checkDeployment(process.env);
  console.log(JSON.stringify(report, null, 2));
  if (!report.verified) process.exitCode = 1;
}
