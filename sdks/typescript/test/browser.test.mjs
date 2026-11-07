import test, { before, after } from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { chromium, webkit, devices, expect } from "@playwright/test";
import { createClient } from "../dist/index.js";
import { createSessionService } from "../dist/server.js";
import { serverFixture, root } from "./server-fixture.mjs";

const domain = process.env.FYRLET_DOMAIN;
const endpoint = process.env.INTEGRATION_ENDPOINT;
const [project] = JSON.parse(await readFile(process.env.INTEGRATION_FIXTURES, "utf8"));
const server = await serverFixture(`${domain}-browser`);
const screenshots = `${root}/.local/browser`;
const report = { domain, measured_at: new Date().toISOString(), cases: [], limits: "Headless browsers and emulated mobile viewports; not physical-device testing or pixel-diff regression testing" };
before(async () => { await mkdir(screenshots, { recursive: true }); await server.start(); });
after(async () => {
  await server.close();
  await writeFile(`${screenshots}/${domain}.json`, JSON.stringify(report, null, 2) + "\n");
});

const profiles = [
  { name: "desktop-chromium", engine: chromium, options: { viewport: { width: 1280, height: 900 } } },
  { name: "android-chromium", engine: chromium, options: devices["Pixel 5"] },
  { name: "iphone-webkit", engine: webkit, options: devices["iPhone 13"] },
];

async function user() {
  const service = createSessionService({ endpoint, serviceKey: project.service_key });
  const session = await service.issueSession({ external_subject: crypto.randomUUID() });
  const client = createClient({ endpoint, projectId: project.project_id, getToken: () => session.token, capabilities: { runs: 1, append: 1 } });
  return { session, client };
}

async function login(page, session) {
  await page.goto(endpoint);
  await expect(page.locator("#action-title")).not.toBeEmpty();
  await page.getByLabel("项目 ID", { exact: true }).fill(project.project_id);
  await page.getByLabel("用户会话令牌", { exact: true }).fill(session.token);
  await page.getByRole("button", { name: "连接工作区", exact: true }).click();
  await expect(page.locator("#status")).toHaveText("已连接");
  await expect(page.locator("#token")).toHaveValue("");
}

async function capture(page, name) {
  await expect(page.locator("#error")).toBeEmpty();
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), "The viewport must not scroll horizontally");
  await page.screenshot({ path: `${screenshots}/${domain}-${name}.png`, fullPage: true, mask: [page.locator("#connection")] });
}

