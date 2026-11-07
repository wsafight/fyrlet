# 接入第一个实时应用

[English](../TUTORIAL.md) | 简体中文

本教程使用现成的 Inbox 宿主，串起业务定义、生成类型、后端会话接口和浏览器订阅。浏览器示例假设你已有的 Web 应用运行在 `http://localhost:5173`。登录和 POST 路由由宿主应用提供；下面的会话处理器使用标准 `Response`，可适配到你的路由框架。

## 1. 准备并启动宿主

需要 Elixir ≥ 1.18、Erlang/OTP、PostgreSQL ≥ 14 和 Node ≥ 22.23.4。在仓库根目录运行：

```sh
bash scripts/postgres.sh start
mix deps.get
npm --prefix sdks/typescript ci
npm --prefix sdks/typescript run build
cd examples/inbox
mix fyrlet.migrate --create
mix fyrlet.project --output ../../.local/project.json "My App"
ALLOWED_ORIGINS=http://localhost:5173 CORS_ORIGINS=http://localhost:5173 PHX_SERVER=true PORT=4000 mix phx.server
```

宿主默认连接本机 55432 上的 `inbox_example_dev`。覆盖数据库时，迁移、创建项目与启动服务都使用同一个 `DATABASE_URL`。项目命令把 `project_id` 和仅供后端使用的 `service_key` 写入仓库根目录的 `.local/project.json`。命令拒绝覆盖已有文件；若它属于当前数据库则复用，否则为新项目指定另一条输出路径。

根目录 Fyrlet 应用默认未注册业务定义。启动 `examples/inbox` 才会加载参考定义和对应迁移。可以先另开终端，在仓库根目录运行 `node sdks/typescript/examples/inbox.mjs`，输入文字并观察实时窗口，再接入浏览器。

## 2. 定义并注册业务

完整业务在 [`InboxExample.Inbox`](../../examples/inbox/lib/inbox_example/inbox.ex)。`contract` 声明 `inbox.add`、`inbox.update` 和 `inbox.recent` 订阅；`authorize` 决定是否允许进入；`execute` 实现操作；`scope` 标识变更影响的数据。示例在 SQL 中同时约束 project 与 subject，单纯让 `authorize` 返回 `:ok` 并不提供行级隔离。

宿主已在 [`examples/inbox/config/config.exs`](../../examples/inbox/config/config.exs) 注册定义：

```elixir
config :fyrlet,
  definitions: [InboxExample.Inbox],
  migration_paths: [{:inbox_example, "priv/repo/migrations"}]
```

