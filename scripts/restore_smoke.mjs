import { parseArgs } from "node:util";
import { createRequire } from "node:module";
import { mkdir, open, writeFile, rm } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes } from "node:crypto";
import assert from "node:assert/strict";
import { launch } from "../bench/lib/process.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
export function restoreSource(value) {
  const url = new URL(value);
  if (!["postgres:", "postgresql:"].includes(url.protocol) || !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname) || url.search || url.hash ||
      !/^\/[a-z][a-z0-9_]*(?:_integration|_react|_cluster)$/.test(url.pathname)) throw new TypeError("Restore smoke only reads an explicitly isolated local test database");
  return url;
}

export async function databaseManifest(client) {
  const tables = await client.query("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename");
  const manifest = {};
  for (const { tablename } of tables.rows) {
    const table = `public."${tablename.replaceAll('"', '""')}"`;
    const count = Number((await client.query(`SELECT count(*) FROM ${table}`)).rows[0].count);
    if (count > 100000) throw new Error("Restore smoke table exceeds the local row budget");
    const result = await client.query(`SELECT md5(coalesce(string_agg(fingerprint,'' ORDER BY fingerprint),'')) AS fingerprint FROM (SELECT md5(row_to_json(records)::text) AS fingerprint FROM ${table} records) fingerprints`);
    manifest[tablename] = { rows: count, fingerprint: result.rows[0].fingerprint };
  }
  return manifest;
}

