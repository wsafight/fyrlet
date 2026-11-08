import test, { before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFile, mkdir, open } from "node:fs/promises";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { chromium, expect } from "@playwright/test";
import { mockOIDC } from "./oidc-fixture.mjs";
import { serverFixture } from "../../../sdks/typescript/test/server-fixture.mjs";

if (!process.env.INTEGRATION_FIXTURES) throw new Error("Run bash scripts/react.sh");
const root = fileURLToPath(new URL("../../../", import.meta.url));
const endpoint = process.env.INTEGRATION_ENDPOINT;
const webOrigin = `http://127.0.0.1:${process.env.WEB_PORT}`;
let api;
let oidc;
let web;
let log;
let browser;

before(async () => {
  await mkdir(`${root}/.local/integration`, { recursive: true });
  api = await serverFixture("react", { simulateProvider: false });
  await api.start();
  oidc = await mockOIDC();
  const [project] = JSON.parse(await readFile(process.env.INTEGRATION_FIXTURES, "utf8"));
  log = await open(`${root}/.local/integration/react-web.log`, "w");
  web = spawn("node", ["server/index.mjs", "--production"], { cwd: fileURLToPath(new URL("../", import.meta.url)), stdio: ["ignore", log.fd, log.fd],
    env: { ...process.env, PUBLIC_ORIGIN: webOrigin, FYRLET_ENDPOINT: endpoint, FYRLET_PROJECT_ID: project.project_id, FYRLET_SERVICE_KEY: project.service_key,
      OIDC_PROVIDERS: JSON.stringify(oidc.providers), ALLOW_INSECURE_OIDC: "1" } });
  await expect.poll(async () => {
    if (web.exitCode !== null) throw new Error("Web host exited; inspect .local/integration/react-web.log");
    try { return (await fetch(`${webOrigin}/auth/me`)).status; } catch { return 0; }
  }).toBe(200);
  browser = await chromium.launch({ headless: true });
});

after(async () => {
  await browser?.close();
  if (web && web.exitCode === null) {
    const exited = once(web, "exit"); web.kill("SIGTERM");
    const timer = setTimeout(() => web.kill("SIGKILL"), 5000);
    try { await exited; } finally { clearTimeout(timer); }
  }
  await log?.close();
  await oidc?.close();
  await api?.close();
});

