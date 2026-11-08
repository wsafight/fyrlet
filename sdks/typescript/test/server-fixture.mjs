import { spawn } from "node:child_process";
import { open, mkdir } from "node:fs/promises";
import { once } from "node:events";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";

export const root = fileURLToPath(new URL("../../../", import.meta.url));

export async function serverFixture(name = process.env.FYRLET_DOMAIN, { simulateProvider = true } = {}) {
  await mkdir(`${root}/.local/integration`, { recursive: true });
  const log = await open(`${root}/.local/integration/${name}-server.log`, "a");
  let server;

  async function start() {
    server = spawn("mix", simulateProvider ? ["run", "--no-halt", `${root}/scripts/domain_server.exs`] : ["phx.server"], {
      cwd: process.env.INTEGRATION_APP,
      env: process.env,
      stdio: ["ignore", log.fd, log.fd],
    });
    const deadline = Date.now() + 20_000;
    while (Date.now() < deadline) {
      if (server.exitCode !== null) throw new Error(`${name} server exited; inspect its integration log`);
      try {
        const health = await fetch(`${process.env.INTEGRATION_ENDPOINT}/ready`, { signal: AbortSignal.timeout(1000) });
        if (health.ok && !simulateProvider) return;
        const metrics = await fetch(`http://127.0.0.1:${process.env.DOMAIN_PROVIDER_PORT}/metrics`, { signal: AbortSignal.timeout(1000) });
        if (health.ok && metrics.ok) return;
      } catch {}
      await delay(50);
    }
    throw new Error(`${name} server did not become ready`);
  }

  async function stop() {
    if (!server || server.exitCode !== null) return;
    const exited = once(server, "exit");
    server.kill("SIGTERM");
    const timeout = setTimeout(() => server.kill("SIGKILL"), 5000);
    try { await exited; } finally { clearTimeout(timeout); }
  }

  return { start, stop, close: async () => { await stop(); await log.close(); } };
}
