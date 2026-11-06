import test, { before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFile, open } from "node:fs/promises";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { createClient, ApiError } from "../dist/index.js";
import { createSessionService } from "../dist/server.js";
import { until } from "./helpers.mjs";

if (!process.env.INTEGRATION_FIXTURES) throw new Error("Run bash scripts/integration.sh from the repository root");
const projects = JSON.parse(await readFile(process.env.INTEGRATION_FIXTURES, "utf8"));
const endpoint = process.env.INTEGRATION_ENDPOINT;
const root = fileURLToPath(new URL("../../../", import.meta.url));
const services = projects.map((project) => createSessionService({ endpoint, serviceKey: project.service_key }));
const log = await open(new URL("../../../.local/integration/server.log", import.meta.url), "a");
let server;

async function startServer() {
  server = spawn("mix", ["phx.server"], { cwd: root, env: process.env, stdio: ["ignore", log.fd, log.fd] });
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    if (server.exitCode !== null) throw new Error("Integration server exited; inspect .local/integration/server.log");
    try { if ((await fetch(`${endpoint}/health`)).ok) return; } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("Integration server did not start");
}

async function stopServer() {
  if (!server || server.exitCode !== null) return;
  const exited = once(server, "exit");
  server.kill("SIGTERM");
  const timeout = setTimeout(() => server.kill("SIGKILL"), 5000);
  try { await exited; } finally { clearTimeout(timeout); }
}

before(startServer);
after(async () => { await stopServer(); await log.close(); });

async function user(context, project = 0, subject = crypto.randomUUID(), extra = {}) {
  const session = await services[project].issueSession({ external_subject: subject });
  const client = createClient({ endpoint, projectId: projects[project].project_id, getToken: () => session.token, retryDelayMs: () => 50, ...extra });
  context.after(() => client.close());
  return { client, session, subject };
}

test("two SDK devices receive committed snapshots, replay and concurrent duplicate calls", async (context) => {
  const first = await user(context);
  const second = await user(context, 0, first.subject);
  const left = first.client.subscribe("inbox.recent", {});
  const right = second.client.subscribe("inbox.recent", {});
  await until(() => left.getState().status === "ready" && right.getState().status === "ready");
  const key = crypto.randomUUID();
  const item = await first.client.call("inbox.add", { text: "shared" }, { idempotencyKey: key });
  await until(() => left.getState().data?.some((entry) => entry.id === item.id) && right.getState().data?.some((entry) => entry.id === item.id));
  assert.deepEqual(await first.client.call("inbox.add", { text: "shared" }, { idempotencyKey: key }), item);
  await assert.rejects(first.client.call("inbox.add", { text: "changed" }, { idempotencyKey: key }), { code: "CONFLICT", status: 409 });
  const sharedKey = crypto.randomUUID();
  const concurrent = await Promise.all(Array.from({ length: 16 }, () => first.client.call("inbox.add", { text: "concurrent" }, { idempotencyKey: sharedKey })));
  assert.equal(new Set(concurrent.map((entry) => entry.id)).size, 1);
  const history = await first.client.call("inbox.history", {});
  assert.equal(history.items.length, 2);
  const mutations = await Promise.allSettled([
    first.client.call("inbox.update", { id: item.id, text: "left", expected_version: 1 }),
    second.client.call("inbox.update", { id: item.id, text: "right", expected_version: 1 }),
  ]);
  assert.equal(mutations.filter((result) => result.status === "fulfilled").length, 1);
  assert.equal(mutations.filter((result) => result.status === "rejected" && result.reason.code === "CONFLICT").length, 1);
});