test("React Suiji completes shared queries, confirmation, recovery and OIDC identity transitions", async (context) => {
  const session = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  context.after(() => session.close());
  const page = await session.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const joins = [];
  page.on("websocket", (socket) => socket.on("framesent", ({ payload }) => {
    const frame = JSON.parse(payload);
    if (frame[3] === "phx_join" && frame[2].startsWith("subscription:")) joins.push(frame);
  }));
  const message = `Alice note ${crypto.randomUUID()}`;
  async function login(name = "Alice", provider = "first", target = page) {
    await target.getByRole("link", { name: `使用 Test ${provider} 登录` }).click();
    await target.getByRole("button", { name: `Sign in as ${name}` }).click();
    await expect(target.getByRole("status")).toHaveText("实时同步中");
  }
  async function apiReply(route, status, body, extraHeaders = {}) {
    const upstream = await session.request.get(`${endpoint}/health`, { headers: { origin: webOrigin } });
    const corsHeaders = Object.fromEntries(Object.entries(upstream.headers()).filter(([name]) => name.startsWith("access-control-")));
    await route.fulfill({ status, headers: { ...corsHeaders, "content-type": "application/json", ...extraHeaders }, body: JSON.stringify(body) });
  }

  await context.test("the production host serves built assets and rejects source access and unsupported methods", async () => {
    const response = await session.request.get(webOrigin);
    assert.equal(response.status(), 200);
    assert.match(response.headers()["content-type"], /text\/html/);
    const script = (await response.text()).match(/src="(\/assets\/[^"\n]+\.js)"/)[1];
    const asset = await session.request.get(`${webOrigin}${script}`);
    assert.equal(asset.status(), 200);
    assert.match(asset.headers()["content-type"], /javascript/);
    const head = await session.request.head(webOrigin);
    assert.equal(head.status(), 200);
    assert.equal((await head.body()).length, 0);
    assert.equal((await session.request.post(webOrigin)).status(), 405);
    for (const path of ["/.env", "/server/auth.mjs", "/%2e%2e%2fserver%2fauth.mjs", "/%invalid-encoding"]) {
      assert.equal((await session.request.get(`${webOrigin}${path}`)).status(), 404);
    }
  });

  await context.test("login and two React consumers use one active subscription", async () => {
    await page.goto(webOrigin);
    await expect(page).toHaveTitle("随记 · Fyrlet");
    await login();
    await expect(page.getByRole("heading", { name: "随记", exact: true })).toBeVisible();
    await expect(page.getByRole("link", { name: "Fyrlet 随记" })).toBeVisible();
    await expect(page.getByPlaceholder("记下此刻的想法…")).toBeVisible();
    assert.equal(joins.length, 1);
    await expect(page.getByLabel("当前记录数量")).toHaveText("0");
  });

  await context.test("post-commit response loss is recovered with one business request", async () => {
    let writes = 0;
    await page.route(`${endpoint}/api/v1/operations/inbox.add`, async (route) => {
      if (route.request().method() !== "POST") { await route.continue(); return; }
      writes++;
      const response = await route.fetch();
      assert.equal(response.status(), 200);
      await route.abort("failed");
    });
    await page.getByLabel("自动恢复短暂失败").check();
    await page.getByLabel("有什么需要记下来？").fill(message);
    await page.getByRole("button", { name: "记下来" }).click();
    await expect(page.locator(".feedback")).toHaveText("已保存并同步");
    await expect(page.getByRole("listitem").filter({ hasText: message })).toHaveCount(1);
    await expect(page.getByLabel("当前记录数量")).toHaveText("1");
    assert.equal(writes, 1);
    await page.unroute(`${endpoint}/api/v1/operations/inbox.add`);
  });

  await context.test("the browser honours a header-only retry-after on definite rejection", async () => {
    let rejectedAt;
    let attempts = 0;
    const keys = [];
    await page.route(`${endpoint}/api/v1/operations/inbox.add`, async (route) => {
      if (route.request().method() !== "POST") { await route.continue(); return; }
      keys.push(route.request().headers()["idempotency-key"]);
      if (++attempts === 1) {
        rejectedAt = Date.now();
        const upstream = await session.request.get(`${endpoint}/health`, { headers: { origin: webOrigin } });
        const corsHeaders = Object.fromEntries(Object.entries(upstream.headers()).filter(([name]) => name.startsWith("access-control-")));
        assert.ok(corsHeaders["access-control-expose-headers"].split(",").map((name) => name.trim().toLowerCase()).includes("retry-after"));
        await route.fulfill({ status: 429, headers: { ...corsHeaders, "content-type": "application/json", "retry-after": "1" },
          body: JSON.stringify({ error: { code: "LIMIT_EXCEEDED", message: "busy", retryable: true, details: {} } }) });
      } else {
        assert.ok(Date.now() - rejectedAt >= 950);
        await route.continue();
      }
    });
    await page.getByLabel("有什么需要记下来？").fill("retry-after verification");
    await page.getByRole("button", { name: "记下来" }).click();
    await expect(page.locator(".feedback")).toHaveText("已保存并同步");
    assert.equal(attempts, 2);
    assert.equal(keys[0], keys[1]);
    await page.unroute(`${endpoint}/api/v1/operations/inbox.add`);
  });

  await context.test("a definite validation error rolls back the prediction and is never retried", async () => {
    const rejected = `Rejected ${crypto.randomUUID()}`;
    const previousCount = await page.getByLabel("当前记录数量").textContent();
    let attempts = 0;
    await page.route(`${endpoint}/api/v1/operations/inbox.add`, async (route) => {
      if (route.request().method() !== "POST") { await route.continue(); return; }
      attempts++;
      await apiReply(route, 422, { error: { code: "VALIDATION_FAILED", message: "测试：内容未通过验证", retryable: true, details: {} } });
    });
    try {
      await page.getByLabel("有什么需要记下来？").fill(rejected);
      await page.getByRole("button", { name: "记下来" }).click();
      await expect(page.locator(".feedback")).toHaveText("测试：内容未通过验证");
      await expect(page.getByRole("listitem").filter({ hasText: rejected })).toHaveCount(0);
      await expect(page.getByLabel("当前记录数量")).toHaveText(previousCount);
      await expect(page.getByLabel("有什么需要记下来？")).toHaveValue(rejected);
      await expect(page.getByRole("button", { name: "查询保存结果" })).toHaveCount(0);
      assert.equal(attempts, 1);
    } finally { await page.unroute(`${endpoint}/api/v1/operations/inbox.add`); }
  });

  await context.test("exhausted unknown recovery can be resumed manually without another write", async () => {
    const uncertain = `Manual recovery ${crypto.randomUUID()}`;
    let writes = 0;
    let recoveries = 0;
    const keys = [];
    await page.route(`${endpoint}/api/v1/operations/inbox.add`, async (route) => {
      if (route.request().method() !== "POST") { await route.continue(); return; }
      writes++;
      keys.push(route.request().headers()["idempotency-key"]);
      assert.equal((await route.fetch()).status(), 200);
      await route.abort("failed");
    });
    await page.route(`${endpoint}/api/v1/operations/inbox.add/recover`, async (route) => {
      if (route.request().method() !== "POST") { await route.continue(); return; }
      recoveries++;
      keys.push(route.request().headers()["idempotency-key"]);
      await apiReply(route, 200, { outcome: "unknown", data: null });
    });
    try {
      await page.getByLabel("有什么需要记下来？").fill(uncertain);
      await page.getByRole("button", { name: "记下来" }).click();
      await expect(page.locator(".feedback")).toContainText("保存结果暂未确认");
      assert.equal(writes, 1);
      assert.equal(recoveries, 2);
      assert.equal(new Set(keys).size, 1);
      await expect(page.getByLabel("有什么需要记下来？")).toHaveValue(uncertain);
      await page.unroute(`${endpoint}/api/v1/operations/inbox.add/recover`);
      await page.getByRole("button", { name: "查询保存结果" }).click();
      await expect(page.locator(".feedback")).toHaveText("已保存并同步");
      await expect(page.getByLabel("有什么需要记下来？")).toHaveValue("");
      await expect(page.getByRole("listitem").filter({ hasText: uncertain })).toHaveCount(1, { timeout: 7000 });
      assert.equal(writes, 1);
    } finally {
      await page.unroute(`${endpoint}/api/v1/operations/inbox.add`);
      await page.unroute(`${endpoint}/api/v1/operations/inbox.add/recover`);
    }
  });

  const second = await session.newPage();
  await context.test("two browser tabs converge and parameter changes release old queries", async () => {
    await second.goto(webOrigin);
    await expect(second.getByText(message, { exact: true })).toBeVisible();
    await page.getByRole("listitem").filter({ hasText: message }).getByRole("button", { name: "归档", exact: true }).click();
    await expect(page.getByText(message, { exact: true })).toHaveCount(0);
    await expect(second.getByText(message, { exact: true })).toHaveCount(0);
    await page.getByLabel("包含归档").check();
    await page.getByLabel("显示数量").selectOption("50");
    await expect(page.getByText(message, { exact: true })).toBeVisible();
    await page.setViewportSize({ width: 375, height: 812 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);
  });

  await context.test("network reconnect retains a single usable query", async () => {
    await api.stop();
    await expect(page.getByRole("status")).toHaveText("正在重新连接");
    await api.start();
    await expect(page.getByRole("status")).toHaveText("实时同步中");
    await expect(page.getByText(message, { exact: true })).toBeVisible();
  });

  await context.test("a revoked token refreshes against the current host login", async () => {
    const rotated = await session.request.post(`${webOrigin}/api/fyrlet/session`, { headers: { origin: webOrigin, "x-fyrlet-refresh": "1" } });
    assert.equal(rotated.status(), 200);
    await page.getByLabel("有什么需要记下来？").fill("renewed credentials");
    await page.getByRole("button", { name: "记下来" }).click();
    await expect(page.locator(".feedback")).toHaveText("已保存并同步");
  });

  await context.test("logout clears both tabs and revokes the old Fyrlet session", async () => {
    const response = await session.request.post(`${webOrigin}/api/fyrlet/session`, { headers: { origin: webOrigin } });
    const token = (await response.json()).token;
    await page.getByRole("button", { name: "退出 / 切换账号" }).click();
    await expect(page.getByRole("heading", { name: "打开你的随记。" })).toBeVisible();
    await expect(second.getByRole("heading", { name: "打开你的随记。" })).toBeVisible();
    assert.equal(await page.getByText(message, { exact: true }).count(), 0);
    await expect.poll(async () => (await fetch(`${endpoint}/api/v1/identity`, { headers: { authorization: `Bearer ${token}`, "x-project-id": (await (await fetch(`${webOrigin}/auth/me`)).json()).projectId } })).status).toBe(401);
  });

  await context.test("switching users and issuers isolates equal external usernames", async () => {
    await login("Bob");
    await expect(page.getByText(message, { exact: true })).toHaveCount(0);
    await page.getByRole("button", { name: "退出 / 切换账号" }).click();
    await login("Alice");
    await page.getByLabel("包含归档").check();
    await expect(page.getByText(message, { exact: true })).toBeVisible();
    await page.getByRole("button", { name: "退出 / 切换账号" }).click();
    await login("Alice", "second");
    await expect(page.getByText(message, { exact: true })).toHaveCount(0);
    await expect(page.getByLabel("当前记录数量")).toHaveText("0");
  });

  await context.test("host revocation clears the active page on identity revalidation", async () => {
    await session.request.post(`${webOrigin}/auth/revoke`, { headers: { origin: webOrigin } });
    await page.evaluate(() => window.dispatchEvent(new Event("focus")));
    await expect(page.getByRole("heading", { name: "打开你的随记。" })).toBeVisible();
    assert.deepEqual(errors, []);
  });

  await context.test("logout during retry backoff clears private state and prevents another business request", async () => {
    const isolated = await browser.newContext();
    try {
      const target = await isolated.newPage();
      const targetErrors = [];
      target.on("pageerror", (error) => targetErrors.push(error.message));
      await target.goto(webOrigin);
      await login("Alice", "first", target);
      const rejected = Promise.withResolvers();
      let attempts = 0;
      await target.route(`${endpoint}/api/v1/operations/inbox.add`, async (route) => {
        if (route.request().method() !== "POST") { await route.continue(); return; }
        attempts++;
        await apiReply(route, 429, { error: { code: "LIMIT_EXCEEDED", message: "busy", retryable: true, details: {} } }, { "retry-after": "1" });
        rejected.resolve();
      });
      await target.getByLabel("自动恢复短暂失败").check();
      await target.getByLabel("有什么需要记下来？").fill("must not be replayed after logout");
      await target.getByRole("button", { name: "记下来" }).click();
      await rejected.promise;
      const unexpected = target.waitForRequest((request) => request.method() === "POST" && request.url() === `${endpoint}/api/v1/operations/inbox.add`, { timeout: 1250 });
      await target.getByRole("button", { name: "退出 / 切换账号" }).click();
      await expect(target.getByRole("heading", { name: "打开你的随记。" })).toBeVisible();
      await assert.rejects(unexpected, /Timeout/);
      await expect(target.getByRole("listitem")).toHaveCount(0);
      assert.equal(attempts, 1);
      assert.deepEqual(targetErrors, []);
    } finally { await isolated.close(); }
  });
});