保留该文件的其他配置。接入自己的宿主时，围绕业务模型实现同样的回调，再替换注册模块。依赖自身的配置不会自动加载到宿主，详见[服务端开发](SERVER.md)和[必需配置](INSTALL.md#必需配置)。

## 3. 导出契约并生成类型

在另一终端中，从已配置的宿主导出契约：

```sh
cd examples/inbox
mix fyrlet.contract ../../.local/tutorial-contract.json
```

回到仓库根目录，生成独立的 TypeScript 契约：

```sh
node sdks/typescript/scripts/generate.mjs .local/tutorial-contract.json .local/tutorial-contract.ts
```

将生成文件用作 Web 应用的 `src/contract.ts`，也可以直接把生成器目标改为该路径。模块导出 `AppContract`，服务端契约变化后需要重新生成。在 Web 应用与后端各自的包目录，执行 `npm install /absolute/path/to/fyrlet/sdks/typescript` 安装已构建的 SDK；打包分发见[安装文档](INSTALL.md)。

## 4. 增加后端会话接口

设置 `FYRLET_ENDPOINT=http://127.0.0.1:4000`，并把项目文件的 `service_key` 作为 `FYRLET_SERVICE_KEY` 加载到后端环境。将 POST `/api/fyrlet/session` 路由接到下面的处理器，**先执行宿主自己的登录校验中间件**。传入中间件确认的用户，不能从请求体读取用户 ID；未登录时传入 `null`。

```ts
import { createSessionService } from "@fyrlet/client/server";

const sessions = createSessionService({
  endpoint: process.env.FYRLET_ENDPOINT!,
  serviceKey: process.env.FYRLET_SERVICE_KEY!,
});

export async function issueSessionResponse(user: { id: string } | null): Promise<Response> {
  if (!user) {
    return Response.json({ error: "UNAUTHENTICATED" }, {
      status: 401,
      headers: { "cache-control": "no-store" },
    });
  }
  const session = await sessions.issueSession({
    external_subject: user.id,
    issuer: "my-product",
    ttl_seconds: 600,
  });
  return Response.json({
    token: session.token,
    project_id: session.project_id,
    expires_at: session.expires_at,
  }, { headers: { "cache-control": "no-store" } });
}
```

Fyrlet 无法签发会话时交给路由的正常错误处理机制。使用 Cookie 登录时，为这个 POST 接口应用宿主的 CSRF 防护和同源校验。服务密钥保留在后端，每次换取会话（含刷新）都重新验证登录，只向浏览器返回当前用户的令牌。单会话撤销见 [SDK 指南](../../sdks/typescript/README.zh-CN.md#后端交换会话)。

## 5. 实现浏览器令牌刷新

在 `src/fyrlet.ts` 等浏览器模块中，用项目的 `project_id` 替换 `project UUID`。后端会话接口应位于 Web 应用自己的源下；开发时可用代理把 `/api/fyrlet/session` 转发给后端。

```ts
import { ApiError, createClient } from "@fyrlet/client";
import type { AppContract } from "./contract";

const projectId = "project UUID";
let session: { token: string; project_id: string; expires_at: string } | undefined;

async function getToken({ forceRefresh }: { forceRefresh: boolean }): Promise<string> {
  if (!forceRefresh && session && Date.parse(session.expires_at) > Date.now() + 30_000) {
    return session.token;
  }
  const response = await fetch("/api/fyrlet/session", {
    method: "POST",
    credentials: "same-origin",
    headers: { accept: "application/json" },
  });
  if (response.status === 401) {
    session = undefined;
    throw new ApiError({ code: "UNAUTHENTICATED", message: "Sign in again" }, 401);
  }
  if (!response.ok) {
    throw new ApiError({
      code: "SESSION_ERROR",
      message: "Could not issue a session",
      retryable: response.status >= 500,
    }, response.status);
  }
  const next = await response.json();
  if (!next || typeof next !== "object" || next.project_id !== projectId ||
      typeof next.token !== "string" || !next.token ||
      typeof next.expires_at !== "string" || !Number.isFinite(Date.parse(next.expires_at))) {
    throw new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid session response" });
  }
  session = next;
  return next.token;
}

export const client = createClient<AppContract>({
  endpoint: "http://127.0.0.1:4000",
  projectId,
  getToken,
});
```

宿主的 CSRF 防护可能要求额外发送其 CSRF 令牌头。`forceRefresh` 为 true 时，后端仍须重新验证登录。宿主登录失效应转换为 `UNAUTHENTICATED`，避免把它当作可无限重试的网络错误。Web 源不是 `http://localhost:5173` 时，启动 Fyrlet 要同时修改 `ALLOWED_ORIGINS` 与 `CORS_ORIGINS`，使用准确的协议、主机和端口。

## 6. 订阅并写入

在网页加载应用模块之前加入以下元素：

```html
<form id="inbox-form">
  <label>Message <input name="text" required /></label>
  <button type="submit">Add</button>
</form>
<pre id="inbox" aria-live="polite"></pre>
```

在 `src/main.ts` 中，通过生成契约连接表单：

```ts
import { client } from "./fyrlet";

const output = document.querySelector<HTMLPreElement>("#inbox")!;
const form = document.querySelector<HTMLFormElement>("#inbox-form")!;
const recent = client.subscribe("inbox.recent", { limit: 20 });
recent.onChange((state) => {
  output.textContent = JSON.stringify({
    status: state.status,
    items: state.data,
    error: state.error?.code,
  }, null, 2);
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const text = String(new FormData(form).get("text") ?? "").trim();
  if (!text) return;
  const idempotencyKey = crypto.randomUUID();
  try {
    await client.call("inbox.add", { text }, { idempotencyKey });
    form.reset();
  } catch (error) {
    output.textContent = error instanceof Error ? error.message : String(error);
  }
});

window.addEventListener("pagehide", () => client.close(), { once: true });
```

状态应从 `connecting` 变为 `ready`，成功写入后订阅会更新。在第二个窗口以同一宿主用户登录，可观察两边同步；换另一个用户登录，验证数据隔离。切换账号时先关闭旧客户端，再创建新实例。使用框架时，把订阅和客户端清理绑定到所属组件或应用的生命周期；关闭后的页面恢复时重新创建客户端。

## 7. 扩展前验证失败路径

- 停止并重启 Fyrlet：订阅应通过新的完整快照恢复，未确认写入不会自动重放。
- 退出宿主登录：下一次令牌交换应返回 401，结束恢复并清空私有数据。
- 提交结果未知的写入，只能复用原幂等键和相同输入重试。`CONFLICT` 需要处理版本或键冲突。
- 修改契约后重新生成类型；使用可选 API 前同时启用宿主和客户端对应能力。

排错见[常见问题](TROUBLESHOOTING.md)，生命周期细节见 [SDK 指南](../../sdks/typescript/README.zh-CN.md)，更完整的业务见[示例应用](../../examples/README.zh-CN.md)。生产环境仍需宿主登录、TLS、网关控制和备份；本教程不构成生产容量验证。
