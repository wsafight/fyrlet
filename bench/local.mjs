import { readFile, mkdir, open, writeFile, chmod, access } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "node:net";
import { randomBytes, randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { configuration, help } from "./lib/config.mjs";
import { launch } from "./lib/process.mjs";
import { until } from "./lib/async.mjs";
import { run } from "./runner.mjs";
import { trafficMeter } from "./lib/transport.mjs";
import { markdown } from "./report.mjs";

const execute = promisify(execFile);
const root = fileURLToPath(new URL("../", import.meta.url));
const children = new Set();
const cancellation = new AbortController();
let interrupted = false;
for (const signal of ["SIGINT", "SIGTERM"]) process.once(signal, () => {
  interrupted = true;
  cancellation.abort();
  for (const child of children) void child.stop();
});

async function available(port) {
  const server = createServer();
  await new Promise((resolveReady, reject) => {
    server.once("error", () => reject(new Error(`Port ${port} is occupied; choose --port`)));
    server.listen(port, "127.0.0.1", resolveReady);
  });
  await new Promise((resolveClosed, reject) => server.close((error) => error ? reject(error) : resolveClosed()));
}

async function main() {
  const config = configuration(process.argv.slice(2));
  if (config.help) { console.log(help); return; }
  if (config.endpoint || config.fixtures) throw new Error("Use bench/runner.mjs to benchmark an externally managed endpoint");
  const runId = `bench-${Date.now()}-${randomUUID().slice(0, 8)}`;
  const output = resolve(config.out ?? resolve(root, ".local/bench", runId));
  const privateRoot = resolve(root, ".local/bench", runId, "private");
  await mkdir(privateRoot, { recursive: true, mode: 0o700 });
  await chmod(privateRoot, 0o700);
  const targets = config.target === "all" ? ["fyrlet", "meteor"] : [config.target];
  const results = [];
  let log;
  let server;
  const command = async (binary, arguments_, env, cwd = root, allowInterrupted = false) => {
    if (interrupted && !allowInterrupted) throw new Error("Benchmark interrupted");
    const handle = launch(binary, arguments_, { cwd, env, stdio: ["ignore", log.fd, log.fd] });
    children.add(handle);
    const timer = setTimeout(() => { void handle.stop(); }, config.startupTimeoutMs);
    try {
      const result = await handle.finished;
      if (result.error || result.code !== 0) throw new Error(`${binary} ${arguments_[0]} failed; inspect the private setup log`);
    } finally { clearTimeout(timer); children.delete(handle); }
  };
  for (const [index, target] of targets.entries()) {
    const port = config.port + index * 100;
    await available(port);
    if (target === "meteor") { await available(port + 1); await available(port + 2); }
    const path = resolve(privateRoot, target);
    await mkdir(path, { recursive: true, mode: 0o700 });
    log = await open(resolve(path, "server.log"), "a", 0o600);
    const fixturePath = resolve(path, "credentials.json");
    const endpoint = `http://127.0.0.1:${port}`;
    const environment = {
      ...process.env, BENCH_RUN_ID: runId, BENCH_FIXTURES: fixturePath,
      BENCH_ROWS: String(config.rows), BENCH_PAYLOAD_BYTES: String(config.payloadBytes),
      BENCH_USERS: String(Math.max(...config.scenarios.map((scenario) => scenario.users))),
      PORT: String(port), PHX_SERVER: "false", MIX_ENV: "prod",
      DATABASE_URL: process.env.BENCH_DATABASE_URL ?? "ecto://postgres:postgres@127.0.0.1:55432/fyrlet_bench",
      SECRET_KEY_BASE: randomBytes(64).toString("base64"), ALLOWED_ORIGINS: "//127.0.0.1,//localhost",
      CORS_ORIGINS: "http://127.0.0.1", BENCH_SECRET: randomBytes(32).toString("hex"),
      BIND_IP: "127.0.0.1", ROOT_URL: endpoint,
    };
    let fixtureCreated = false;
    let databasePid = config.databasePid;
    console.log(`Preparing ${target}; private logs: ${resolve(path, "server.log")}`);
    try {
      const versions = {};
      if (target === "fyrlet") {
        await command("mix", ["compile", "--warnings-as-errors"], environment);
        await command("mix", ["ecto.create", "--quiet"], environment);
        await command("mix", ["ecto.migrate", "--quiet"], environment);
        await command("mix", ["run", "bench/fixtures/seed.exs"], environment);
        fixtureCreated = true;
        const { stdout } = await execute("elixir", ["--version"], { cwd: root });
        versions.elixir = stdout.trim();
        versions.phoenix = (await readFile(resolve(root, "mix.lock"), "utf8")).match(/"phoenix": \{:hex, :phoenix, "([^"]+)"/)?.[1] ?? "unknown";
        try {
          const { stdout: postgres } = await execute("psql", [environment.DATABASE_URL.replace(/^ecto:/, "postgresql:"), "-Atc", "SHOW server_version"], { cwd: root });
          versions.postgresql = postgres.trim();
        } catch { versions.postgresql = "unavailable"; }
        if (!databasePid && !process.env.BENCH_DATABASE_URL) {
          try { databasePid = Number((await readFile(resolve(root, ".local/postgres/postmaster.pid"), "utf8")).split("\n")[0]); } catch {}
        }
        server = launch("mix", ["phx.server"], { cwd: root, env: { ...environment, PHX_SERVER: "true" }, stdio: ["ignore", log.fd, log.fd] });
      } else {
        let binary = process.env.METEOR_BIN;
        if (!binary) {
          const localBinary = resolve(root, ".local/meteor-toolchain/.meteor/meteor");
          try {
            await access(localBinary);
            binary = localBinary;
            environment.METEOR_WAREHOUSE_DIR ??= resolve(root, ".local/meteor-toolchain/.meteor");
          }
          catch { binary = "meteor"; }
        }
        try {
          const { stdout } = await execute(binary, ["--version"], { cwd: resolve(root, "bench/apps/meteor"), env: environment, timeout: config.startupTimeoutMs });
          versions.meteor = stdout.trim();
        } catch { throw new Error("Meteor CLI is unavailable. Install the pinned release or set METEOR_BIN; see bench/README.md"); }
        await command("npm", ["ci", "--ignore-scripts"], environment, resolve(root, "bench/apps/meteor"));
        server = launch(binary, ["run", "--production", "--port", `127.0.0.1:${port}`], {
          cwd: resolve(root, "bench/apps/meteor"), env: environment, stdio: ["ignore", log.fd, log.fd],
        });
      }
      children.add(server);
      await until(async () => {
        if (server.ended || interrupted) throw new Error(`Benchmark server exited; inspect ${resolve(path, "server.log")}`);
        try {
          const response = await fetch(`${endpoint}${target === "fyrlet" ? "/health" : "/__bench/health"}`, { signal: AbortSignal.timeout(1000) });
          if (!response.ok) return false;
          const health = await response.json();
          return target === "fyrlet" ? health.data?.status === "ok" : health.ready === true;
        }
        catch { return false; }
      }, config.startupTimeoutMs, `${target} readiness`);
      if (target === "meteor") {
        const { seed } = await import("./adapters/meteor.mjs");
        const fixture = await seed({ endpoint, secret: environment.BENCH_SECRET, runId, rows: config.rows,
          users: Number(environment.BENCH_USERS), payloadBytes: config.payloadBytes, timeoutMs: config.timeoutMs });
        await writeFile(fixturePath, JSON.stringify(fixture), { mode: 0o600 });
        fixtureCreated = true;
        versions.mongodb = fixture.mongo_version;
        versions.applicationNode = fixture.runtime_node;
        versions.observerConfiguration = fixture.observer_config;
      }
      process.env.BENCH_APPLICATION_MODE = target === "fyrlet" ? "MIX_ENV=prod; mix phx.server" : "meteor run --production; CLI and proxy included";
      process.env.BENCH_VERSIONS = JSON.stringify(versions);
      process.env.BENCH_DATABASE_SHARED = target === "fyrlet" ? "true" : "false";
      process.env.BENCH_TOPOLOGY = "single local application instance; generator and database on the same host; no resource limits";
      const result = await run({ ...config, signal: cancellation.signal, target, endpoint, fixtures: fixturePath, out: resolve(output, target), appPid: server.child.pid, databasePid });
      results.push(result);
    } finally {
      try {
        if (fixtureCreated && !config.keepData && target === "meteor" && server && !server.ended) {
          const { cleanup } = await import("./adapters/meteor.mjs");
          await cleanup({ endpoint, secret: environment.BENCH_SECRET, runId, network: trafficMeter(), timeoutMs: config.timeoutMs });
        }
      } finally {
        if (server) { await server.stop(); children.delete(server); server = undefined; }
        try {
          if (fixtureCreated && !config.keepData && target === "fyrlet") {
            await command("mix", ["run", "bench/fixtures/cleanup.exs"], environment, root, true);
          }
        } finally { await log.close(); }
      }
    }
    if (interrupted) throw new Error("Benchmark interrupted");
  }
  await mkdir(output, { recursive: true });
  await writeFile(resolve(output, "comparison.md"), markdown(results));
  console.log(`Report: ${resolve(output, "comparison.md")}`);
}

try { await main(); }
catch (error) { console.error(error.message); process.exitCode = interrupted ? 130 : 1; }
finally { await Promise.all([...children].map((child) => child.stop())); }