test("socket RPC writes produce ordered field deltas and preserve immutable earlier views", async (context) => {
  const frames = [];
  const sent = [];
  class RecordingSocket extends WebSocket {
    constructor(...arguments_) {
      super(...arguments_);
      this.addEventListener("message", (event) => { try { frames.push(JSON.parse(String(event.data))); } catch {} });
    }
    send(data) { sent.push(JSON.parse(String(data))); super.send(data); }
  }
  const writer = await user(context, 0, crypto.randomUUID(), { operationTransport: "socket" });
  const reader = await user(context, 0, writer.subject, { WebSocket: RecordingSocket });
  const items = [];
  for (let index = 0; index < 8; index++) items.push(await writer.client.call("inbox.add", { text: `seed ${index}`.padEnd(128, "x") }));
  const subscription = reader.client.subscribe("inbox.recent", {});
  await until(() => subscription.getState().status === "ready");
  const earlier = subscription.getState().data;
  const item = items[0];
  for (let version = 1; version <= 6; version++) {
    const updated = await writer.client.call("inbox.update", { id: item.id, expected_version: version, text: `version ${version + 1}` });
    await until(() => subscription.getState().data?.some((entry) => entry.id === item.id && entry.version === updated.version));
  }
  assert.equal(earlier.find((entry) => entry.id === item.id).version, 1);
  assert.ok(frames.filter((frame) => frame[3] === "delta").length >= 6);
  assert.ok(frames.filter((frame) => frame[3] === "delta").every((frame) =>
    Object.keys(frame[4]).sort().join(",") === "b,g,p,s" && typeof frame[4].g === "string"));
  const acknowledgements = sent.filter((frame) => frame[3] === "ack");
  assert.ok(acknowledgements.length >= 7);
  assert.ok(acknowledgements.every((frame) => frame[0] === null && frame[1] === null &&
    Object.keys(frame[4]).sort().join(",") === "g,s"));
  assert.equal(frames.filter((frame) => frame[3] === "phx_reply" && frame[1] === null).length, 0);
  const key = crypto.randomUUID();
  const saved = await writer.client.call("inbox.add", { text: "idempotent socket" }, { idempotencyKey: key });
  assert.deepEqual(await writer.client.call("inbox.add", { text: "idempotent socket" }, { idempotencyKey: key }), saved);
  await assert.rejects(writer.client.call("inbox.add", { text: "changed" }, { idempotencyKey: key }), { code: "CONFLICT", status: 409 });
});

test("projects and subjects cannot read or mutate each other's inboxes", async (context) => {
  const first = await user(context);
  const otherUser = await user(context);
  const otherProject = await user(context, 1, first.subject);
  const item = await first.client.call("inbox.add", { text: "private" });
  for (const outsider of [otherUser, otherProject]) {
    const history = await outsider.client.call("inbox.history", {});
    assert.equal(history.items.length, 0);
    await assert.rejects(outsider.client.call("inbox.delete", { id: item.id, expected_version: 1 }), { code: "NOT_FOUND", status: 404 });
    const subscription = outsider.client.subscribe("inbox.recent", {});
    await until(() => subscription.getState().status === "ready");
    assert.deepEqual(subscription.getState().data, []);
  }
  const spoofed = await fetch(`${endpoint}/api/v1/identity`, { headers: { authorization: `Bearer ${first.session.token}`, "x-project-id": projects[1].project_id } });
  assert.equal(spoofed.status, 401);
  await assert.rejects(services[1].revokeSession(first.session.session_id), { code: "NOT_FOUND" });
});

test("one connection multiplexes bounded views and applies batched membership changes", async (context) => {
  const frames = [];
  class RecordingSocket extends WebSocket {
    constructor(...arguments_) {
      super(...arguments_);
      this.addEventListener("message", (event) => frames.push(JSON.parse(String(event.data))));
    }
  }
  const reader = await user(context, 0, crypto.randomUUID(), { WebSocket: RecordingSocket });
  const writer = await user(context, 0, reader.subject, { operationTransport: "socket" });
  for (let index = 0; index < 12; index++) await writer.client.call("inbox.add", { text: `seed ${index}` });
  const subscriptions = Array.from({ length: 12 }, () => reader.client.subscribe("inbox.recent", { limit: 3 }));
  await until(() => subscriptions.every((subscription) => subscription.getState().status === "ready"));
  const original = subscriptions[0].getState().data;
  const item = await writer.client.call("inbox.add", { text: "new visible item" });
  const converge = async () => {
    const expected = (await writer.client.call("inbox.history", { limit: 3 })).items;
    await until(() => subscriptions.every((subscription) => JSON.stringify(subscription.getState().data) === JSON.stringify(expected)));
  };
  await converge();
  await writer.client.call("inbox.archive", { id: item.id, expected_version: 1 });
  await converge();
  await writer.client.call("inbox.archive", { id: item.id, expected_version: 2, archived: false });
  await converge();
  await writer.client.call("inbox.delete", { id: item.id, expected_version: 3 });
  await converge();
  assert.equal(original.length, 3);
  assert.ok(!original.some((record) => record.id === item.id));
  const batches = frames.filter((frame) => frame.batch);
  assert.ok(batches.some((frame) => frame.batch.length > 1));
  assert.ok(batches.every((frame) => frame.batch.length <= 64));
  console.log(`multiplex: ${batches.length} batches carry ${batches.reduce((sum, frame) => sum + frame.batch.length, 0)} channel messages`);
});

