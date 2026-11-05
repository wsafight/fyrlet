# Fyrlet

一个可运行的服务端与 TypeScript SDK 原型：在 Elixir 中定义命名业务操作和订阅，客户端通过类型化调用与实时快照使用数据。参考业务是按项目、用户隔离的个人收件箱。

本期实现项目服务密钥、短期用户会话、事务幂等、Oban 持久化失效通知、确认式快照订阅、断线恢复和契约类型生成。源码尚未作为 Hex 或 npm 包发布；SDK 包标记为 private。

## 项目结构

- `lib/fyrlet/`：服务端业务运行时、鉴权、契约与持久化。
- `lib/fyrlet_web/`：HTTP 与 Phoenix Channels 传输。
- `sdks/typescript/`：当前 TypeScript SDK，本地包名 `@fyrlet/client`。
- `sdks/README.md`：多语言 SDK 的目录约定、共享协议与后续计划。
- `docs/PROTOCOL.md`、`priv/contract.json`：各语言 SDK 共同遵守的协议与业务契约。

Elixir 应用名为 `:fyrlet`，模块前缀为 `Fyrlet` / `FyrletWeb`，管理命令为 `mix fyrlet.*`。为复用现有本地数据，默认数据库仍使用 `realtime_dev` / `realtime_test` / `realtime_integration`；也可通过 `DATABASE_URL` 配置其他名称。已有部署升级后先运行 `mix ecto.migrate`，将持久化通知任务的 worker 和队列名称迁移到 Fyrlet。

## 本地启动

需要 Elixir ≥ 1.18、兼容的 Erlang/OTP、PostgreSQL ≥ 14 和 Node ≥ 22。当前环境验证使用 Elixir 1.20.5 / OTP 29.1.2、PostgreSQL 17.11、Node 24.5.0。版本锁定在 mix.lock 与 sdks/typescript/package-lock.json。

```sh
bash scripts/postgres.sh start
mix setup
mix fyrlet.project --output .local/project.json "My App"
npm --prefix sdks/typescript ci
npm --prefix sdks/typescript run build
mix phx.server
```

默认 HTTP 地址为 `http://127.0.0.1:4000`，项目数据库端口为 55432。另开终端运行示例：

```sh
node sdks/typescript/examples/inbox.mjs
```

示例从忽略目录 `.local/project.json` 读取服务端凭证，并为固定的本地用户交换短期会话。输入文字保存记录，`/quit` 退出。打开两个终端即可观察同一用户的实时更新，也可单次执行：

```sh
node sdks/typescript/examples/inbox.mjs "保存第一条记录"
```

这是运行在可信 Node 环境的验证工具。浏览器端只接收自己的后端签发的用户会话令牌，不能读取项目服务密钥。

已有 PostgreSQL 可以通过 DATABASE_URL 指定连接；也提供 `docker compose up -d`。`.env.example` 是配置参考，应用不会自动读取 `.env`。本地 PostgreSQL 仅绑定 loopback，停止命令为 `bash scripts/postgres.sh stop`。

## 客户端调用

```ts
import { createClient, ApiError } from "@fyrlet/client";
import type { AppContract } from "@fyrlet/client/example-contract";

const client = createClient<AppContract>({
  endpoint: "http://localhost:4000",
  projectId: "项目 UUID",
  getToken: async ({ forceRefresh }) => {
    const response = await fetch("/api/fyrlet-session", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ forceRefresh }),
    });
    if (!response.ok) throw new ApiError({ code: "UNAUTHENTICATED", message: "Sign in to continue" });
    return (await response.json()).token;
  },
});

const recent = client.subscribe("inbox.recent", { limit: 50 });
const stop = recent.onChange((state) => console.log(state.status, state.data));
await client.call("inbox.add", { text: "Hello Phoenix" });
stop();
recent.unsubscribe();
client.close();
```

`/api/fyrlet-session` 是客户业务后端自行实现的登录适配接口。它必须从已验证的登录态取得用户身份，再通过 SDK 的 server 入口交换会话。相关示例与生命周期说明见 [SDK 文档](sdks/typescript/README.md)。本仓库内可直接使用相对路径或本地 package 依赖，以上包名用于展示对外 API。

## 扩展业务

实现 `Fyrlet.Definition` 的 contract / authorize / execute / scope 回调，在 `config/config.exs` 的 definitions 中注册。输入输出契约是校验和类型的唯一来源。写入回调返回结果与受影响 Scope；框架将业务、幂等结果和通知任务放在同一事务。

```sh
mix fyrlet.contract priv/contract.json
npm --prefix sdks/typescript run generate
npm --prefix sdks/typescript run typecheck
```

扩展方式见 [服务端开发](docs/SERVER.md)。私有查询必须在 SQL 层约束 Actor 的 project 与 subject。框架不接受客户端提交任意 SQL、任意表查询或任意 Elixir 代码。

## 验证

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
npm --prefix sdks/typescript test
npm --prefix sdks/typescript run typecheck
bash scripts/integration.sh
```

集成脚本使用独立 realtime_integration 数据库及 4100 端口，创建独立项目，启动和关闭自己的服务进程。它验证真实 HTTP / WebSocket、多设备收敛、16 路相同幂等键并发写入、跨项目隔离、撤销、离线补读与服务重启。可用 INTEGRATION_DATABASE_URL / INTEGRATION_PORT 覆盖连接。凭证和日志位于忽略目录 `.local/integration/`，不会删除已有开发数据。

## 基准测试

```sh
bash scripts/bench.sh --profile smoke
bash scripts/bench.sh --scenario fanout --devices 50 --repeats 3
```

`bench/` 提供多设备、多用户、高频更新、离线恢复、慢客户端和空闲订阅场景。执行器验证最终数据，输出原始延迟样本、负载、应用与数据库资源及 Markdown 报告。Meteor 对照应用与安装、代理配置、测量口径见 [基准测试说明](bench/README.md)。本地 smoke 用于验证测试工具，不代表容量上限或相对其他产品的性能结论。

## 运行边界

- PostgreSQL 是事实来源；订阅发送有界完整快照。默认每 30 秒复核，支持显式刷新；没有增量游标、离线写入或多订阅原子视图。
- 默认每连接 20 个订阅、每页 100 条、每快照 256 KiB；快照最多一份待确认，默认 15 秒确认超时。请求体及 Socket 帧限 64 KiB，数据库语句超时 10 秒。
- 写入幂等窗口 24 小时。部署者可定时执行 `mix fyrlet.prune` 清理过期幂等结果及过期一天以上的会话。外部服务副作用不纳入数据库幂等保证。
- 生产需配置 DATABASE_URL、SECRET_KEY_BASE、ALLOWED_ORIGINS、CORS_ORIGINS，并通过 PHX_SERVER=true 启动 release。TLS、网关限流、项目配额、备份和控制台仍由部署方补齐。
- 本期验证单节点服务与 Node SDK。浏览器示例经过类型检查，尚未做浏览器自动化及移动端真机验收；支持注入 fetch、WebSocket 和随机 ID。
- 已提供操作耗时、订阅查询、快照字节和活跃订阅数 telemetry；完整监控面板和容量压测基线仍待建设，未宣称相对其他框架的性能优势。

产品范围见 [PRD](docs/PRD.md)，凭证边界见 [鉴权设计](docs/AUTH.md)，接口字段见 [协议](docs/PROTOCOL.md)。
