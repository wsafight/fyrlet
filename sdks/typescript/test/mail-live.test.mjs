import test, { before, after } from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { setTimeout as delay } from "node:timers/promises";
import { createClient } from "../dist/index.js";
import { createSessionService } from "../dist/server.js";
import { serverFixture, root } from "./server-fixture.mjs";

for (const name of ["RESEND_API_KEY", "MAIL_FROM", "MAIL_TO"]) assert.ok(process.env[name], `${name} is required`);
const seconds = Number(process.env.MAIL_SMOKE_TIMEOUT_SECONDS ?? 180);
assert.ok(Number.isInteger(seconds) && seconds >= 30 && seconds <= 600);
const [project] = JSON.parse(await readFile(process.env.INTEGRATION_FIXTURES, "utf8"));
const endpoint = process.env.INTEGRATION_ENDPOINT;
const server = await serverFixture("notify-live", { simulateProvider: false });
before(server.start);
after(server.close);

test("real email reaches provider-confirmed delivery and completes its Run", { timeout: (seconds + 10) * 1000 }, async () => {
  const service = createSessionService({ endpoint, serviceKey: project.service_key });
  const session = await service.issueSession({ external_subject: crypto.randomUUID(), ttl_seconds: seconds + 60 });
  const client = createClient({ endpoint, projectId: project.project_id, getToken: () => session.token, capabilities: { runs: 1 } });
  const report = { measured_at: new Date().toISOString(), provider: "Resend", status: "started" };
  const started = performance.now();
  try {
    const input = { event_id: crypto.randomUUID(), recipient: process.env.MAIL_TO, title: "Fyrlet 真实投递验收", body: "这是一封通过 Notify Run 和邮件 Effect 发送的验收邮件。" };
    const options = { idempotencyKey: crypto.randomUUID() };
    const first = await client.startRun("notify.send", input, options);
    const repeated = await client.startRun("notify.send", input, options);
    assert.equal(first.run_id, repeated.run_id);
    report.run_id = first.run_id;
    const run = client.subscribeRun(first.run_id);
    const inbox = client.subscribe("notify.inbox", {});
    const deadline = Date.now() + seconds * 1000;
    while (Date.now() < deadline) {
      const state = run.getState();
      if (state.status === "error") throw new Error(state.error?.code ?? "Run subscription failed");
      const status = state.data?.status;
      if (["failed", "cancelled", "expired"].includes(status)) throw new Error(`Email Run ended as ${status}`);
      const notification = inbox.getState().data?.find(item => item.run_id === first.run_id);
      if (status === "completed" && notification?.delivery === "delivered") {
        report.status = "provider_confirmed_delivery";
        report.elapsed_ms = Math.round(performance.now() - started);
        return;
      }
      await delay(250);
    }
    throw new Error("Provider-confirmed delivery timed out; inspect this Run before sending another email");
  } catch (error) {
    report.status = "unverified";
    throw error;
  } finally {
    client.close();
    await mkdir(`${root}/.local/mail-live`, { recursive: true });
    await writeFile(`${root}/.local/mail-live/result.json`, JSON.stringify(report, null, 2) + "\n");
  }
});