async function main() {
  const { values } = parseArgs({ options: { source: { type: "string" }, out: { type: "string" }, app: { type: "string" } } });
  const application = values.app ?? "inbox";
  if (!["inbox", "notify", "flow", "agent", "chat"].includes(application)) throw new TypeError("Invalid restore application");
  const source = restoreSource(values.source ?? process.env.RESTORE_SOURCE_DATABASE_URL ?? "postgres://postgres:postgres@127.0.0.1:55432/fyrlet_integration");
  const output = resolve(values.out ?? resolve(root, ".local/readiness", `restore-${Date.now()}`));
  await mkdir(output, { recursive: true, mode: 0o700 });
  const report = { startedAt: new Date().toISOString(), status: "running", application, scope: "Local test-database snapshot restore and repeat migration; not a production backup or supported-version upgrade proof", stages: [], databaseRemoved: false };
  const reportPath = resolve(output, "result.json");
  await writeFile(reportPath, JSON.stringify(report, null, 2), { flag: "wx", mode: 0o600 });
  const { Client } = createRequire(new URL("../examples/inbox-react/package.json", import.meta.url))("pg");
  const adminURL = new URL(source); adminURL.pathname = "/postgres";
  const target = new URL(source); target.pathname = `/fyrlet_restore_${Date.now()}_${randomBytes(4).toString("hex")}`;
  const admin = new Client({ connectionString: adminURL.toString(), connectionTimeoutMillis: 5000, query_timeout: 10000 });
  const original = new Client({ connectionString: source.toString(), connectionTimeoutMillis: 5000, query_timeout: 10000 });
  const restored = new Client({ connectionString: target.toString(), connectionTimeoutMillis: 5000, query_timeout: 10000 });
  let created = false;
  let child;
  let interrupted = false;
  const stop = () => { interrupted = true; void child?.stop(); };
  process.once("SIGINT", stop); process.once("SIGTERM", stop);
  async function command(binary, arguments_, environment, stdio) {
    if (interrupted) throw new Error("Restore smoke interrupted");
    const docker = environment.RESTORE_DOCKER === "1";
    const args = docker && ["pg_dump", "pg_restore"].includes(binary)
      ? ["run", "--rm", "-i", "--network", "host", ...["PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGDATABASE", "PGOPTIONS"].flatMap((name) => ["-e", name]), "--entrypoint", binary, "postgres:17", ...arguments_]
      : arguments_;
    child = launch(docker && ["pg_dump", "pg_restore"].includes(binary) ? "docker" : binary, args, { cwd: resolve(root, "examples", application), env: environment, stdio });
    const timeout = setTimeout(() => { void child?.stop(); }, 120000);
    try {
      const result = await child.finished;
      if (result.code !== 0 || interrupted) throw new Error("Restore stage failed; inspect its private log");
    } finally { clearTimeout(timeout); child = undefined; }
  }
  const environment = (url) => ({ ...process.env, PGHOST: url.hostname, PGPORT: url.port || "5432", PGUSER: decodeURIComponent(url.username), PGPASSWORD: decodeURIComponent(url.password), PGDATABASE: url.pathname.slice(1), PGOPTIONS: "" });
  const log = await open(resolve(output, "commands.log"), "wx", 0o600);
  const dump = await open(resolve(output, "snapshot.dump"), "wx", 0o600);
  try {
    await admin.connect(); await original.connect();
    const size = Number((await original.query("SELECT pg_database_size(current_database()) AS bytes")).rows[0].bytes);
    if (size > 512 * 1024 * 1024) throw new Error("Restore source exceeds the local size budget");
    await original.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY");
    const snapshot = (await original.query("SELECT pg_export_snapshot() AS snapshot")).rows[0].snapshot;
    report.manifest = await databaseManifest(original);
    await command("pg_dump", ["--format=custom", "--no-owner", "--no-acl", "--snapshot", snapshot], { ...environment(source), PGOPTIONS: "-c default_transaction_read_only=on" }, ["ignore", dump.fd, log.fd]);
    await original.query("COMMIT"); report.stages.push("consistent-snapshot-dump");
    await admin.query(`CREATE DATABASE "${target.pathname.slice(1)}" TEMPLATE template0`); created = true;
    const input = await open(resolve(output, "snapshot.dump"), "r");
    try { await command("pg_restore", ["--no-owner", "--no-acl", "--exit-on-error", "--dbname", target.pathname.slice(1)], environment(target), [input.fd, log.fd, log.fd]); }
    finally { await input.close(); }
    await restored.connect();
    assert.deepEqual(await databaseManifest(restored), report.manifest); report.stages.push("all-table-facts-preserved");
    for (let attempt = 0; attempt < 2; attempt++) await command("mix", ["fyrlet.migrate", "--quiet"], { ...process.env, MIX_ENV: "dev", DATABASE_URL: target.toString().replace(/^postgres(?:ql)?:/, "ecto:") }, ["ignore", log.fd, log.fd]);
    assert.deepEqual(await databaseManifest(restored), report.manifest); report.stages.push("repeat-migration-no-fact-changes");
    report.status = "passed";
  } catch (error) { report.status = "failed"; report.failure = interrupted ? "Interrupted" : error.message.startsWith("Restore ") ? error.message : "Restore or fact verification failed; inspect private logs"; }
  finally {
    if (child) await child.stop();
    await Promise.allSettled([original.end(), restored.end()]);
    if (created) {
      try { await admin.query(`DROP DATABASE "${target.pathname.slice(1)}" WITH (FORCE)`); report.databaseRemoved = true; }
      catch { report.status = "failed"; report.failure = "Temporary restore database cleanup failed"; report.cleanupDatabase = target.pathname.slice(1); }
    }
    await admin.end().catch(() => {});
    await log.close(); await dump.close(); await rm(resolve(output, "snapshot.dump"), { force: true });
    process.removeListener("SIGINT", stop); process.removeListener("SIGTERM", stop);
    report.finishedAt = new Date().toISOString();
    await writeFile(reportPath, JSON.stringify(report, null, 2) + "\n");
    console.log(`Restore smoke ${report.status}: ${reportPath}`);
    if (report.status !== "passed") process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await main(); } catch { console.error("Restore smoke could not start; check arguments and local prerequisites"); process.exitCode = 1; }
}
