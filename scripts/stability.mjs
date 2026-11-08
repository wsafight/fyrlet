import { parseArgs } from "node:util";
import { createRequire } from "node:module";
import { mkdir, open, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "../bench/lib/process.mjs";
import { acceptanceFingerprint } from "./acceptance.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
export function stabilityConfiguration(arguments_) {
  const { values } = parseArgs({ args: arguments_, options: Object.fromEntries(["seconds", "clients", "sample-ms", "base-port", "out"].map((name) => [name, { type: "string" }])) });
  const integer = (name, fallback, minimum, maximum) => {
    const value = Number(values[name] ?? fallback);
    if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new TypeError(`Invalid ${name}`);
    return value;
  };
  return { seconds: integer("seconds", 86400, 5, 86400), clients: integer("clients", 20, 2, 50), sampleMs: integer("sample-ms", 30000, 1000, 60000),
    basePort: integer("base-port", 4250, 1024, 65530), output: resolve(values.out ?? resolve(root, ".local/readiness", `stability-${Date.now()}`)) };
}

async function main() {
  const config = stabilityConfiguration(process.argv.slice(2));
  if (process.env.CLUSTER_DATABASE_URL) throw new TypeError("This wrapper uses the default isolated chat/agent cluster databases");
  const databaseURL = "postgres://postgres:postgres@127.0.0.1:55432/chat_cluster";
  const url = new URL(databaseURL);
  if (!["postgres:", "postgresql:"].includes(url.protocol) || !["127.0.0.1", "localhost"].includes(url.hostname) || !url.pathname.endsWith("_cluster")) throw new TypeError("Use an isolated local cluster database");
  await mkdir(config.output, { recursive: true, mode: 0o700 });
  const reportPath = resolve(config.output, "result.json");
  const fingerprint = await acceptanceFingerprint(root);
  const report = { startedAt: new Date().toISOString(), status: "running", requestedSeconds: config.seconds, clients: config.clients, sourceFingerprint: fingerprint, startupSamplesUnavailable: 0, sampleFailures: 0, samples: [],
    boundary: "Same-host two-node test, not multi-host faults. No production memory, backlog, pool-wait or table-growth SLO has been selected.", stability24h: "not-verified" };
  await writeFile(reportPath, JSON.stringify(report, null, 2), { flag: "wx", mode: 0o600 });
  const { Pool } = createRequire(new URL("../examples/inbox-react/package.json", import.meta.url))("pg");
  const database = new Pool({ connectionString: databaseURL, max: 1, connectionTimeoutMillis: 2000, query_timeout: 5000, options: "-c default_transaction_read_only=on" });
  database.on("error", () => {});
  const log = await open(resolve(config.output, "cluster.log"), "wx", 0o600);
  let sampling;
  async function sample() {
    if (sampling) return sampling;
    sampling = (async () => {
      try {
        const statistics = await database.query("SELECT pg_database_size(current_database())::text AS database_bytes, (SELECT count(*) FROM sessions)::text AS sessions, (SELECT count(*) FROM idempotency_results)::text AS idempotency_results, (SELECT count(*) FROM oban_jobs)::text AS jobs, (SELECT count(*) FROM fyrlet_runs WHERE status='pending')::text AS pending_runs, (SELECT coalesce(extract(epoch FROM (clock_timestamp()-min(inserted_at))),0) FROM fyrlet_runs WHERE status='pending')::text AS oldest_pending_seconds, (SELECT count(*) FROM fyrlet_effects WHERE resolution_required OR status='unknown')::text AS unresolved_effects, (SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock')::text AS database_lock_waiters");
        report.samples.push({ at: new Date().toISOString(), ...Object.fromEntries(Object.entries(statistics.rows[0]).map(([key, value]) => [key, Number(value)])) });
      } catch { if (report.samples.length) report.sampleFailures++; else report.startupSamplesUnavailable++; }
    })();
    try { await sampling; } finally { sampling = undefined; }
  }
  const child = launch("bash", ["scripts/cluster.sh", "chat", "agent"], { cwd: root, env: { ...process.env, CLUSTER_DATABASE_URL: undefined,
    CLUSTER_SOAK_SECONDS: String(config.seconds), CLUSTER_CLIENTS: String(config.clients), CLUSTER_BASE_PORT: String(config.basePort), CLUSTER_REPORT_DIR: resolve(config.output, "cluster") }, stdio: ["ignore", log.fd, log.fd] });
  let interrupted = false;
  const stop = () => { interrupted = true; void child.stop(); };
  process.once("SIGINT", stop); process.once("SIGTERM", stop);
  const timer = setInterval(() => { void sample(); }, config.sampleMs);
  const timeout = setTimeout(stop, (config.seconds + 600) * 1000);
  try {
    await sample();
    const exited = await child.finished;
    clearInterval(timer);
    if (sampling) await sampling;
    await sample();
    report.chat = JSON.parse(await readFile(resolve(config.output, "cluster/chat.json"), "utf8"));
    report.agent = JSON.parse(await readFile(resolve(config.output, "cluster/agent.json"), "utf8"));
    if (interrupted || exited.code !== 0 || report.chat.soak?.seconds !== config.seconds || report.samples.length < 2 || report.sampleFailures) throw new Error("Stability run incomplete or failed sampling/correctness");
    if ((await acceptanceFingerprint(root)).digest !== fingerprint.digest) throw new Error("Stability sources changed during verification");
    report.status = "passed";
    if (config.seconds === 86400) report.stability24h = "same-host-correctness-run-completed; production-resource-SLO-unverified";
  } catch (error) { report.status = "failed"; report.failure = error.message.startsWith("Stability") ? error.message : "Cluster verification did not complete; inspect private logs"; }
  finally {
    clearInterval(timer); clearTimeout(timeout);
    if (!child.ended) await child.stop();
    if (sampling) await sampling;
    await database.end(); await log.close();
    process.removeListener("SIGINT", stop); process.removeListener("SIGTERM", stop);
    report.finishedAt = new Date().toISOString();
    await writeFile(reportPath, JSON.stringify(report, null, 2) + "\n");
    console.log(`Stability ${report.status}: ${reportPath}`);
    if (report.status !== "passed") process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await main(); } catch { console.error("Stability run could not start; check configuration and local prerequisites"); process.exitCode = 1; }
}
