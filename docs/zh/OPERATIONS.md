# 运维与容量

部署、配置项与环境变量见 [INSTALL.md](INSTALL.md)。本文覆盖运维入口、容量与保留、配额、可观测性、故障恢复和多节点部署。

## 运维命令

```sh
mix fyrlet.project --output .local/project.json "My App"
mix fyrlet.contract priv/contract.json
mix fyrlet.revoke_key KEY_ID
mix fyrlet.prune
```

project 输出文件权限为 0600，已有文件会拒绝覆盖。prune 可由部署环境定时执行。密钥管理命令属于受信任控制面，目前不开放 HTTP 管理项目或密钥接口。

当前配置中的关键限制包括 max_subscriptions、max_subscriptions_per_node、max_observers、max_snapshot_bytes、max_channel_queue（检查视图所属进程的邮箱）、snapshot_ack_timeout、reconciliation_interval、socket_batch_max_messages、socket_batch_max_bytes、idempotency_ttl。单个数据库语句超时由 Repo 的 PostgreSQL statement_timeout 控制；任意 Elixir CPU 任务没有通用强制隔离超时，业务回调应保持短小。

`max_subscriptions` 默认每连接 20 个。`max_subscriptions_per_node` 默认限制单节点合计 10,000 个活动订阅、append 和 Presence Channel，可通过 `FYRLET_MAX_SUBSCRIPTIONS_PER_NODE` 设置（1–1,000,000）。Tracker 同时执行节点、连接与项目上限，在 Channel 退出时释放名额。`max_observers` 单独限制共享 Observer 进程，默认 10,000 个；私有订阅在 Channel 内运行，不占 Observer 进程。这些值是资源保护上限，不代表节点容量。

订阅契约可声明 `"max_snapshot_bytes" => 32_768`，最大不超过配置的全局上限（默认 256 KiB）。启动时验证预算是否合法；首次加入、重新计算和显式刷新时检查实际快照。超限返回 `LIMIT_EXCEEDED`，不会截断数据。该预算覆盖私有、共享与 append 快照；append 批次仍执行独立的流控上限。

- `mix fyrlet.runs`：停滞的运行；`mix fyrlet.effects`：未知、等待人工或超期未派发的副作用；`mix fyrlet.plugins`：插件、能力与迁移状态。
- 恢复扫描器（`Fyrlet.Runs.Recovery`）修复过期租约、漏发的唤醒、等待超时、取消期限、运行到期、授权失效、定义缺失；它只看数据库，不依赖进程存活或一次通知。启用 `runs` 能力时自动随应用启动。
- 清理任务（每 10 分钟）会删除过期幂等记录、过期会话、过期匿名主体、超期的终态运行和 webhook 去重记录；**不会**删除活跃运行、仍有未决副作用的运行及其必要事实。

## 数据保留与容量