for (const profile of profiles) test(`${domain} completes its UI flow on ${profile.name}`, { timeout: 60_000 }, async () => {
  const browser = await profile.engine.launch();
  const context = await browser.newContext(profile.options);
  const page = await context.newPage();
  const errors = [];
  const result = { profile: profile.name, engine: browser.browserType().name(), browser_version: browser.version(), viewport: page.viewportSize(), passed: false };
  report.cases.push(result);
  context.on("page", opened => opened.on("pageerror", error => errors.push(error.message)));
  page.on("pageerror", error => errors.push(error.message));
  let owner;
  let colleague;
  try {
    owner = await user();
    await login(page, owner.session);
    if (domain === "notify") {
      await page.getByLabel("收件邮箱", { exact: true }).fill("recipient@example.com");
      await page.getByLabel("标题", { exact: true }).fill("浏览器通知验收 · " + "release".repeat(20));
      await page.getByLabel("正文", { exact: true }).fill("通过网页提交并观察投递对账。");
      await page.getByRole("button", { name: "创建", exact: true }).click();
      await expect(page.locator("#list .entry small")).toHaveText("delivered", { timeout: 15_000 });
      await expect(page.locator("#detail")).toContainText('"status": "completed"');
    }
    if (domain === "flow") {
      await page.getByLabel("流程名称", { exact: true }).fill(`review-${crypto.randomUUID()}`);
      await page.getByRole("button", { name: "保存并运行", exact: true }).click();
      await expect(page.getByRole("button", { name: "发送信号", exact: true })).toBeVisible();
      await page.getByRole("button", { name: "发送信号", exact: true }).click();
      await expect(page.locator("#detail")).toContainText('"status": "completed"');
      await capture(page, profile.name);
      const invalid = [{ type: "http", name: "invalid", url: "https://example.com", body: "{" }];
      await page.getByLabel("节点 JSON", { exact: true }).fill(JSON.stringify(invalid));
      await page.getByRole("button", { name: "保存并运行", exact: true }).click();
      await expect(page.locator("#error")).toContainText("VALIDATION_FAILED");
      await expect(page.locator("#list .entry")).toHaveCount(1);
    }
    if (domain === "agent") {
      await page.getByLabel("需要审核的文本", { exact: true }).fill("a bounded browser task");
      await page.getByRole("button", { name: "创建", exact: true }).click();
      await page.getByRole("button", { name: "批准", exact: true }).click();
      await expect(page.locator("#list .entry small")).toHaveText("approved");
      await capture(page, profile.name);
      await page.getByRole("button", { name: "创建", exact: true }).click();
      await page.getByRole("button", { name: "拒绝", exact: true }).click();
      await expect(page.locator("#list .entry small")).toContainText(["rejected", "approved"]);
      await page.getByRole("button", { name: "创建", exact: true }).click();
      await page.getByRole("button", { name: "取消运行", exact: true }).click();
      await expect(page.locator("#detail")).toContainText('"status": "cancelled"');
    }
    if (domain === "chat") {
      colleague = await user();
      const peer = await context.newPage();
      await login(peer, colleague.session);
      await page.getByLabel("会话主题", { exact: true }).fill("浏览器协作验收");
      await page.getByRole("button", { name: "创建", exact: true }).click();
      const invitation = page.locator("#controls p").filter({ hasText: "邀请码：" });
      await expect(invitation).toBeVisible();
      const code = (await invitation.textContent()).replace("邀请码：", "");
      await peer.getByLabel("会话邀请码", { exact: true }).fill(code);
      await peer.getByRole("button", { name: "加入", exact: true }).click();
      await expect(peer.getByLabel("消息正文", { exact: true })).toBeVisible();
      await page.getByRole("button", { name: "刷新成员", exact: true }).click();
      await expect(page.getByLabel("负责人", { exact: true }).locator("option")).toHaveCount(2);
      await page.getByLabel("消息正文", { exact: true }).fill("<img src=x onerror=alert(1)>");
      await page.getByRole("button", { name: "发送", exact: true }).click();
      await expect(peer.locator("#detail")).toContainText("<img src=x onerror=alert(1)>");
      await expect(peer.locator("#detail img")).toHaveCount(0);
      const rooms = owner.client.subscribe("chat.rooms", {});
      await expect.poll(() => rooms.getState().data?.length).toBe(1);
      const roomId = rooms.getState().data[0].id;
      rooms.unsubscribe();
      for (let index = 0; index < 105; index++) await owner.client.call("chat.post", { room_id: roomId, text: `历史消息 ${index}` });
      await login(page, owner.session);
      await page.getByRole("button", { name: "打开会话", exact: true }).click();
      await expect(page.locator("#detail > div")).toHaveCount(100);
      await page.getByRole("button", { name: "加载更早消息", exact: true }).click();
      await expect(page.locator("#detail > div")).toHaveCount(106);
      await expect(page.locator("#error")).toContainText("历史起点");
      await page.getByRole("button", { name: "人工接管", exact: true }).click();
      await expect(peer.locator("#detail-title")).toContainText("人工处理中");
      await capture(peer, profile.name);
      await page.getByRole("button", { name: "关闭会话", exact: true }).click();
      await expect(peer.getByRole("button", { name: "发送", exact: true })).toBeDisabled();
      await peer.getByRole("button", { name: "离开会话", exact: true }).click();
      await expect(peer.locator("#detail")).toBeEmpty();
      await expect(peer.locator("#controls")).toBeEmpty();
      await expect(peer.locator("#list .entry")).toHaveCount(0);
    }
    if (domain === "notify") await capture(page, profile.name);
    assert.deepEqual(errors, [], "Browser JavaScript errors must not be swallowed");
    assert.deepEqual(await page.evaluate(() => ({ local: Object.keys(localStorage), session: Object.keys(sessionStorage) })), { local: [], session: [] });
    result.passed = true;
  } catch (error) {
    console.error({ domain, profile: profile.name, javascript: errors, visibleError: await page.locator("#error").textContent() });
    await page.screenshot({ path: `${screenshots}/${domain}-${profile.name}-failed.png`, fullPage: true, mask: [page.locator("#connection")] });
    throw error;
  } finally {
    owner?.client.close();
    colleague?.client.close();
    await browser.close();
  }
});
