import test, { before, after, afterEach } from "node:test";
import assert from "node:assert/strict";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { setTimeout as delay } from "node:timers/promises";
import { createClient } from "../dist/index.js";
import { createSessionService } from "../dist/server.js";
import { clusterFixture, waitFor } from "./cluster-fixture.mjs";
import { root } from "./server-fixture.mjs";

const domain = process.env.FYRLET_DOMAIN;
const [project] = JSON.parse(await readFile(process.env.INTEGRATION_FIXTURES, "utf8"));
const cluster = await clusterFixture();
const clients = [];
let sessionRefreshes = 0;
const report = { domain, measured_at: new Date().toISOString(), topology: "Two named BEAM nodes on one local host, shared PostgreSQL, real HTTP/WebSocket; not a multi-host production capacity claim", checks: [] };
before(cluster.start);
afterEach(() => {
  for (const client of clients.splice(0)) client.close();
});
after(async () => {
  for (const client of clients) client.close();
  await cluster.close();
  await mkdir(`${root}/.local/cluster`, { recursive: true });
  await writeFile(`${root}/.local/cluster/${domain}.json`, JSON.stringify(report, null, 2) + "\n");
});

function clientFor(session, endpoint, issue) {
  const client = createClient({ endpoint, projectId: project.project_id, getToken: async ({ forceRefresh }) => {
    if (forceRefresh && issue) {
      Object.assign(session, await issue());
      sessionRefreshes++;
    }
    return session.token;
  }, capabilities: { runs: 1, append: 1 }, retryDelayMs: () => 50 });
  clients.push(client);
  return client;
}

async function user(endpoint = cluster.endpoint) {
  const service = createSessionService({ endpoint, serviceKey: project.service_key });
  const subject = crypto.randomUUID();
  const issue = () => service.issueSession({ external_subject: subject, ttl_seconds: 900 });
  const session = await issue();
  return { session, client: clientFor(session, endpoint, issue) };
}

async function resources() {
  return Promise.all([0, 1].map(async index => {
    const { node, configured, connected, ...info } = await cluster.runtime(index);
    return { label: `node-${index}`, connected_peers: connected.length, ...info };
  }));
}

