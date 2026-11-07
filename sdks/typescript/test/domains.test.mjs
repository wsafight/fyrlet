import test, { before, after } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createClient } from "../dist/index.js";
import { createSessionService } from "../dist/server.js";
import { until } from "./helpers.mjs";
import { serverFixture } from "./server-fixture.mjs";

const domain = process.env.FYRLET_DOMAIN;
const endpoint = process.env.INTEGRATION_ENDPOINT;
const projects = JSON.parse(await readFile(process.env.INTEGRATION_FIXTURES, "utf8"));
const server = await serverFixture();
const startServer = server.start;
const stopServer = server.stop;
before(startServer);
after(server.close);
async function user(context, project = 0) {
  const service = createSessionService({ endpoint, serviceKey: projects[project].service_key });
  const session = await service.issueSession({ external_subject: crypto.randomUUID() });
  const client = createClient({ endpoint, projectId: projects[project].project_id, getToken: () => session.token, capabilities: { runs: 1, append: 1 }, retryDelayMs: () => 50 });
  context.after(() => client.close());
  return { client, session };
}
async function waiting(client, id) {
  const subscription = client.subscribeRun(id);
  await until(() => subscription.getState().data?.status === "waiting", 10_000);
  return subscription;
}

test(`${domain} serves its interface and browser SDK without an external CDN`, async () => {
  const page = await fetch(endpoint);
  assert.equal(page.status, 200);
  assert.ok((await page.text()).includes(`data-domain="${domain}"`));
  for (const path of ["/app.js", "/sdk/index.js", "/sdk/client.js", "/sdk/phoenix.mjs"]) {
    const asset = await fetch(endpoint + path);
    assert.equal(asset.status, 200);
    assert.ok(asset.headers.get("content-type").includes("javascript"));
  }
  assert.equal((await fetch(`${endpoint}/sdk/../not-a-file`)).status, 404);
});

if (domain === "notify") test("notification delivery crosses the email adapter, reconciles acceptance and updates the live inbox", async (context) => {
  const owner = await user(context);
  const other = await user(context);
  const inbox = owner.client.subscribe("notify.inbox", {});
  const privateInbox = other.client.subscribe("notify.inbox", {});
  await until(() => inbox.getState().status === "ready" && privateInbox.getState().status === "ready");
  const input = { event_id: crypto.randomUUID(), recipient: "recipient@example.com", title: "Integration notification", body: "Delivered after reconciliation" };
  const started = await owner.client.startRun("notify.send", input);
  const run = owner.client.subscribeRun(started.run_id);
  await until(() => run.getState().data?.status === "completed", 10_000);
  await until(() => inbox.getState().data?.[0]?.delivery === "delivered");
  assert.equal(inbox.getState().data[0].title, input.title);
  assert.deepEqual(privateInbox.getState().data, []);
  const repeated = await owner.client.startRun("notify.send", input);
  assert.equal(repeated.run_id, started.run_id);
  assert.equal(repeated.existing, true);
  const independent = await other.client.startRun("notify.send", input);
  assert.notEqual(independent.run_id, started.run_id);
  assert.equal(run.getState().data.effects[0].status, "succeeded");
});

if (domain === "flow") test("saved flows survive restart and resume HTTP nodes after a durable signal", async (context) => {
  const owner = await user(context);
  const saved = owner.client.subscribe("flow.saved", {});
  await until(() => saved.getState().status === "ready");
  const input = { flow_id: crypto.randomUUID(), nodes: [
    { type: "http", name: "first", url: `http://127.0.0.1:${process.env.DOMAIN_PROVIDER_PORT}/hook`, body: "{}" },
    { type: "wait", name: "approval", signal: "go", timeout_seconds: 3600 },
    { type: "http", name: "last", url: `http://127.0.0.1:${process.env.DOMAIN_PROVIDER_PORT}/hook`, body: "{}" },
  ] };
  await owner.client.call("flow.save", input);
  await owner.client.call("flow.save", input);
  await until(() => saved.getState().data?.length === 1);
  const started = await owner.client.startRun("flow.start", input);
  const run = await waiting(owner.client, started.run_id);
  await assert.rejects(owner.client.startRun("flow.start", input), { code: "CONFLICT" });
  const generation = run.getState().generation;
  await stopServer();
  await startServer();
  await until(() => run.getState().status === "ready" && run.getState().generation !== generation, 10_000);
  const wait = run.getState().data.steps.find((step) => step.type === "wait");
  await owner.client.signalRun(started.run_id, { wait_id: wait.id, name: "ngo", payload: {} });
  await until(() => run.getState().data?.status === "completed", 10_000);
  assert.equal(run.getState().data.effects.length, 2);
  assert.ok(run.getState().data.effects.every((effect) => effect.status === "succeeded"));
});

