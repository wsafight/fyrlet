# 安装与公共接口

Fyrlet 是服务端依赖：宿主应用把它加进依赖，注册自己的业务定义（`Fyrlet.Definition`），由 Fyrlet 提供契约、身份、事务写入、幂等和实时订阅。仓库内的 [examples/inbox](../../examples/inbox) 是一个独立 Mix 项目，只通过本文列出的入口使用 Fyrlet，它的测试就是安装验收。

源码尚未发布到 Hex，SDK 尚未发布到 npm。可以使用固定提交的源码依赖，或使用本地分发包（见下方“打包与安装验收”）：

```elixir
{:fyrlet, git: "…", ref: "<提交>"}      # 或本地 path: "../fyrlet"
```

## 安装步骤

1. **依赖**：见上。Fyrlet 自带 `Fyrlet.Repo`、`FyrletWeb.Endpoint`（独立端口）和 Oban，随应用启动。
2. **配置**：依赖里的 `config/*.exs` 不会被宿主加载。宿主在自己的 `config/config.exs` 里写下方“必需配置”，在 `config/runtime.exs` 里调用 `Fyrlet.RuntimeConfig`。
3. **业务定义**：实现 `Fyrlet.Definition`，在 `definitions` 里注册。
4. **迁移**：宿主的迁移目录写进 `migration_paths`，用 `mix fyrlet.migrate --create` 一次执行 Fyrlet 与宿主的全部迁移。发布时用 `bin/app eval "Fyrlet.Release.migrate()"`。
5. **SDK**：从源码构建 `@fyrlet/client`，或安装本地 `.tgz`；契约用 `mix fyrlet.contract priv/contract.json` 导出，再用 `sdks/typescript/scripts/generate.mjs` 生成类型。四个网页应用在编译时嵌入 SDK，先执行 `npm --prefix sdks/typescript ci` 和 `npm --prefix sdks/typescript run build`。

### 必需配置

`config/config.exs`（键名与取值见 [examples/inbox/config/config.exs](../../examples/inbox/config/config.exs)）：

| 键 | 含义 |
| --- | --- |
| `ecto_repos: [Fyrlet.Repo]` | 让 `ecto.*` 任务识别仓库 |
| `definitions: [MyApp.Definition]` | 业务定义模块 |
| `migration_paths: [{:my_app, "priv/repo/migrations"}]` | 宿主迁移目录 |
| `session_ttl`、`max_subscriptions`、`max_snapshot_bytes`、`max_channel_queue`、`snapshot_ack_timeout`、`reconciliation_interval`、`max_observers`、`observer_hibernate_after`、`channel_hibernate_after`、`socket_batch_max_messages`、`socket_batch_max_bytes`、`idempotency_ttl`、`batch_session_checks`、`capabilities` | 运行限制与开关，均需给出（示例里是推荐默认值） |
| `Fyrlet.Repo`、`Oban`、`FyrletWeb.Endpoint` 三段 | 连接池、队列与清理器、端点 |
| `config :logger, level: :info`（非测试环境） | 生产日志级别。依赖库自己的配置文件不会被加载，发行版的默认级别是 `:debug`，会把**每条 SQL** 格式化写出：同一负载下实测多耗约 26% 的 CPU（见 [OPTIMIZATIONS.md](OPTIMIZATIONS.md) 的“端到端复测”） |

`config/runtime.exs`：

```elixir
import Config
config :fyrlet, Fyrlet.RuntimeConfig.settings(config_env())
```

可通过 `FYRLET_MAX_SUBSCRIPTIONS_PER_NODE` 设置单节点 Channel 总上限（1–1,000,000，默认 10,000），覆盖普通订阅、append 与 Presence；见[容量限制](OPERATIONS.md)。

