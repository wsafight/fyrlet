# Fyrlet

基于 Phoenix 的实时应用框架：在 Elixir 中定义命名的业务操作和订阅，客户端通过类型化调用和实时视图使用数据。写入在一个事务里完成业务、幂等和失效通知；订阅按用户授权，断线后自动恢复。

- **契约驱动**：同一份契约用于校验、导出，并生成 TypeScript 类型。
- **项目与用户隔离**：服务密钥换取短期用户令牌，会话与授权在每次推送前复核。
- **可靠写入**：事务、幂等键、Oban 持久化的失效通知。
- **实时订阅**：完整快照加 ACK，可协商字段级增量，断线后取回当前快照。
- **可选能力**：持久 Run 与 Effect、追加订阅、共享订阅、在线状态、插件、项目配额、Prometheus 指标。

状态：已验证单节点、Node SDK、四个领域应用和同机双节点；**尚未发布到 Hex / npm**，生产容量未验证（见[验收记录](docs/ACCEPTANCE.md)）。

文档入口：[文档索引](docs/README.md) · [安装](docs/INSTALL.md) · [服务端开发](docs/SERVER.md) · [协议](docs/PROTOCOL.md) · [TypeScript SDK](sdks/typescript/README.md) · [产品文档](docs/PRODUCT.md) · [运维](docs/OPERATIONS.md) · [示例应用](examples/README.md)

## 快速开始

需要 Elixir ≥ 1.18、Erlang/OTP、PostgreSQL ≥ 14 和 Node ≥ 22（在 Elixir 1.20.5 / OTP 29、PostgreSQL 17、Node 24 上验证）。

```sh
bash scripts/postgres.sh start                              # 本地 PostgreSQL，端口 55432
mix setup
mix fyrlet.project --output .local/project.json "My App"    # 创建项目与服务密钥
npm --prefix sdks/typescript ci && npm --prefix sdks/typescript run build
mix phx.server                                              # http://127.0.0.1:4000
```

另开终端运行 Node 示例，输入文字保存收件箱记录；再开一个终端可观察多设备实时更新：

```sh
node sdks/typescript/examples/inbox.mjs                     # 交互，/quit 退出
node sdks/typescript/examples/inbox.mjs "保存第一条记录"      # 单次执行
```

示例从被忽略的 `.local/project.json` 读取服务端凭证并交换短期会话，只用于可信 Node 环境；浏览器端只会拿到后端签发的用户令牌。已有 PostgreSQL 用 `DATABASE_URL` 指定，`.env.example` 仅作配置参考。网页聊天等领域应用的启动步骤见 [examples/](examples/README.md)。

## 客户端调用

```ts
import { createClient } from "@fyrlet/client";
import type { AppContract } from "@fyrlet/client/example-contract";

const client = createClient<AppContract>({
  endpoint: "http://localhost:4000",
  projectId: "项目 UUID",
  getToken: async ({ forceRefresh }) => fetchSessionTokenFromYourBackend(forceRefresh),
});

const recent = client.subscribe("inbox.recent", { limit: 50 });
recent.onChange((state) => console.log(state.status, state.data));
await client.call("inbox.add", { text: "Hello Phoenix" });
client.close();
```

`getToken` 由你的后端实现：从已验证的登录态取得用户身份，再通过 SDK 的 server 入口交换会话。订阅状态、重连、乐观写入、在线状态见 [SDK 文档](sdks/typescript/README.md)。

## 在服务端扩展

实现 `Fyrlet.Definition` 的 `contract` / `authorize` / `execute` / `scope` 回调，并在 `config/config.exs` 的 `definitions` 里注册。输入输出契约是校验和类型的唯一来源；私有查询必须在 SQL 层约束 Actor 的 project 与 subject。

```sh
mix fyrlet.contract priv/contract.json && npm --prefix sdks/typescript run generate   # 导出契约并生成类型
```

详见[服务端开发](docs/SERVER.md)；共享订阅、追加订阅、持久 Run 等可选能力见[文档索引](docs/README.md)。

## 目录

`lib/`：服务端 · `sdks/typescript/`：TypeScript SDK（其他语言见 [sdks/](sdks/README.md)） · `examples/`：收件箱与 Notify、Flow、Agent、Chat · `packages/`：Webhooks / Ops 插件与 HTTP / 邮件适配器 · `docs/`：文档 · `bench/`、`scripts/`：基准与验证脚本

## 验证与基准

```sh
mix format --check-formatted && mix compile --warnings-as-errors
bash scripts/test_all.sh                    # Elixir 核心、应用与独立包
npm --prefix sdks/typescript test           # SDK 单元测试
bash scripts/integration.sh                 # 真实 HTTP / WebSocket 场景
```

其余脚本见[验收记录](docs/ACCEPTANCE.md)，基准方法见 [bench/](bench/README.md)，结果见[性能对比](docs/PERFORMANCE.md)；本地结果不能外推生产容量。

## 运行边界

- PostgreSQL 是事实来源；没有离线写入，也没有跨订阅的原子视图。默认限制见[协议](docs/PROTOCOL.md#收敛与资源)。外部副作用不在数据库幂等保证内，需要时用 Run 与 Effect。
- 生产配置（`DATABASE_URL`、`SECRET_KEY_BASE`、`ALLOWED_ORIGINS`、`CORS_ORIGINS`）见[安装文档](docs/INSTALL.md)；TLS、网关限流、备份和控制台由部署方补齐。
- 实体移动设备、多主机生产、24 小时稳定性和真实邮件投递尚未验收。
