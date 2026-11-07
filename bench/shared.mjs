import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFile, writeFile, mkdir, open } from "node:fs/promises";
import { once } from "node:events";
import { setTimeout as delay } from "node:timers/promises";
import { createClient } from "../sdks/typescript/dist/index.js";
import { createSessionService } from "../sdks/typescript/dist/server.js";
import { until } from "../sdks/typescript/test/helpers.mjs";

const fanout = Number(process.env.FANOUT ?? 25);
const posts = Number(process.env.POSTS ?? 20);
const rounds = Number(process.env.ROUNDS ?? 3);
if (![fanout, posts, rounds].every(Number.isInteger) || fanout < 1 || fanout > 50 || posts < 1 || posts > 1000 || rounds < 1 || rounds > 10) throw new Error("Use FANOUT=1..50, POSTS=1..1000 and ROUNDS=1..10");
const endpoint = process.env.INTEGRATION_ENDPOINT;
const metrics = `http://127.0.0.1:${process.env.DOMAIN_PROVIDER_PORT}/metrics`;
const [project] = JSON.parse(await readFile(process.env.INTEGRATION_FIXTURES, "utf8"));
const log = await open(".local/integration/shared-bench-server.log", "a");
const server = spawn("mix", ["run", "--no-halt", "../../scripts/domain_server.exs"], { cwd: process.env.INTEGRATION_APP, env: process.env, stdio: ["ignore", log.fd, log.fd] });
const clients = [];
let wireBytes = 0;
class RecordingSocket extends WebSocket {
  constructor(...arguments_) {
    super(...arguments_);
    this.addEventListener("message", (event) => { wireBytes += Buffer.byteLength(String(event.data)); });
  }
}
async function ready() {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    if (server.exitCode !== null) throw new Error("Benchmark server exited; inspect its log");
    try { if ((await fetch(endpoint + "/health")).ok) return; } catch {}
    await delay(50);
  }
  throw new Error("Benchmark server did not become ready");
}
const results = [];
async function readMetrics(path = "", method = "GET") {
  const response = await fetch(metrics + path, { method });
  assert.equal(response.status, 200, `Metrics ${method} ${path} failed`);
  return response.json();
}
try {
  await ready();
  const service = createSessionService({ endpoint, serviceKey: project.service_key });
  for (let index = 0; index < fanout; index++) {
    const session = await service.issueSession({ external_subject: crypto.randomUUID() });
    clients.push(createClient({ endpoint, projectId: project.project_id, getToken: () => session.token, capabilities: { append: 1 }, delta: false, WebSocket: RecordingSocket }));
  }
  for (let round = 0; round < rounds; round++) {
    for (const mode of ["private", "shared", "snapshot", "append"]) {
      const room = await clients[0].call("chat.create", { title: `${mode}-${round}` });
      const reference = { room_id: room.id };
      for (const client of clients.slice(1)) await client.call("chat.join", { code: room.code });
      const messages = mode === "snapshot" || mode === "append";
      if (messages) for (let index = 0; index < 100; index++) await clients[0].call("chat.post", { ...reference, text: `seed-${index}`.padEnd(128, "x") });
      const subscriptions = clients.map((client) => mode === "append" ? client.subscribeAppend("chat.messages", reference) : client.subscribe({ private: "chat.room.private", shared: "chat.room", snapshot: "chat.messages.snapshot" }[mode], reference));
      await until(() => subscriptions.every((subscription) => subscription.getState().status === "ready"), 10_000);
      await delay(100);
      await readMetrics("/reset", "POST");
      wireBytes = 0;
      const latencies = [];
      for (let index = 0; index < posts; index++) {
        const value = `${mode}-${round}-${index}`.padEnd(messages ? 128 : 20, "x");
        const started = performance.now();
        if (messages) await clients[0].call("chat.post", { ...reference, text: value });
        else await clients[0].call("chat.rename", { ...reference, title: value });
        await until(() => subscriptions.every((subscription) => {
          const data = subscription.getState().data;
          return messages ? data?.at(-1)?.text === value : data?.title === value;
        }), 10_000);
        latencies.push(performance.now() - started);
      }
      const counters = await readMetrics();
      assert.ok(counters.db_queries > 0, "Database telemetry must be active");
      if (mode !== "append") {
        assert.ok(counters.view_queries > 0, "View telemetry must be active");
        assert.ok(counters.snapshot_encodes > 0, "Serialization telemetry must be active");
      }
      const bytes = wireBytes;
      let refreshFallbacks = 0;
      if (mode === "append") {
        const sequence = subscriptions[0].getState().seq;
        await subscriptions[0].refresh();
        await until(() => subscriptions[0].getState().seq > sequence);
        refreshFallbacks = (await readMetrics()).fallback_refresh - counters.fallback_refresh;
        assert.equal(refreshFallbacks, 1);
      }
      latencies.sort((left, right) => left - right);
      results.push({ mode, round: round + 1, fanout, posts, payload_bytes: bytes, p50_ms: latencies[Math.floor(latencies.length * 0.5)], p95_ms: latencies[Math.min(latencies.length - 1, Math.floor(latencies.length * 0.95))], ...counters, explicit_refresh_fallbacks: refreshFallbacks });
      for (const subscription of subscriptions) subscription.unsubscribe();
      await delay(50);
    }
  }
  const totalViews = (mode) => results.filter((result) => result.mode === mode).reduce((sum, result) => sum + result.view_queries, 0);
  const totalBytes = (mode) => results.filter((result) => result.mode === mode).reduce((sum, result) => sum + result.payload_bytes, 0);
  const totalEncodes = (mode) => results.filter((result) => result.mode === mode).reduce((sum, result) => sum + result.snapshot_encodes, 0);
  const report = { measured_at: new Date().toISOString(), fanout, posts, rounds, limits: "Single local node, development build, real PostgreSQL/HTTP/WebSocket, 10ms delivery polling; not a capacity claim. view_queries counts view builds; snapshot_encodes counts shared data encoding, excluding per-client envelopes.", shared_view_reduction: 1 - totalViews("shared") / totalViews("private"), shared_encoding_reduction: 1 - totalEncodes("shared") / totalEncodes("private"), append_payload_reduction: 1 - totalBytes("append") / totalBytes("snapshot"), results };
  await mkdir(".local/bench", { recursive: true });
  const filename = `.local/bench/shared-${Date.now()}.json`;
  await writeFile(filename, JSON.stringify(report, null, 2) + "\n");
  console.log(JSON.stringify({ report: filename, shared_view_reduction: report.shared_view_reduction, shared_encoding_reduction: report.shared_encoding_reduction, append_payload_reduction: report.append_payload_reduction, results }, null, 2));
} finally {
  for (const client of clients) client.close();
  if (server.exitCode === null) {
    const exited = once(server, "exit");
    server.kill("SIGTERM");
    const timeout = setTimeout(() => server.kill("SIGKILL"), 5000);
    try { await exited; } finally { clearTimeout(timeout); }
  }
  await log.close();
}
