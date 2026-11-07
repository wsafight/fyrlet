# 实现状态与验收矩阵

本文记录各能力的实现状态，以及验收场景与自动化验证的对应关系。验证的环境、原始证据和复现命令见 [ACCEPTANCE.md](ACCEPTANCE.md)；测试数量以 `bash scripts/test_all.sh` 与 `npm --prefix sdks/typescript test` 的输出为准。

状态含义：**已实现**（有自动化测试）、**部分**、**未实现**。验收矩阵是目标清单，不表示所有生产场景已经验收；实体移动设备、多主机生产环境、24 小时稳定性、真实邮件投递与 Hex / npm 发布尚未验收。

## 能力实现状态

| 能力 | 内容 | 状态 | 主要代码 | 主要测试 |
| --- | --- | --- | --- | --- |
| 能力协商与契约导出 | 能力协商；依赖能力的条目按需出现在契约中；`UNSUPPORTED_CAPABILITY` | 已实现 | `capabilities.ex`、`registry.ex` | `capabilities_test`、`capability_channel_test` |
| 分发与安装 | 仓库外应用安装、迁移入口、公共接口清单 | 已实现：固定源码 / 本地源码包与 npm tgz，含 SHA256 清单；尚未发布到 Hex/npm | `migrator.ex`、`runtime_config.ex`、`scripts/package.sh` | `scripts/install_smoke.sh` |
| 持久 Run | 顺序 Run、等待与信号、取消、租约与执行代次、恢复、运行视图 | 已实现 | `runs/*.ex`、`runs.ex` | `runs_*_test`、`runs/concurrency_test` |
| 动态规划 | `advance/3` 动态规划 | 已实现 | `runs/dynamic.ex` | `runs/dynamic_test` |
| 执行策略 | `:oban`、`:local`（连续执行）、`:external` | 已实现 | `runs/worker.ex`、`runs/executor.ex` | `runs_test`、`runs/executor_test` |
| 外部执行器协议 | 外部执行器协议（HTTP） | 已实现 | `runs/executor.ex`、`features/executors.ex` | `runs/executor_test` |
| 执行授权与定义版本固定 | 执行授权、定义版本固定 | 已实现 | `runs/resolver.ex` | `runs/recovery_test` |
| Effect 与 Outbox | Effect/Outbox、适配器协议、对账、回执、人工处置 | 已实现 | `effects.ex`、`effects/*.ex` | `effects/effects_test`、`effects/http_test` |
| 受管数据访问 | 受管数据访问 `data_scope/3`、`Fyrlet.Scope` | 已实现 | `scope.ex` | `scope_test` |
| 领域应用：Notify、Flow | Notify、Flow | 已实现：领域模型、持久表、网页；Notify 有 Resend 供应商，Flow 可保存私有流程。定义与测试使用公共 API | `examples/notify`、`examples/flow`、`examples/support` | 各自测试、`domains.test.mjs` |
| 领域应用：Agent、Chat | Agent、Chat | 已实现：有限工具与审批任务；登录与邀请式聊天、分配、人工接管、分页历史。均有模型、迁移和网页；未包含 LLM 或匿名可写聊天 | `examples/agent`、`examples/chat` | 各自测试、`domains.test.mjs` |
| 追加订阅 | 追加型增量通道（`mode: "append"`） | 已实现（每节点有界共享读取缓存；已验同机双节点，完整历史由应用分页） | `features/stream.ex`、`features/stream/reader.ex`、`append_channel.ex` | `stream_test`（含真实并发）、`stream_reader_test`、`append_channel_test`、SDK 集成、`cluster.test.mjs` |
| 共享订阅范围 | 共享订阅范围（`sharing: "identical"`） | 已实现 | `subscriptions/observer.ex`、`runtime.ex` | `shared_scope_test` |
| 匿名只读入口 | 未认证访问显式公开的订阅与数据；独立的会话签发速率与活动数上限 | 已实现（核心可选特性，不是插件：它引入核心的主体类型） | `features/anonymous.ex` | `features/anonymous_test` |
| Webhook | 签名校验、重放防护、持久化去重，转换为信号 | 已实现：**独立插件包 `packages/fyrlet_webhooks`**（路由 `/api/v1/plugins/webhooks/:source`，自带迁移与去重清理） | `packages/fyrlet_webhooks/` | 包内测试（含插件一致性套件） |
| 批量摄取 | 持久受理的批量输入，逐项结果、去重与背压 | 已实现（核心可选特性：它是核心的操作种类） | `features/ingest.ex` | `features/ingest_test` |
| HTTP 副作用适配器 | HTTP / webhook 派发；去重与查询能力按目标服务声明 | 已实现：**独立包 `packages/fyrlet_effect_http`**（`FyrletEffectHTTP`，经 `effect_adapters` 注册） | `packages/fyrlet_effect_http/` | 包内测试 |
| HTTP 外部执行器 | 外部执行器的 HTTP 协议：领取、续租、上报、取消 | 已实现（核心可选特性：Run 协议的 HTTP 端） | `runs/executor.ex` | `runs/executor_test` |
| 邮件副作用适配器 | 邮件派发；受理、投递与退信按供应商语义区分 | 已实现：独立邮件适配器，含 `FyrletEffectEmail.Resend` 供应商、24h 幂等键、受理后查询对账、投递/退信映射；真实发送凭证与投递尚未验收 | `packages/fyrlet_effect_email/` | 包内测试（含本地 HTTP 供应商协议测试）、Notify 端到端 |
| Ops 状态与告警 | 有界状态快照、阈值告警、项目级只读状态接口 | 已实现：**独立插件包 `packages/fyrlet_ops`**：有界状态快照、阈值告警与“开始/恢复”通知、项目级只读 HTTP（`/api/v1/plugins/ops/status`）、`mix fyrlet.ops`；**没有图形面板**（面板由宿主用快照与遥测搭建） | `packages/fyrlet_ops/` | 包内测试（含插件一致性套件） |
| 插件接口与一致性套件 | 插件接口、启动校验、失败隔离、一致性套件、`mix fyrlet.plugins` | 已实现 | `plugin.ex`、`plugins.ex`、`conformance/plugin.ex` | `plugins_test` |
| 数据保护 | 字段脱敏、清除、可选静态加密、保留期 | 已实现 | `runs/privacy.ex`、`vault.ex` | `runs/privacy_test` |
| 限额 | 限额：节点、负载、事件、信号收件箱、每项目排队与并发、派发速率（并发上限在项目级 advisory 锁下统计并创建租约，同一项目的并发认领不会超过上限） | 已实现 | `runs/limits.ex` | `runs_test`、`effects/effects_test` |
| TypeScript SDK | TypeScript SDK 的 Run、能力协商、append 订阅 API | 已实现：`capabilities`、`startRun/getRun/signalRun/cancelRun/subscribeRun/subscribeRecentRuns/subscribeAppend`；未声明能力仍只使用基础协议 | `sdks/typescript/src` | 单元、真实服务端集成、较早服务端兼容、领域端到端 |
| 浏览器交互与布局 | 网页交互与布局 | 已实现：四应用 × 桌面 Chromium、Android Chromium 模拟、iPhone WebKit 模拟；含截图、无横向溢出、长标题、纯文本防注入、历史与撤销。未覆盖实体设备和像素差分回归 | `scripts/browser.sh` | `browser.test.mjs`（12） |
| 双节点发现与故障恢复 | 集群发现、跨节点通知与故障恢复 | 已实现可选静态节点列表；真实同机双节点验证共享/append、跨节点撤销、幂等、SIGKILL 后切换/重入、持久审批、会话续期与资源清理。多主机生产与 24h 待验 | `cluster.ex`、`scripts/cluster.sh` | `runtime_config_test`、`cluster.test.mjs`（3） |
| 项目配额 | 按项目的读、写调用速率与订阅数上限，默认不限制；超限返回 429 加 `Retry-After`（单节点计数） | 已实现 | `quota.ex`、`subscriptions/tracker.ex` | `quota_test` |
| Prometheus 指标 | `GET /metrics`，默认关闭，需令牌；标签基数有界 | 已实现 | `metrics.ex` | `metrics_test` |
| 在线状态（Presence） | 房间成员与“正在输入”，能力 `presence`；SDK `subscribePresence` | 已实现（含真实服务端加 SDK 的端到端运行） | `presence.ex`、`presence_channel.ex`、`sdks/typescript/src/client.ts` | `presence_channel_test`、SDK 单元 |
| 乐观写入（SDK） | `CallOptions.optimistic`：本地预测叠加在服务端数据上，失败回滚；结束时机为启发式 | 已实现 | `sdks/typescript/src/client.ts` | SDK 单元 |
| 共享订阅的批量会话复核 | `identical` 共享房间对成员的会话检查批量发出，每次变更的会话语句数不再随成员数线性增长 | 已实现 | `subscriptions/observer.ex`、`session_checks.ex` | `session_checks_test`、`shared_scope_test`、`test/bench/shared_fanout.exs` |
| 租约与并发上限 | 外部执行器的租约过期立即生效；同一项目的并发认领在项目级 advisory 锁下不超过上限 | 已实现 | `runs/engine.ex`、`runs/executor.ex` | `runs/executor_test`、`runs/concurrency_test` |