if (domain === "agent") test("finite tools require the owner's explicit decision and persist rejection", async (context) => {
  const owner = await user(context);
  const other = await user(context);
  await assert.rejects(owner.client.startRun("agent.start", { goal: "text", tool: "shell" }), { code: "VALIDATION_FAILED" });
  const started = await owner.client.startRun("agent.start", { goal: "a bounded text task", tool: "word_count" });
  const run = await waiting(owner.client, started.run_id);
  const wait = run.getState().data.steps.find((step) => step.type === "wait");
  await assert.rejects(other.client.signalRun(started.run_id, { wait_id: wait.id, name: "approval", payload: { approved: true } }), { code: "FORBIDDEN" });
  await owner.client.signalRun(started.run_id, { wait_id: wait.id, name: "approval", payload: { approved: false } });
  await until(() => run.getState().data?.status === "completed", 10_000);
  const tasks = owner.client.subscribe("agent.tasks", {});
  await until(() => tasks.getState().data?.[0]?.status === "rejected");
  assert.equal(JSON.parse(tasks.getState().data[0].result_json).words, 4);
  const privateTasks = other.client.subscribe("agent.tasks", {});
  await until(() => privateTasks.getState().status === "ready");
  assert.deepEqual(privateTasks.getState().data, []);
});

if (domain === "chat") test("invited members share messages and metadata; history, handoff and revocation stay isolated", async (context) => {
  const owner = await user(context);
  const colleague = await user(context);
  const outsider = await user(context, 1);
  const room = await owner.client.call("chat.create", { title: "Support conversation" });
  const reference = { room_id: room.id };
  await assert.rejects(colleague.client.call("chat.get", reference), { code: "FORBIDDEN" });
  await assert.rejects(outsider.client.call("chat.join", { code: room.code }), { code: "NOT_FOUND" });
  await colleague.client.call("chat.join", { code: room.code });
  const first = owner.client.subscribeAppend("chat.messages", reference);
  const second = colleague.client.subscribeAppend("chat.messages", reference);
  const shared = colleague.client.subscribe("chat.room", reference);
  await until(() => first.getState().status === "ready" && second.getState().status === "ready" && shared.getState().status === "ready");
  for (let index = 0; index < 4; index++) await owner.client.call("chat.post", { ...reference, text: `message ${index}` });
  await until(() => first.getState().data?.length === 4 && second.getState().data?.length === 4);
  assert.deepEqual(first.getState().data, second.getState().data);
  const history = await colleague.client.call("chat.history", { ...reference, limit: 2 });
  const older = await colleague.client.call("chat.history", { ...reference, limit: 2, cursor: history.next_cursor });
  assert.equal(new Set([...history.items, ...older.items].map((item) => item.id)).size, 4);
  assert.equal(older.next_cursor, null);
  await colleague.client.call("chat.handoff", reference);
  await until(() => shared.getState().data?.status === "human");
  await colleague.client.call("chat.leave", reference);
  await until(() => second.getState().status === "error" && shared.getState().status === "error");
  assert.equal(second.getState().data, undefined);
  await owner.client.call("chat.close", reference);
  await assert.rejects(owner.client.call("chat.post", { ...reference, text: "late message" }), { code: "CONFLICT" });
});