test("disconnect, changes while offline and rejoin restore the current full snapshot", async (context) => {
  const connections = [];
  class TrackingWebSocket extends WebSocket {
    constructor(...arguments_) { super(...arguments_); connections.push(this); }
  }
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const reader = await user(context, 0, crypto.randomUUID(), { WebSocket: TrackingWebSocket, getToken: async ({ forceRefresh }) => {
    if (forceRefresh) await gate;
    return reader.session.token;
  } });
  const writer = await user(context, 0, reader.subject);
  const subscription = reader.client.subscribe("inbox.recent", {});
  await until(() => subscription.getState().status === "ready");
  const generation = subscription.getState().generation;
  connections.at(-1).close();
  await until(() => subscription.getState().status === "recovering");
  const item = await writer.client.call("inbox.add", { text: "written offline" });
  release();
  await until(() => subscription.getState().status === "ready" && subscription.getState().data?.some((entry) => entry.id === item.id));
  assert.notEqual(subscription.getState().generation, generation);
  subscription.unsubscribe();
  await until(() => connections.at(-1).readyState === WebSocket.CLOSED);
});

test("session revocation disconnects sockets, clears data and rejects further operations", async (context) => {
  const owner = await user(context);
  await owner.client.call("inbox.add", { text: "before logout" });
  const subscription = owner.client.subscribe("inbox.recent", {});
  await until(() => subscription.getState().status === "ready");
  assert.equal(subscription.getState().data.length, 1);
  await services[0].revokeSession(owner.session.session_id);
  await until(() => subscription.getState().status === "error");
  assert.equal(subscription.getState().data, undefined);
  assert.equal(subscription.getState().error.code, "UNAUTHENTICATED");
  await assert.rejects(owner.client.call("inbox.add", { text: "after logout" }), { code: "UNAUTHENTICATED" });
});

test("the host can refresh a revoked session into the same authenticated subject", async (context) => {
  const subject = crypto.randomUUID();
  let session = await services[0].issueSession({ external_subject: subject });
  let refreshes = 0;
  const client = createClient({ endpoint, projectId: projects[0].project_id, getToken: async ({ forceRefresh }) => {
    if (forceRefresh) { refreshes++; session = await services[0].issueSession({ external_subject: subject }); }
    return session.token;
  } });
  context.after(() => client.close());
  await client.call("inbox.add", { text: "first" });
  await services[0].revokeSession(session.session_id);
  await client.call("inbox.add", { text: "second" });
  assert.equal(refreshes, 1);
  assert.equal((await client.call("inbox.history", {})).items.length, 2);
});

test("archive, history pagination, validation and explicit refresh use the generated contract", async (context) => {
  const owner = await user(context);
  const items = [];
  for (let index = 0; index < 3; index++) items.push(await owner.client.call("inbox.add", { text: `item-${index}` }));
  const first = await owner.client.call("inbox.history", { limit: 2 });
  const next = await owner.client.call("inbox.history", { limit: 2, cursor: first.next_cursor });
  assert.equal(new Set([...first.items, ...next.items].map((item) => item.id)).size, 3);
  assert.equal(next.next_cursor, null);
  await owner.client.call("inbox.archive", { id: items[0].id, expected_version: 1 });
  const subscription = owner.client.subscribe("inbox.recent", {});
  await until(() => subscription.getState().status === "ready");
  assert.equal(subscription.getState().data.length, 2);
  const previous = subscription.getState().seq;
  await subscription.refresh();
  await until(() => subscription.getState().seq > previous);
  await assert.rejects(owner.client.call("inbox.add", { text: "" }), (error) => error instanceof ApiError && error.code === "VALIDATION_FAILED" && Boolean(error.details.fields["$.text"]));
});

test("an application restart preserves PostgreSQL data and SDK subscriptions recover", async (context) => {
  const owner = await user(context);
  const item = await owner.client.call("inbox.add", { text: "survives restart" });
  const subscription = owner.client.subscribe("inbox.recent", {});
  await until(() => subscription.getState().status === "ready");
  const generation = subscription.getState().generation;
  await stopServer();
  await until(() => subscription.getState().status === "recovering");
  await startServer();
  await until(() => subscription.getState().status === "ready" && subscription.getState().generation !== generation, 10_000);
  assert.ok(subscription.getState().data.some((entry) => entry.id === item.id));
});