需要明确的两点：

1. 能力包按性质分为独立插件（Webhooks、Ops）和独立适配器（HTTP、Email），都在 `packages/`。匿名入口、摄取、HTTP 执行器、追加通道改变核心身份或协议，保留为核心可选特性。插件运行时代码通过公共 `Fyrlet.Transaction`、`Fyrlet.HTTP`、`Fyrlet.Diagnostics` 与 Run/Effect 入口接入，不直接引用核心 Engine、Signal schema 或 Web 响应内部模块；应用测试使用 `Fyrlet.Testing`。完整公共清单见 [INSTALL.md](INSTALL.md)，分类见 [PLUGINS.md](PLUGINS.md)。
2. 并发相关的断言（并发创建、并发领取、信号对超时、取消对完成、项目并发上限）在 `runs/concurrency_test` 中以**不使用沙箱、真实提交**的方式验证；其余测试跑在 Ecto 沙箱里，行锁竞争只能靠这一组覆盖。

## 基础验收（A01–A18）

| 编号 | 场景 | 通过标准 |
| --- | --- | --- |
| A01 | 干净环境启动 | 按文档完成依赖安装、数据库初始化、开发账号创建和服务启动 |
| A02 | 输入校验 | 类型或字段错误返回稳定错误码，数据库不发生业务写入 |
| A03 | 身份与数据隔离 | 用户 A 不能读取、修改、订阅或借助 Scope 获得用户 B 的记录 |
| A04 | 写入成功 | 成功响应对应已提交数据，另一连接最终获得包含该记录的快照 |
| A05 | 并发重复请求 | 同一幂等键和相同输入只产生一条业务记录，并返回一致结果 |
| A06 | 冲突请求 | 幂等键换输入、过期记录版本均返回明确冲突 |
| A07 | 事务回滚 | 业务失败不保留成功幂等结果，也不触发相应数据通知 |
| A08 | 提交后中断 | 提交成功但发布通知前中断，恢复后仍能刷新相关订阅 |
| A09 | 初始查询竞态 | 建立订阅与写入并发执行，最终数据包含最新提交且无需用户重新打开应用 |
| A10 | 查询期间变化 | 刷新尚未完成时再次写入，旧结果不能永久覆盖新结果 |
| A11 | 重复与乱序处理 | 重复失效通知不重复写入；验证客户端忽略旧 generation 和旧序号 |
| A12 | 断线与重启 | 断开后继续写入，再连接或重启服务后能取得当前正确快照 |
| A13 | 通知遗漏 | 主动丢弃通知，周期校验在健康条件下按约定窗口修复数据 |
| A14 | 权限失效 | 失效后拒绝操作与快照下发，并在约定复核窗口内关闭订阅 |
| A15 | 查询范围变化 | 新增、归档、删除改变最近列表时，下一份快照顺序和成员正确 |
| A16 | 资源回收 | 取消订阅或断开连接后，相关监听与定时任务被释放 |
| A17 | 慢客户端 | 资源有界，不无限积压快照；断开后可以重新读取当前状态 |
| A18 | 协议与基线 | 契约可导出、错误有说明，性能结果附可复现环境和脚本 |