环境变量：`DATABASE_URL`、`POOL_SIZE`、`PORT`、`PHX_SERVER`、`CORS_ORIGINS`；数值型变量必须是范围内的整数（`POOL_SIZE` 1–10000，`PORT` 1–65535），否则启动时报错并指出变量名；`ALLOWED_ORIGINS`、`CORS_ORIGINS` 的各项会去掉首尾空格；`:prod` 下 `SECRET_KEY_BASE` 与 `ALLOWED_ORIGINS` 必填。网页与 API 同源时自动放行该来源，其他来源仍需 `CORS_ORIGINS` 明确配置。可选的项目配额默认值 `FYRLET_PROJECT_READS_PER_SECOND`、`FYRLET_PROJECT_WRITES_PER_SECOND`、`FYRLET_PROJECT_MAX_SUBSCRIPTIONS`（见 [OPERATIONS.md](OPERATIONS.md#项目配额fyrletquota)）；可选的摄取数据保留期默认值 `FYRLET_INGEST_RETENTION_SECONDS`（秒数，至少 60，或 `forever`；见 [DATABASE.md](DATABASE.md#按项目配置保留期)）；可选 `FYRLET_METRICS_TOKEN`（启用 `GET /metrics`，见 [OPERATIONS.md](OPERATIONS.md#prometheus-指标fyrletmetrics)）；可选 `FYRLET_CLUSTER_NODES` 为逗号分隔的 `name@host`，最多 32 个；配置后必须启用 Erlang 命名节点并使用相同 cookie。部署方法与调优见 [OPERATIONS.md](OPERATIONS.md)。

### 共享仓库的约束

Fyrlet 与宿主共用一个 `Fyrlet.Repo`。这是有意的：业务写入、幂等记录和失效通知作业必须在同一个事务里提交。因此宿主的业务表也在这个仓库里，并建议带上与 Fyrlet 自己的表一致的复合外键 `(subject_id, project_id) → subjects(id, project_id)`，保证记录的主体属于同一项目（示例迁移里有写法）。宿主使用自己的 `Repo` 的方式目前不支持。表结构与宿主表的约定见 [DATABASE.md](DATABASE.md)。

需要在同一事务中组合宿主写入和受管 Run 调用时，以 `Fyrlet.Transaction.run/1` 作为最外层边界。嵌套调用加入外层事务，Run 通知与运行 telemetry 在外层提交后发出；回滚时丢弃。不要在外面再包一层普通 `Repo.transaction/1`。回调的返回值直接作为结果，`Repo.rollback(reason)` 返回 `{:error, reason}`。

### 宿主网页路由

配置 `config :fyrlet, host_router: MyApp.Web`，其中模块实现 Plug 的 `init/1`、`call/2`。核心和插件路由未匹配时才进入宿主路由，未配置则返回 404。宿主自行处理网页与静态资源的授权和缓存；四个网页应用的共享宿主路由在 `examples/support`，不属于插件。插件仍通过 `plugins` 配置加载。

## 公共接口

宿主可以依赖下列模块与任务；它们的破坏性变更会随协议或契约版本说明。未列出的模块是内部实现，可能随时变化。

| 公共 | 说明 |
| --- | --- |
| `Fyrlet.Definition` | 业务定义回调：`contract/0`、`authorize/3`、`execute/3`、`scope/3`，可选 `change/4`、`load_subscription/3`、`update_subscription/5` |
| `Fyrlet.Schema` | 契约 schema 构造与校验（`object/2`、`validate/2`） |
| `Fyrlet.Error`、`Fyrlet.Actor` | 错误与调用者结构 |
| `Fyrlet.Subscriptions.View` | `update_subscription/5` 收到和返回的视图结构 |
| `Fyrlet.Auth` | 项目与服务密钥、签发/撤销会话、鉴权 |
| `Fyrlet.Runtime` | `call/4`、`prepare_subscription/3`、`view/4`、`snapshot/2`（服务端内调用与测试） |
| `Fyrlet.Registry` | `export/1`、`validate!/0` |
| `Fyrlet.Runs`、`Fyrlet.Runs.Privacy` | 运行：`operation/2`、`start_output/0`、`get/2`、`signal/3`、`cancel/2`、`revoke_grant/2`、集成信号 `signal_from_integration/3`；`scope/1` 返回随该主体 Run 变更而失效的订阅范围；清除 `purge_subject/2` |
| `Fyrlet.Effects`、`Fyrlet.Effects.Adapter` | 副作用：`receipt/4`、`resolve/5`、适配器行为（HTTP、邮件适配器是 `packages/` 里的独立包） |
| `Fyrlet.Features.Executors`、`Fyrlet.Runs.Executor` | 外部执行器凭据与协议 |
| `Fyrlet.Scope` | 受管数据访问 |
| `Fyrlet.Features.Ingest`、`Fyrlet.Features.Anonymous` | 摄取、匿名只读入口 |
| `Fyrlet.Features.Stream` | 事务内 `append/3`、窗口读取、`reset/2`、`prune/2`；订阅由 `stream/3` 选流 |
| `FyrletWebhooks` | 独立 `fyrlet_webhooks` 包的插件入口和 `sign/3` 签名辅助 |
| `Fyrlet.Transaction` | 组合受管调用与宿主写入的 `run/1` 事务边界 |
| `Fyrlet.HTTP` | 宿主与插件的 `result/2`、`success/2`、`error/2,3` JSON 响应辅助 |
| `Fyrlet.Diagnostics` | 可信服务端聚合：`runs/3`、`effects/3`、`limits/1`、`plugins/1`；`cluster/0` 返回本节点及配置/已连接节点。项目由已鉴权上下文选择，`:all` 只供部署运维 |
| `Fyrlet.Testing` | 测试辅助：创建项目/用户、`snapshot/3`、`step/1`、`recover/0`、`drive/2`、`effects/1`、`wait_step/1`、租约/等待故障模拟；搭配 Ecto Sandbox 与手动 Oban |
| `Fyrlet.Vault`、`Fyrlet.EncryptedMap` | 可选静态加密 |
| `Fyrlet.Plugin`、`Fyrlet.Conformance.Plugin` | 插件接口与一致性套件 |
| `Fyrlet.Capabilities` | 能力声明与协商 |
| `Fyrlet.Repo` | 与 Fyrlet 共享的仓库 |
| `Fyrlet.RuntimeConfig`、`Fyrlet.Migrator`、`Fyrlet.Release` | 配置、迁移、发布辅助 |
| `mix fyrlet.migrate` / `fyrlet.contract` / `fyrlet.prune` / `fyrlet.project` / `fyrlet.revoke` / `fyrlet.runs` / `fyrlet.effects` / `fyrlet.plugins` / `fyrlet.ops` | 运维任务；`fyrlet.ops` 由独立 Ops 包提供 |
| HTTP `/api/v1/*`、WebSocket `/socket` | 线协议，见 [PROTOCOL.md](PROTOCOL.md) |

内部（不要直接依赖）：`Fyrlet.Subscriptions.Observer`、`Fyrlet.Subscriptions.SessionChecks`、`Fyrlet.Subscriptions.Tracker`、`Fyrlet.Subscriptions.Delta`、`Fyrlet.Subscriptions.RecordIndex`、`Fyrlet.InvalidationWorker`、`Fyrlet.PruneWorker`、`Fyrlet.Runs.Engine` / `Store` / `Recovery` / `Dynamic` / `Plan` / `Resolver` / `Worker`、`Fyrlet.Effects.Worker`、`FyrletWeb.*`。

## 协议版本与能力

| 维度 | 规则 |
| --- | --- |
| 协议版本 | `protocol_version` 目前只有 `1`，加入通道时必须带；其他值返回 `UNSUPPORTED_VERSION` |
| 契约 | 导出服务端能提供的全部条目，并列出已启用的能力；依赖能力的条目只在对应能力启用时出现 |
| 能力 | 连接在加入时可声明 `capabilities`（`{名称: 版本}` 或名称数组），启用的是与服务端的交集，版本取较小者；未声明而使用依赖能力的订阅会得到 `UNSUPPORTED_CAPABILITY`（HTTP 400） |
| 定义 | 只实现基础回调的定义可以注册；其余回调只对声明了对应种类的操作要求 |
| 数据库 | 首次发布前核心采用一份合并基线，旧开发／测试库直接重建；发布后迁移只追加，回退不得丢弃进行中的执行事实 |

### 自动化验证覆盖

| 内容 | 验证 |
| --- | --- |
| 类型生成器读取检入的契约，拒绝其他协议版本 | `sdks/typescript/test/unit.test.mjs`（读取 `priv/contract.json`） |
| SDK 的业务调用与订阅 | `scripts/integration.sh` 的 9 个真实 HTTP / WebSocket 场景 |
| SDK 的 Run / append 路径 | 同脚本的 4 个真实服务端场景，含信号、重启恢复、隔离与窗口 |
| 未协商能力的连接收不到能力事件，协商了的得到协商结果 | `test/fyrlet_web/capability_channel_test.exs` |
| 协商规则、契约导出、`run` 操作的启用校验 | `test/fyrlet/capabilities_test.exs` |
| 仓库外应用安装、迁移、运行 | `scripts/install_smoke.sh` 在仓库外解包，运行 Inbox / Agent 测试，并在独立 npm consumer 中安装 SDK `.tgz` |
| 四个网页应用的真实业务闭环 | `scripts/domains.sh` 的 8 个 HTTP / WebSocket 场景（含静态资源与无 CDN 的浏览器 SDK） |
| 四应用的浏览器交互与布局 | `scripts/browser.sh`：桌面、Android Chromium 模拟、iPhone WebKit 模拟，共 12 个流程，保存截图并检查横向溢出 |
| 同机双节点通知与恢复 | `scripts/cluster.sh`：共享/append、幂等、跨节点撤销、故障切换、审批恢复及 120 秒持续流量；报告含会话续期与资源清理 |

## 打包与安装验收

```sh
npm --prefix sdks/react ci
bash scripts/package.sh
bash scripts/install_smoke.sh
```

打包会先删除旧 SDK 构建输出，运行 client 与 React 的类型检查和单元测试，再生成四份归档：`.local/releases/fyrlet-source-0.1.0.tar.gz`、`fyrlet-0.1.0.tar`（Hex）、`fyrlet-client-0.1.0.tgz`、`fyrlet-react-0.1.0.tgz`，以及记录精确提交、源码指纹、大小和 SHA-256 的 `manifest.json`。源码包包含核心、领域应用、能力包、文档与验证脚本，排除依赖、构建缓存及本地凭证。安装验收拒绝不安全的归档条目，在临时消费者中编译并加载解包后的 Hex 包，并在仓库外运行源码归档中的 Inbox／Agent 测试。独立 npm consumer 使用本地打包的第三方依赖，在不访问注册表网络的情况下安装两份 `.tgz`，验证导入并以 `skipLibCheck: false` 严格编译 TypeScript 消费者；Elixir 消费者复用已下载依赖。这些是仓库外安装检查，不等于注册表发布。

将源码包解到固定目录后，宿主使用 `{:fyrlet, path: "/固定目录"}`；SDK 使用 `npm install /固定目录/fyrlet-client-0.1.0.tgz`。已选择 Apache-2.0 与公开的正式包元数据；实际 Hex/npm 发布、包名所有权及注册表凭证仍是外部维护者门槛。

## 示例应用

| 目录 | 内容 | 验证 |
| --- | --- | --- |
| `examples/inbox` | 参考业务：个人收件箱，增量窗口 | `cd examples/inbox && mix test`（也是安装验收） |
| [`examples/notify`](../../examples/notify/README.zh-CN.md) | 通知模型、站内列表、Resend 邮件供应商、Run 状态与网页 | `cd examples/notify && mix test` |
| [`examples/flow`](../../examples/flow/README.zh-CN.md) | 私有流程保存、顺序 HTTP / 等待节点、运行记录与网页 | `cd examples/flow && mix test` |
| [`examples/agent`](../../examples/agent/README.zh-CN.md) | 有限文本工具、人工审批、任务模型与网页；未接入 LLM | `cd examples/agent && mix test` |
| [`examples/chat`](../../examples/chat/README.zh-CN.md) | 登录会话、邀请成员、分配、人工接管、历史、共享与 append 网页聊天 | `cd examples/chat && mix test` |

它们都以路径依赖引用主库，使用自己的配置和数据库。使用 Run 的应用在 `config :fyrlet` 中加 `capabilities: %{"runs" => 1}`；使用在线状态（房间成员与“正在输入”）的应用加 `"presence" => 1`，并在定义的契约里声明 `presence` 段（见 [PROTOCOL.md](PROTOCOL.md) 的“在线状态”）；用到副作用则注册适配器 `effect_adapters: %{"http" => FyrletEffectHTTP}`（依赖 `{:fyrlet_effect_http, path: "…/packages/fyrlet_effect_http"}`），并配置 `config :fyrlet_effect_http, allowed_hosts: […]`（允许的主机）与 `config :fyrlet, :effect_secrets`。

四个应用的启动、浏览器登录和功能边界见各自 README。真实邮件发送需要 `RESEND_API_KEY` 和已经验证的 `MAIL_FROM`；本仓库用本地供应商模拟验证协议，没有外部真实投递验收。所有领域定义与测试通过公共入口调用，插件运行时代码通过 `Transaction`、`HTTP`、`Diagnostics` 等公共接口接入核心。

浏览器、双节点和真实邮件的复现步骤、证据及剩余环境要求见 [ACCEPTANCE.md](ACCEPTANCE.md)。真实邮件工具 `scripts/mail_live.sh --check` 只检查配置；正常运行需要额外指定 `MAIL_TO`，会向该地址发送一封验收邮件并等待供应商确认投递。

**迁移提示：** 项目尚未发布，核心迁移已合并为一份（`priv/repo/migrations/20261106000000_create_fyrlet.exs`，含 Oban 的表）。若你的开发数据库执行过更早的迁移，请重建该数据库。