各表由谁清理、保留多久见 [DATABASE.md](DATABASE.md#清理与保留)；摄取数据的保留期可按项目设置，见[按项目配置保留期](DATABASE.md#按项目配置保留期)。

每次写入都会产生一行幂等结果（含完整返回值）和一条 Oban 兜底作业。按 500 writes/s 粗估（在小表上实测每行约 1 KB，含索引，实际会有出入）：幂等结果保留 24 小时时稳态约 4300 万行、约 40 GB；Oban 作业保留 1 小时约 180 万行。请按业务的重试窗口选择保留期：

- `idempotency_ttl`（秒，默认 86400）或环境变量 `FYRLET_IDEMPOTENCY_TTL_SECONDS`：幂等结果保留时长，等于客户端可安全重试同一个 Idempotency-Key 的窗口。缩短它会缩小表，但超过窗口的重试会被当成新请求重新执行。
- 过期幂等结果和过期超过 24 小时的会话由 `Fyrlet.PruneWorker` 每 10 分钟分批清理（每批 5000 行）；`mix fyrlet.prune` 仍可手动执行。
- Oban 已完成作业由 `pruner` 清理：保留 1 小时、每 10 秒最多删 50000 条。Oban 默认每 30 秒最多删 10000 条，持续写入超过约 333 次/秒时清理会跟不上，所以这里调高了。
- `POOL_SIZE` 设置数据库连接池大小（默认 10，范围 1–10000）。写入事务会在整个事务期间占用连接。实测（800 writes/s、应用 1 vCPU、各 6 次）10 与 30 的完成写入、CPU、P95 没有可测差别，见 [OPTIMIZATIONS.md](OPTIMIZATIONS.md) 的“连接池大小”一节；更高写入速率或更慢的数据库下是否变化没有测，出现连接排队时再调大。

## 项目配额（`Fyrlet.Quota`）

按项目限制操作调用速率和同时打开的订阅数。**默认不限制**，不配置时行为与之前完全一致。

```elixir
config :fyrlet,
  quotas: [
    default: [reads_per_second: 200, writes_per_second: 50, max_subscriptions: 5_000],
    projects: %{"<project uuid>" => [writes_per_second: 500]}
  ]
```

- 键为 `reads_per_second`、`writes_per_second`、`max_subscriptions`，值为 `nil`（不限）或正整数；项目条目按键覆盖默认值。拼写错误、非正数会让应用启动失败。
- 默认值也可由环境变量给出：`FYRLET_PROJECT_READS_PER_SECOND`、`FYRLET_PROJECT_WRITES_PER_SECOND`、`FYRLET_PROJECT_MAX_SUBSCRIPTIONS`（范围 1–1000000）。按项目的覆盖只能写在应用配置里。
- **读写分开计数**：`kind: "read"` 的操作算读，写入、Run、摄取算写。检查发生在派发之前，所以超限的调用不会校验输入、不会占用数据库连接，也不会产生幂等记录。
- 超限返回 HTTP 429、`LIMIT_EXCEEDED`、`retryable: true`，`details` 带 `scope`、`class`、`limit` 和 `retry_after_ms`；HTTP 响应同时带 `Retry-After`（秒，向上取整）。被拒绝的调用同样计数，所以无视提示的客户端会一直被拒绝。每次拒绝发出 `[:fyrlet, :quota, :rejected]` 遥测事件（metadata 含 `project_id`、`class`）。
- 订阅上限由 `Tracker` 计数，与每连接上限（`max_subscriptions`）叠加；达到项目上限时返回不可重试的 `LIMIT_EXCEEDED`，关闭订阅后立即释放。

**限制，请按需评估：**

- 速率按**一秒固定窗口**计数。客户端在一秒末尾和下一秒开头各发满额度，这两秒交界处最多通过两倍额度；任意完整的一秒内不会超过上限。
- 所有计数都是**单节点内**的。多节点部署时，一个项目在每个节点上各有一份额度，总额度约为节点数乘以上限。
- 没有对读取订阅快照的字节量、Run 之外的存储量做限制。

## 可观测性

### 遥测事件

Telemetry 事件包括 fyrlet.operation.stop、fyrlet.subscription.query、fyrlet.subscription.snapshot、fyrlet.subscription.delta 和 fyrlet.subscription.count，另有 Ecto / Oban 自身事件。duration 为 monotonic native 单位，snapshot 的 bytes 为完整数据 JSON 字节，delta 的 bytes 为 patch JSON 字节（不含事件外壳），active 为当前本节点订阅数。默认关闭 Phoenix 连接参数及 channel 参数日志，业务异常只记录异常类型，客户端得到统一错误。

fyrlet.auth.batch 事件包含 duration、requests（本批请求数）与 sessions（去重后会话数），metadata.result 表示查询成功或失败。fyrlet.transport.batch 包含 messages 与 bytes（被聚合的 Phoenix 帧字节之和，不含 batch 外壳）。默认 Phoenix JSON serializer 配合 Jason 时，快照和 delta 可复用 Observer 已编码的 JSON；其他 serializer 或 JSON 库保留普通数据推送路径。

Run、Effect 与插件的事件：

| 事件 | 关键字段 |
| --- | --- |
| `fyrlet.run.stop` | operation、status、duration、steps |
| `fyrlet.run.step` | name、status、attempt、duration |
| `fyrlet.run.recovery` | reason、expired_leases、rescheduled、stale_results |
| `fyrlet.run.signal` | accepted / consumed / duplicate / rejected、wait_age |
| `fyrlet.run.cancel` | confirmed / fenced_timeout、duration |
| `fyrlet.effect.stop` | adapter、status、attempt、unknown |
| `fyrlet.effect.reconcile` | adapter、age、outcome、resolution_required |
| `fyrlet.run.queue` | 队列年龄（最老待领取 Step）、排队数、按项目聚合的并发占用 |
| `fyrlet.run.wait` | 超期未到达信号的等待节点数、`definition_unavailable` 数量 |
| `fyrlet.delta.snapshot_fallback` | name、reason（gap / overflow / refresh） |
| `fyrlet.scope.shared` | members，元数据 name、mode |
| `fyrlet.subscription.serialize` | 快照数据实际编码的 duration、bytes，元数据 name、mode；不含每连接的协议封套编码 |

另有 `fyrlet.subscription.append`（追加批次的字节与条目数）、`fyrlet.ops.status`（`alerts`、`stuck_runs`、`queue_age_seconds`、`unresolved_effects`）和 `fyrlet.ops.alert`（`firing` 1/0，元数据 `name`、`severity`）。`fyrlet_ops` 的告警只在状态转换时通知（`FyrletOps.AlertHandler`），告警内容不含 Run/Effect ID。`fyrlet.run.queue` 在恢复扫描时按全局和单项目最大租约数发出，不含 Run ID 之类的高基数标签。

必须能定位：Run 停在哪个 Step、副作用处于哪个状态、追加订阅是否发生过快照回退。

### Prometheus 指标（`Fyrlet.Metrics`）

`GET /metrics` 输出 Prometheus 文本格式。**默认关闭**：只有配置了令牌才会启动、记录并开放该路由（`config :fyrlet, metrics: [token: "…"]` 或环境变量 `FYRLET_METRICS_TOKEN`，至少 16 字节，否则启动失败）。抓取时带 `Authorization: Bearer <token>`，令牌用常量时间比较；未启用、缺令牌、令牌错误都返回同样的 404，不泄露端点是否存在。路由和业务端口相同，生产环境请再用网关限制来源。

记录方式是在发出事件的进程里做一次 ETS 原子更新，没有消息、没有锁。计数都是**单节点内**的，由 Prometheus 跨节点求和。**标签有界**：操作名只在契约里注册过才使用，否则记为 `_unknown`（`operation.stop` 的名字来自客户端请求，不做限制会被随机名撑爆内存）；没有项目或用户标签。

| 指标 | 类型 | 说明 |
| --- | --- | --- |
| `fyrlet_operations_total{name,result}` | counter | 操作调用 |
| `fyrlet_operation_duration_seconds{name}` | histogram | 操作耗时 |
| `fyrlet_subscription_queries_total{name,result}`、`…_query_duration_seconds{name}` | counter / histogram | 订阅取数 |
| `fyrlet_snapshots_total`、`fyrlet_snapshot_bytes_total`、`fyrlet_deltas_total`、`fyrlet_delta_bytes_total`（`{name}`） | counter | 下发的快照与增量 |
| `fyrlet_append_batches_total`、`fyrlet_append_items_total`（`{name}`） | counter | 追加批次 |
| `fyrlet_snapshot_serializations_total{name,mode}` | counter | Observer 完整快照编码次数 |
| `fyrlet_snapshot_fallbacks_total{name}` | counter | 回退为完整快照 |
| `fyrlet_subscriptions_active` | gauge | 本节点打开的订阅数 |
| `fyrlet_observers` | gauge | 本节点运行的 Observer 数 |
| `fyrlet_session_check_batch_size`、`…_duration_seconds` | histogram | 批量会话检查的批大小与耗时 |
| `fyrlet_transport_batches_total`、`fyrlet_transport_batched_messages_total` | counter | Socket 多帧批处理 |
| `fyrlet_quota_rejected_total{class}` | counter | 项目配额拒绝 |
| `fyrlet_db_queue_seconds`、`fyrlet_db_query_seconds` | histogram | 数据库连接池排队与查询耗时 |
| `fyrlet_vm_processes`、`fyrlet_vm_memory_bytes`、`fyrlet_vm_run_queue` | gauge | BEAM 状态 |

建议关注的信号（阈值需按自己的负载定，这里没有经过验证的默认值）：

- `fyrlet_db_queue_seconds` 的高分位上升：连接池不够用，才是调大 `POOL_SIZE` 的依据。
- `fyrlet_session_check_batch_size` 长期为 1：批处理没有生效，会话检查在逐个发往数据库。
- `fyrlet_snapshot_fallbacks_total` 增长：增量协商失败或窗口溢出，下行流量会变大。
- `fyrlet_quota_rejected_total` 增长：某个项目在撞配额，需要调额度或排查客户端。
- `fyrlet_vm_run_queue` 持续大于 0：调度器饱和。

## 运行限额与数据保护

均可用 `config :fyrlet, runs: […]` 覆盖：单运行节点数 50、节点输入输出与信号负载 64 KiB、单步骤尝试 3 次、租约 60 秒、恢复扫描 30 秒、运行默认有效期 7 天（最长 30 天）、终态运行保留 30 天、信号去重保留 7 天、信号收件箱 50、每项目排队 1000 / 并发 100、每运行每分钟信号 60、Effect 每项目派发 50 次/秒、摄取待处理 10000。

运行要求：

- 每项目限制并发 Run/Step、排队数量与 Effect 派发速率；单 Run 限制节点数、输入输出大小、信号收件箱、事件速率与总存储预算。达到上限应拒绝、暂停或标记截断，不能无限增长。
- 运行事件支持批量落盘和有界读取；高频日志不应逐 token 触发完整 Run 快照。日志节流不允许丢弃状态转换、信号回执或 Effect 尝试事实。
- Run 的 `input`/`output`、信号 `payload` 与 Effect `payload`/`result` 可能含个人或业务敏感数据：定义可声明字段级脱敏（日志与事件不含原文）、可选的静态加密，并支持按保留期或按主体请求清除；清除不得破坏幂等键、`payload_hash` 与审计所需的非敏感事实。
- 通过 request/run/step/attempt/effect 标识关联结构化日志；凭据与敏感负载不进入日志，Run ID 等高基数字段不直接作为常驻指标标签。
- 独立配置运行期限、终态历史保留期、信号去重期、Effect 对账期限及事件归档。`mix fyrlet.prune` 不得删除活跃 Run、未解决 Effect、仍需去重的逻辑键及其必要关联记录。
- 恢复、对账、归档任务都要有队列年龄、失败与容量告警；可选 `fyrlet_ops` 提供状态快照与告警，基本背压和上限由对应运行模块负责。

## 传输批处理与故障恢复

SocketTransport 保持单帧为标准 Phoenix 五元素数组；多帧出站消息包装为 `{"batch":[...]}`，保留帧顺序。只聚合同轮 transport mailbox 已有的推送，通过自发送 flush 消息提交，不设置等待凑批定时器。socket_batch_max_messages 默认 64 且硬上限为 64；socket_batch_max_bytes 默认 256 KiB，是聚合预算，单条超预算消息单独发送，不截断。入站 Socket 帧 64 KiB 限制与出站批处理预算不同。批处理可混合不同 topic，不提供跨订阅事务或原子可见性；自写客户端必须支持此包装，不能假定原生 Phoenix decoder 即可处理。

共享 Channel 监控 Observer，运行中的 Observer 退出时发送 retryable 的 INTERNAL_ERROR。私有 Channel 持有自己的视图状态；Channel 退出后，SDK 重新加入该 topic 并接收新快照。会话检查 worker 故障或超时也返回 retryable 内部错误，不绕过认证。SDK 收到 retryable status 后重建连接和订阅，以新 generation 的完整快照恢复，不重放未确认的业务写入。attach 遇到 Observer 调用退出会内部重试一次，仍失败则返回 retryable 错误；SDK 对首次加入返回的 retryable 错误也会自动恢复：该订阅进入 recovering，由 Phoenix 通道按退避重新加入（连续失败超过 10 次才报告 error），连接上的其他订阅不受影响；UNAUTHENTICATED 仍重建整个连接，不可重试的 join 错误立即失败。

## 运行时调优

早期在本机 M3 Pro 的低负载实时推送测试中，下面的可选配置降低过累计 CPU 消耗。该历史对照报告已移除，**没有在同限额环境中复测**，请把它当作待验证的可选项：

```sh
ERL_FLAGS='+S 4:4 +sbwt none +sbwtdcpu none +sbwtdio none' \
MIX_ENV=prod mix phx.server
```

此配置需要已有的生产数据库、密钥与其他环境变量。它没有写入全局默认值；调度器数量应结合部署 CPU 预算和实际负载重新测试。当前结果不能证明最大吞吐提升，低负载延迟也没有随 CPU 消耗同比下降。最新的同资源测试使用容器 cgroup 限额，BEAM 自动只启用 1 个调度器，没有使用上述手动配置。

## 可选双节点部署

默认保持单节点。`FYRLET_CLUSTER_NODES` 为逗号分隔的静态 Erlang 节点名，例如 `fyrlet_b@node-b.internal`；最多 32 个，每个不超过 255 字节，只允许字母、数字、点、下划线、短横线与一个 `@`。配置后启动 `Fyrlet.Cluster`，每秒尝试连接尚未连接的对端；未命名节点会明确拒绝启动。节点名与 cookie 由 Erlang/发行版管理，不由 HTTP 请求设置。

使用 Mix 在本机验证时，先让两个应用使用相同数据库、定义、插件与迁移，然后分别运行（`<本机短主机名>` 替换为相同的实际主机名，cookie 通过环境提供）：

```sh
FYRLET_CLUSTER_NODES="fyrlet_b@<本机短主机名>" PHX_SERVER=true PORT=4200 \
  elixir --sname fyrlet_a --cookie "$FYRLET_CLUSTER_COOKIE" -S mix phx.server
FYRLET_CLUSTER_NODES="fyrlet_a@<本机短主机名>" PHX_SERVER=true PORT=4201 \
  elixir --sname fyrlet_b --cookie "$FYRLET_CLUSTER_COOKIE" -S mix phx.server
```

发行版用 `RELEASE_DISTRIBUTION=name`、`RELEASE_NODE=fyrlet_a@node-a.internal` 与相同的 `RELEASE_COOKIE`，并在 `FYRLET_CLUSTER_NODES` 写实际对端节点名。节点间须互相解析主机名并允许 Erlang 分布式通信，限制在受信任的内部网络。负载均衡器需支持 WebSocket 和健康检查；已有连接在节点终止后由 SDK 重新连接并恢复订阅，不依赖粘性会话。

共享数据与执行事实仍持久化到同一 PostgreSQL；共享 Observer 与追加读取缓存只在各节点本地共享，跨节点通过 PubSub 传播失效，没有全局内存缓存。`Fyrlet.Diagnostics.cluster/0` 返回本节点、配置对端与实际已连接节点，供可信运维代码使用。`FYRLET_CLUSTER_NODES` 未设置时不启动发现进程；宿主已有节点发现机制时也可继续由宿主连接。

`bash scripts/cluster.sh` 已验同机两节点的幂等、共享/append、普通失效下的成员撤销、SIGKILL 后切换、节点重入、持久审批、会话续期与资源清理。详细结果见 [ACCEPTANCE.md](ACCEPTANCE.md)；多主机网络分区、生产容量与 24 小时稳定性尚未验证。
- 新增配置：`FYRLET_IDEMPOTENCY_TTL_SECONDS`、`POOL_SIZE`、`FYRLET_CHANNEL_HIBERNATE_MS`（构建期）。