## 能力验收（R01–R25）

| 编号 | 场景 | 通过标准 | 状态 | 验证 |
| --- | --- | --- | --- | --- |
| R01 | 未协商的能力不可见 | 类型生成器读取契约；启用新能力不向未协商它的连接发送任何能力事件 | 已实现 | `capabilities_test`、`capability_channel_test`、SDK 单元 / 集成 |
| R02 | Run 创建幂等 | 保留期内同键同输入返回同一 Run，不同输入冲突；并发创建只有一份记录及首个任务 | 已实现 | `runs_test`、`runs_concurrency_test` |
| R03 | Run 推进 | 顺序计划按固定输入推进；输出、状态与下个任务原子提交；动态模式单独验收 | 已实现 | `runs_test`、`runs_dynamic_test` |
| R04 | 等待与信号 | 提前信号持久化后可消费；重复不重复推进；错误名称、关闭等待与迟到信号不复活节点 | 已实现 | `runs_signals_test`、`runs_concurrency_test` |
| R05 | 取消 | 受理后不产生后续工作；确认或超时隔离均可结束；迟到结果只审计，外部未知结果保留 | 已实现 | `runs_recovery_test`、`runs_executor_test`、`effects_test` |
| R06 | 中断恢复 | 已持久化完成的 Step 不重跑；未确认尝试可重试；旧租约结果不能覆盖当前状态 | 已实现 | `runs_recovery_test`（含故障注入） |
| R07 | 外部去重 | 支持幂等的适配器在有效窗口内复用同一请求键；仅可查询的适配器不宣称至多一次 | 已实现 | `effects_test` |
| R08 | 未知副作用 | 丢失响应后进入 `unknown`；超对账期限仍未知并告警，不伪造失败、不默认重发 | 已实现 | `effects_test` |
| R09 | 运行视图 | 另一客户端通过 `fyrlet.run` 实时看到状态与事件，断线后可恢复 | 已实现 | `runs_subscription_test` |
| R10 | 匿名入口 | 未认证客户端只能访问显式公开的订阅与数据，越权被拒 | 已实现 | `anonymous_test` |
| R11 | Webhook | 错误签名与窗口外请求被拒；合法重复投递返回可识别回执，不重复消费或推进 | 已实现 | `packages/fyrlet_webhooks` 的测试、`effects/receipt_test`（回执） |
| R12 | 增量衔接 | `base_cursor` 不匹配时刷新；源 ID 空洞与并发事务提交不造成误判或遗漏 | 已实现 | `stream_test`（并发提交无空洞/重复）、`append_channel_test`（衔接、窗口上限、慢客户端）、SDK 真实集成、Chat 历史与撤销验收 |
| R13 | 增量上限 | 慢客户端不无限积压；超限后回退快照且资源有界 | 已实现 | `stream_test`（并发提交无空洞/重复）、`append_channel_test`（衔接、窗口上限、慢客户端）、SDK 真实集成、Chat 历史与撤销验收 |
| R14 | 共享订阅范围 | 相同共享键合并查询与序列化；逐成员仍授权，移除成员不可因缓存命中继续接收 | 已实现 | `shared_scope_test`（含对每条保护的变异检验）、25 个独立用户真实端到端压测；[PERFORMANCE.md](PERFORMANCE.md#共享房间与追加流端到端对照2026-11-07) |
| R15 | 数据范围 | 受管路径覆盖读写与归属字段；缺失策略或不支持的查询拒绝，不退回无过滤执行 | 已实现 | `scope_test` |
| R16 | 插件路径 | 官方入口不跳过授权；可选插件失败关闭入口，必需依赖失败阻止就绪 | 已实现 | `plugins_test` |
| R17 | 能力协商 | 客户端只收到自己声明的能力对应的事件；不支持时明确拒绝 | 已实现 | `capability_channel_test`、`capabilities_test` |
| R18 | 定义升级 | 旧 Run 使用固定实现；版本缺失停止调度并告警，不静默运行新实现 | 已实现 | `runs_recovery_test` |
| R19 | 执行身份 | 发起会话过期不自动终止 Run；执行授权撤销拒绝新工作，查看与干预另行授权 | 已实现 | `runs_recovery_test` |
| R20 | 快照与历史 | `fyrlet.run` 的事件与 Step 历史分页、上限与截断标记一致，不能声称完整补齐；追加订阅另有窗口淘汰与快照/位置一致性用例 | 已实现：Run 视图的分页与截断标记；增量窗口淘汰与快照/位置一致性 | `runs_subscription_test`、`append_channel_test`、SDK 单元测试 |
| R21 | 保留与背压 | 排队、日志、信号与存储有界；清理不会删除活跃执行与未解决 Effect 的必要事实 | 已实现 | `runs_recovery_test`、`runs_privacy_test`、`ingest_test` |
| R22 | 两个应用复用 | 第一个领域应用完成闭环，第二个复用公开 API，无 fork 或核心代码复制 | 已实现 | Notify、Flow、Agent、Chat 的公共接口、模型 / 迁移 / 网页与 8 个端到端场景；仓库外解包安装验收 |
| R23 | 等待超时与状态转换 | `wait_timeout_action` 的 `:fail`/`:continue` 均可验证；授权撤销、`definition_unavailable` 超时可使 `pending`/`waiting` 的 Run 进入 `failed`；`cancelling` 期间到期进入 `expired` | 已实现 | `runs_signals_test`、`effects_test`、`runs_test` |
| R24 | 在途 Effect 与取消 | Run 取消后在途 Effect 的真实结果仍被记录并在运行视图可见；`awaiting_effect` 的 Step 租约释放后，Effect 租约失效不会导致 Step 重跑 | 已实现 | `runs_signals_test`、`effects_test`、`runs_test` |
| R25 | 业务键 | 相同 `business_key` 在幂等记录清理后仍不创建重复 Run；`on_conflict` 两种取值行为符合声明 | 已实现 | `runs_signals_test`、`effects_test`、`runs_test` |

R05、R06、R08、R23、R24 必须通过**故障注入**验证。注入点：领取后执行前（`:after_claim`）、结果提交前（`:before_commit`）、结果提交后通知前（`:after_commit`）、推进决定与唤醒之间（`:before_wake_insert`）、Effect 认领后（`:effect_claimed`）与外部调用返回后结算前（`:effect_before_settle`）、取消与完成并发、恢复扫描与迟到结果并发。仅有顺利路径的集成测试不算通过。