if (domain === "chat") {
  test("cross-node shared/append delivery, idempotency, membership revocation and abrupt failover", { timeout: 90_000 }, async () => {
    const owner = await user(cluster.endpoints[0]);
    const colleague = await user(cluster.endpoints[1]);
    const room = await owner.client.call("chat.create", { title: "Cluster conversation" });
    const reference = { room_id: room.id };
    await colleague.client.call("chat.join", { code: room.code });
    const first = owner.client.subscribeAppend("chat.messages", reference);
    const second = colleague.client.subscribeAppend("chat.messages", reference);
    const shared = colleague.client.subscribe("chat.room", reference);
    await waitFor(() => [first, second, shared].every(subscription => subscription.getState().status === "ready"));
    const input = { ...reference, text: "exactly one cross-node commit" };
    const options = { idempotencyKey: crypto.randomUUID() };
    const sameOwner = clientFor(owner.session, cluster.endpoints[1]);
    const responses = await Promise.all([owner.client.call("chat.post", input, options), sameOwner.call("chat.post", input, options)]);
    assert.equal(responses[0].id, responses[1].id);
    await waitFor(() => first.getState().data?.length === 1 && second.getState().data?.length === 1);
    for (let index = 0; index < 20; index++) await (index % 2 ? owner : colleague).client.call("chat.post", { ...reference, text: `across nodes ${index}` });
    await waitFor(() => second.getState().data?.length === 21 && first.getState().data?.length === 21);
    assert.deepEqual(first.getState().data, second.getState().data);
    await owner.client.call("chat.rename", { ...reference, title: "Visible on both nodes" });
    await waitFor(() => shared.getState().data?.title === "Visible on both nodes");
    const remoteColleague = clientFor(colleague.session, cluster.endpoints[0]);
    await remoteColleague.call("chat.leave", reference);
    await waitFor(() => second.getState().status === "error" && shared.getState().status === "error");
    assert.equal(second.getState().data, undefined);
    const routed = clientFor(owner.session, cluster.endpoint);
    const recovered = routed.subscribeAppend("chat.messages", reference);
    await waitFor(() => recovered.getState().status === "ready");
    const generation = recovered.getState().generation;
    cluster.select(1);
    await cluster.stopNode(0, "SIGKILL");
    await waitFor(() => recovered.getState().status === "ready" && recovered.getState().generation !== generation);
    await routed.call("chat.post", { ...reference, text: "after abrupt failover" });
    await waitFor(() => recovered.getState().data?.at(-1)?.text === "after abrupt failover");
    await cluster.startNode(0);
    await cluster.joined();
    cluster.select(0);
    await routed.reconnect();
    await waitFor(() => recovered.getState().status === "ready");
    for (const client of clients) client.close();
    await waitFor(async () => (await resources()).every(info => info.subscriptions === 0 && info.observers === 0), 15_000);
    report.checks.push("cross_node_shared_and_append", "concurrent_idempotency", "remote_membership_revocation", "sigkill_proxy_failover", "node_rejoin", "subscription_cleanup");
    report.after_failover = await resources();
  });

  const seconds = Number(process.env.CLUSTER_SOAK_SECONDS ?? 120);
  const fanout = Number(process.env.CLUSTER_CLIENTS ?? 12);
  assert.ok(Number.isInteger(seconds) && seconds >= 5 && seconds <= 86_400);
  assert.ok(Number.isInteger(fanout) && fanout >= 2 && fanout <= 50);
  test(`bounded windows and persistence during ${seconds}s of cross-node traffic`, { timeout: (seconds + Math.max(60, Math.ceil(seconds / 20))) * 1000 }, async () => {
    const owner = await user(cluster.endpoints[0]);
    const room = await owner.client.call("chat.create", { title: "Cluster soak" });
    const reference = { room_id: room.id };
    const members = [owner];
    for (let index = 1; index < fanout; index++) {
      const member = await user(cluster.endpoints[index % 2]);
      await member.client.call("chat.join", { code: room.code });
      members.push(member);
    }
    const streams = members.map(member => member.client.subscribeAppend("chat.messages", reference));
    await waitFor(() => streams.every(stream => stream.getState().status === "ready"));
    const initial = await resources();
    const samples = [{ seconds: 0, nodes: initial }];
    const refreshesBefore = sessionRefreshes;
    const latencies = [];
    const started = performance.now();
    let writes = 0;
    let reconnects = 0;
    while (performance.now() - started < seconds * 1000) {
      const text = `soak-${writes}`;
      const before = performance.now();
      await members[writes % fanout].client.call("chat.post", { ...reference, text });
      await waitFor(() => streams.every(stream => stream.getState().data?.at(-1)?.text === text));
      for (const stream of streams) {
        const data = stream.getState().data;
        assert.ok(data.length <= 100);
        assert.equal(new Set(data.map(message => message.id)).size, data.length);
      }
      latencies.push(performance.now() - before);
      writes++;
      if (writes % 50 === 0) {
        await members[reconnects % fanout].client.reconnect();
        await waitFor(() => streams.every(stream => stream.getState().status === "ready"));
        reconnects++;
      }
      const elapsed = (performance.now() - started) / 1000;
      if (elapsed - samples.at(-1).seconds >= 10) {
        const nodes = await resources();
        for (const info of nodes) assert.ok(info.reader_entries <= 10_000);
        samples.push({ seconds: elapsed, nodes });
      }
      await delay(25);
    }
    let cursor;
    let expected = writes - 1;
    let historyPages = 0;
    let historyReconnects = 0;
    do {
      const page = await owner.client.call("chat.history", { ...reference, limit: 50, ...(cursor ? { cursor } : {}) });
      for (const message of [...page.items].reverse()) assert.equal(message.text, `soak-${expected--}`);
      cursor = page.next_cursor;
      if (++historyPages % 100 === 0) {
        await owner.client.reconnect();
        historyReconnects++;
      }
    } while (cursor);
    assert.equal(expected, -1);
    const beforeRelease = await resources();
    for (const info of beforeRelease) assert.ok(info.reader_entries <= 10_000);
    samples.push({ seconds: (performance.now() - started) / 1000, nodes: beforeRelease });
    const peak = initial.map((node, index) => Object.fromEntries(Object.entries(node).map(([key, value]) => [key, typeof value === "number" ? Math.max(...samples.map(sample => sample.nodes[index][key])) : value])));
    for (const member of members) member.client.close();
    await waitFor(async () => (await resources()).every(info => info.subscriptions === 0 && info.observers === 0), 15_000);
    await delay(2000);
    const released = await resources();
    assert.ok(released.every(info => info.reader_entries === 0));
    latencies.sort((left, right) => left - right);
    const refreshes = sessionRefreshes - refreshesBefore;
    assert.ok(refreshes >= reconnects + historyReconnects);
    report.soak = { seconds, clients: fanout, writes, reconnects, history_reconnects: historyReconnects, session_refreshes: refreshes, p50_ms: latencies[Math.floor(latencies.length * 0.5)], p95_ms: latencies[Math.floor(latencies.length * 0.95)], initial, peak, released, samples };
    report.checks.push("bounded_append_windows", "full_history_no_gaps_or_duplicates", "repeated_reconnects", "session_renewal", "reader_cache_cleanup");
  });
}

if (domain === "agent") test("cross-node Run idempotency, durable approval and owner isolation survive a worker node loss", { timeout: 60_000 }, async () => {
  const owner = await user(cluster.endpoints[0]);
  const remoteOwner = clientFor(owner.session, cluster.endpoints[1]);
  const other = await user(cluster.endpoints[1]);
  const input = { goal: "one durable cluster task", tool: "word_count" };
  const options = { idempotencyKey: crypto.randomUUID() };
  const starts = await Promise.all([owner.client.startRun("agent.start", input, options), remoteOwner.startRun("agent.start", input, options)]);
  assert.equal(starts[0].run_id, starts[1].run_id);
  const id = starts[0].run_id;
  const run = remoteOwner.subscribeRun(id);
  await waitFor(() => run.getState().data?.status === "waiting");
  const wait = run.getState().data.steps.find(step => step.type === "wait");
  await assert.rejects(other.client.signalRun(id, { wait_id: wait.id, name: "approval", payload: { approved: true } }), { code: "FORBIDDEN" });
  await cluster.stopNode(0, "SIGKILL");
  await remoteOwner.signalRun(id, { wait_id: wait.id, name: "approval", payload: { approved: true } });
  await waitFor(() => run.getState().data?.status === "completed");
  const tasks = remoteOwner.subscribe("agent.tasks", {});
  await waitFor(() => tasks.getState().data?.length === 1);
  assert.equal(tasks.getState().data[0].status, "approved");
  assert.ok(run.getState().data.steps.filter(step => step.type === "step").every(step => step.status === "succeeded"));
  await cluster.startNode(0);
  await cluster.joined();
  const again = await owner.client.startRun("agent.start", input, options);
  assert.equal(again.run_id, id);
  for (const client of clients) client.close();
  await waitFor(async () => (await resources()).every(info => info.subscriptions === 0 && info.observers === 0), 15_000);
  report.checks.push("concurrent_run_idempotency", "cross_node_run_subscription", "owner_signal_isolation", "durable_wait_after_node_loss", "single_task_commit", "node_rejoin");
});
