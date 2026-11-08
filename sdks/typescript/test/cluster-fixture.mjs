import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer, request } from "node:http";
import { connect } from "node:net";
import { mkdir, open } from "node:fs/promises";
import { once } from "node:events";
import { hostname } from "node:os";
import { setTimeout as delay } from "node:timers/promises";
import { root } from "./server-fixture.mjs";

export async function waitFor(check, timeout = 10_000) {
  const deadline = Date.now() + timeout;
  let failure;
  while (Date.now() < deadline) {
    try { if (await check()) return; } catch (error) { failure = error; }
    await delay(25);
  }
  throw new Error("Cluster condition did not become true", { cause: failure });
}

export async function clusterFixture() {
  const base = Number(process.env.CLUSTER_BASE_PORT ?? 4200);
  const domain = process.env.FYRLET_DOMAIN;
  const suffix = `${process.pid}_${crypto.randomUUID().slice(0, 8)}`;
  const host = hostname().split(".")[0];
  const names = ["a", "b"].map(label => `fyrlet_${label}_${suffix}`);
  const cookie = crypto.randomUUID().replaceAll("-", "");
  const endpoints = [base, base + 1].map(port => `http://127.0.0.1:${port}`);
  const metrics = [base + 2, base + 3].map(port => `http://127.0.0.1:${port}`);
  const reportDirectory = process.env.CLUSTER_REPORT_DIR;
  if (reportDirectory) await mkdir(reportDirectory, { recursive: true, mode: 0o700 });
  const logs = await Promise.all(names.map((name, index) => reportDirectory ?
    open(`${reportDirectory}/${domain}-node-${index}.log`, "wx", 0o600) :
    open(`${root}/.local/integration/${domain}-cluster-${index}.log`, "a", 0o600)));
  const servers = [];
  const sockets = new Set();
  let active = 0;
  const proxy = createServer((incoming, outgoing) => {
    const upstream = request(endpoints[active] + incoming.url, { method: incoming.method, headers: incoming.headers }, response => {
      outgoing.writeHead(response.statusCode, response.headers);
      response.pipe(outgoing);
    });
    upstream.on("error", () => { if (!outgoing.headersSent) outgoing.writeHead(502); outgoing.end(); });
    incoming.pipe(upstream);
  });
  proxy.on("upgrade", (incoming, socket, head) => {
    const upstream = connect(base + active, "127.0.0.1");
    sockets.add(socket);
    socket.on("close", () => { sockets.delete(socket); upstream.destroy(); });
    socket.on("error", () => upstream.destroy());
    upstream.on("error", () => socket.destroy());
    upstream.on("connect", () => {
      const headers = [];
      for (let index = 0; index < incoming.rawHeaders.length; index += 2) headers.push(`${incoming.rawHeaders[index]}: ${incoming.rawHeaders[index + 1]}`);
      upstream.write(`${incoming.method} ${incoming.url} HTTP/1.1\r\n${headers.join("\r\n")}\r\n\r\n`);
      if (head.length) upstream.write(head);
      socket.pipe(upstream).pipe(socket);
    });
  });

  async function runtime(index) {
    const response = await fetch(metrics[index] + "/runtime", { signal: AbortSignal.timeout(2000) });
    assert.equal(response.status, 200);
    return response.json();
  }

  async function startNode(index) {
    servers[index] = spawn("elixir", ["--sname", names[index], "--cookie", cookie, "-S", "mix", "run", "--no-halt", `${root}/scripts/domain_server.exs`], {
      cwd: process.env.INTEGRATION_APP,
      env: { ...process.env, PORT: String(base + index), DOMAIN_PROVIDER_PORT: String(base + 2 + index), FYRLET_CLUSTER_NODES: `${names[1 - index]}@${host}` },
      stdio: ["ignore", logs[index].fd, logs[index].fd],
    });
    await waitFor(async () => {
      if (servers[index].exitCode !== null) throw new Error("Cluster node exited; inspect its log");
      return (await fetch(endpoints[index] + "/health")).ok && (await runtime(index)).node.startsWith(names[index] + "@");
    }, 30_000);
  }

  async function stopNode(index, signal = "SIGTERM") {
    const server = servers[index];
    if (!server || server.exitCode !== null || server.signalCode !== null) return;
    const exited = once(server, "exit");
    server.kill(signal);
    const timeout = setTimeout(() => server.kill("SIGKILL"), 5000);
    try { await exited; } finally { clearTimeout(timeout); }
  }

  async function joined() {
    await waitFor(async () => (await Promise.all([runtime(0), runtime(1)])).every(info => info.connected.length === 1));
  }

  return {
    endpoints, endpoint: `http://127.0.0.1:${base + 4}`, runtime, startNode, stopNode, joined,
    select: index => { active = index; },
    start: async () => {
      await Promise.all([startNode(0), startNode(1)]);
      await joined();
      proxy.listen(base + 4, "127.0.0.1");
      await once(proxy, "listening");
    },
    close: async () => {
      for (const socket of sockets) socket.destroy();
      proxy.closeAllConnections();
      if (proxy.listening) await new Promise(resolve => proxy.close(resolve));
      await Promise.all([stopNode(0), stopNode(1)]);
      await Promise.all(logs.map(log => log.close()));
    },
  };
}
