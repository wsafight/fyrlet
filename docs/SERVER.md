# 服务端业务开发

当前应用是可运行的参考实现，核心在 lib/fyrlet，传输在 lib/fyrlet_web，示例在 Fyrlet.Example.Inbox。首版通过配置注册受信任的业务模块，不提供动态加载租户代码。

## 注册定义

业务模块实现 Fyrlet.Definition：

| 回调 | 责任 |
| --- | --- |
| contract/0 | 声明 operations / subscriptions、输入输出 schema、操作 read / write 类型及订阅的可选 shared 标记 |
| authorize/3 | 根据服务端 Actor 和规范化输入进行操作级授权 |
| execute/3 | 查询或执行业务，返回 `{:ok, data, affected_scopes}` 或 `{:error, %Fyrlet.Error{}}` |
| scope/3 | 返回该订阅依赖的内部通知主题 |
| change/4（可选） | 根据本次操作、Actor、规范化输入与已验证输出，生成即时变更信息 |
| load_subscription/3（可选） | 根据订阅名称、Actor、规范化参数，返回 `{:ok, data, context}` 或 `{:error, %Fyrlet.Error{}}` |
| update_subscription/5（可选） | 根据订阅名称、Actor、规范化参数、上一份 `%Fyrlet.View{}` 和变更，返回局部替换、重置、上下文更新、不变或重载 |

在 config/config.exs 的 definitions 列表中注册模块。启动时验证回调、名称、操作类型和 schema。完整示例为 lib/fyrlet/example/inbox.ex。

schema 支持封闭对象、字符串及字符串 enum、boolean、JavaScript 安全整数、array、null、anyOf，以及 uuid / date-time 字符串格式。它不是完整 JSON Schema；不支持浮点数、任意属性对象、引用或递归类型。高精度业务值应使用明确的字符串编码。

## 查询与授权

Actor 的 project_id / subject_id / session_id 来自已验证会话，不来自业务输入。以收件箱为例：

```elixir
from item in Fyrlet.InboxItem,
  where: item.project_id == ^actor.project_id and item.subject_id == ^actor.subject_id
```

上述数据库过滤负责行级数据范围。authorize 的 :ok 只表示允许执行这个业务，不能替代查询过滤。拥有记录 UUID 或命中 Scope 都不授予权限。角色和团队关系可以加入应用自己的表与 authorize 逻辑；本期参考应用只实现个人所有权。

## Observer 与共享边界

Observer 默认空闲 1000 ms 后进入 GenServer 休眠，压缩进程堆；消息到达时恢复，刷新、鉴权和 ACK 逻辑照常执行。可通过 `observer_hibernate_after` 或 `FYRLET_OBSERVER_HIBERNATE_AFTER_MS` 调整，环境变量 `infinity` 关闭休眠。这是内存与唤醒 CPU 的取舍，持续忙碌的 Observer 不会进入休眠。

Observer 的 `init/1` 只注册通知与有界状态，初始业务加载在本 Observer 的首次 attach 内执行，受 15 秒调用超时约束。一个慢加载不会阻塞 DynamicSupervisor 启动其他 session 的 Observer。每节点默认最多 10,000 个 Observer，可通过 `:max_observers` 调整；达到上限的新视图以 `LIMIT_EXCEEDED` 拒绝，已有共享视图仍可 attach。这个资源保护值不是已验证的连接容量。

每个订阅通过 Observer 串行维护规范化 View，channel 负责各客户端的 generation、seq、ACK 与到期定时器。只有订阅的服务端契约显式设置 `"shared": true` 才启用共享，缺省或其他值均不共享；这不是客户端 join 选项。当前 `inbox.recent` 已启用。

共享使用节点本地 Registry / DynamicSupervisor，key 为 `{actor, subscription}`，不是 Scope 或仅 project / subject。完整 Actor 包含 project_id、subject_id、session_id、expires_at；准备后的完整 subscription 包含 module、name、规范化 parameters、specification、scope。同 session 的多设备在这些值一致时可复用，不同 session 即使同 project / subject 也不共享；不同节点不共享。客户端 topic UUID 与 delivery 不在共享 key 中，全量和增量客户端可以复用同一个 Observer。

每次全量或局部计算都在开始前重新验证会话并调用 `authorize/3`，计算后再次验证会话。每次 attach 也独立执行会话检查、业务授权、再次会话检查与大小检查，即使已有 Observer 且复用缓存快照也不跳过；没有授权 TTL 缓存。attach 不强制重新查询业务数据，数据新鲜度仍由失效通知、显式刷新与周期复核保证。

## 事务与失效通知

各租户表保留项目与用户过滤索引，并为 subject / service key 的外键补充以关联字段开头的索引。项目删除触发的级联删除和外键检查可使用这些索引；项目优先的复合索引无法替代仅以 subject_id 查询时所需的索引。

write 操作的 execute 运行于框架事务内。应用可以使用 Repo 或 Ecto.Multi 处理自己的领域数据，成功后返回有变化的 Scope 列表。框架在输出校验通过后写入幂等结果及 Oban 任务，最后一起提交。最外层事务成功提交后立即广播失效通知，订阅刷新不必等待 Oban 调度；持久化任务仍会执行，覆盖提交后进程退出或即时广播失败的情况。命中幂等缓存不再次广播。若调用方已开启 Repo 事务，框架无法确定外层何时提交，因此仅使用持久化任务通知，避免广播尚未提交或最终回滚的写入。

不要在回调中提前广播正文或产生不可回滚的外部副作用。异步外部工作应由单独的持久化任务执行，并自行定义重试与补偿。

收件箱 Scope 形式为 `projects:<project>:subjects:<subject>:inbox`。持久化任务只保存 Scope 与项目，广播 `{:invalidated, job_id}`。即时通知可广播 `{:invalidated, job_id, change}`，change 只在内存中传递，不写入 Oban 参数。Observer 保存最近 64 个通知 ID，跳过已处理的持久化重试；不按 ID 大小丢弃乱序通知，旧 ID 被淘汰后重放只会触发安全刷新。Observer 先监听通知再读取初始数据；同轮多个待处理刷新合并后丢弃局部变更提示，回退全量加载。持久化兜底没有变更正文，也走全量加载。

每个 Observer 只有一个协调（reconciliation）定时器，默认每 30 秒重新授权并全量加载以修复遗漏通知，不按客户端创建此定时器。无论 delivery 是否为 delta-v1，都维护同一规范化 View；需要完整快照时编码并缓存当前修订的 data JSON。自动刷新可见数据不变时不推送、不增加视图修订或客户端序号；私有 context 的变化不算可见数据变化。显式 refresh 重新加载，并在请求客户端可接收时发送完整快照，即使数据未变。

ACK 按客户端独立维护，每个客户端最多一条待确认更新；等待 ACK 不阻止 Observer 计算或向其他 ready 客户端推送，也不积累每个客户端的补丁队列。落后客户端 ACK 后会触发重新授权的全量加载，并以完整快照追平；只有跟上上一视图修订、已请求 delta-v1 且未强制刷新时才可接收增量。channel 的 seq 与 Observer 内部 revision 不是同一个计数器。

### 规范化 View 与回调

`%Fyrlet.View{}` 对唯一字符串 id 的记录数组维护 records（ID → 记录）、order（ID 顺序）、sizes（逐记录 JSON 字节数）、bytes（完整可见数据 JSON 字节数），并保存私有 context、patch、unchanged。其他数据保存在 value，走完整加载路径。`View.data/1` 还原对外数据；context 不进入快照、delta 或对外字节数，但业务必须自行限制其大小，不能把它当作无界缓存。

`load_subscription/3` 返回 `{:ok, data, context}`，框架校验完整输出并构造 View；未实现时回退到 `execute/3` 并使用空 context。`update_subscription/5` 仅在已有规范化记录数组且有即时变更时调用，第四个参数是 View，不是数组下标索引或旧版 metadata map。返回形式为：

| 返回值 | 含义 |
| --- | --- |
| `{:replace, id, record}` | 替换已有字符串 ID 的记录，要求 record 的 id 一致；校验元素并更新字节数和 patch |
| `{:reset, data, context}` | 校验完整输出，重建 View 并比较可见数据变化 |
| `{:context, context}` | 只更新私有上下文，可见数据不变 |
| `:unchanged` | 数据和上下文均不变 |
| `:reload` | 重新调用加载回调并校验完整输出 |

可选 change 回调在写入事务内执行，只返回信息，不自行广播。局部更新仍须由业务确认项目、用户、记录版本、可见性、过滤条件和排序；索引与变更提示不是授权凭据，不能确定时必须返回 `:reload`。框架在即时变更中附带内部 CommittedChange 元数据，但传给更新回调的是变更正文。仅当替换记录与已验证的操作输出完全一致、订阅元素 schema 与操作输出 schema 完全一致时，才复用输出校验及 JSON 字节数；否则仍校验替换记录。元数据不进入持久化任务。

收件箱初次加载最多查询 `limit + 8` 条，只把前 limit 条发给客户端，其余至多 8 条作为私有候选区保存在 context.reserve，context.complete 表示已知候选是否覆盖剩余结果。可见记录的 inbox.update 在 previous_version、inserted_at、archived 均匹配时局部替换；候选区记录同样检查后只更新 context；确定在窗口与候选区之后的正文更新可以保持不变。新增、删除、归档等成员变化会在 Actor 所有权 SQL 范围内读取当前记录，核对变更与版本，再重排可见数据和候选区。版本缺口、当前记录与通知不一致、缺少可信上下文，或结果未完整覆盖且候选耗尽时重新加载；不能据此宣称所有成员变化均免查询。多个变更合并、持久化兜底与周期复核也全量加载。

### 合并并发会话检查

batch_session_checks 默认开启。8 个节点内分片按 session_id 接收检查请求，每批至多 128 个请求，对重复会话合并数据库读取。它不缓存查询结果、不设置等待凑批定时器：只合并本轮查询开始前已经接收的请求，查询进行中到达的请求使用后续查询。返回时仍检查项目、用户、撤销标记及当前到期时间。快照处理前后的两次会话检查均保留。

写入的 FOR SHARE 会话锁及调用方事务中的检查直接使用当前数据库连接，保持事务可见性与撤销串行化。可通过应用配置将 batch_session_checks 设为 false 恢复逐次查询。分片异常或等待超时返回可重试的内部错误，不放行未经确认的会话。

结果范围必须有界。参考订阅只包含最近一页，历史记录通过 inbox.history 的 keyset 游标读取。快照超限关闭订阅并返回 LIMIT_EXCEEDED，不截断成看似完整的数据。

## 运维入口

```sh
mix fyrlet.project --output .local/project.json "My App"
mix fyrlet.contract priv/contract.json
mix fyrlet.revoke_key KEY_ID
mix fyrlet.prune
```

project 输出文件权限为 0600，已有文件会拒绝覆盖。prune 可由部署环境定时执行。密钥管理命令属于受信任控制面，本期不开放 HTTP 管理项目或密钥接口。

当前配置中的关键限制包括 max_subscriptions、max_snapshot_bytes、max_channel_queue（当前检查 Observer 邮箱）、snapshot_ack_timeout、reconciliation_interval、socket_batch_max_messages、socket_batch_max_bytes、idempotency_ttl。单个数据库语句超时由 Repo 的 PostgreSQL statement_timeout 控制；任意 Elixir CPU 任务没有通用强制隔离超时，业务回调应保持短小。

## 数据保留与容量

每次写入都会产生一行幂等结果（含完整返回值）和一条 Oban 兜底作业。按 500 writes/s 粗估（在小表上实测每行约 1 KB，含索引，实际会有出入）：幂等结果保留 24 小时时稳态约 4300 万行、约 40 GB；Oban 作业保留 1 小时约 180 万行。请按业务的重试窗口选择保留期：

- `idempotency_ttl`（秒，默认 86400）或环境变量 `FYRLET_IDEMPOTENCY_TTL_SECONDS`：幂等结果保留时长，等于客户端可安全重试同一个 Idempotency-Key 的窗口。缩短它会缩小表，但超过窗口的重试会被当成新请求重新执行。
- 过期幂等结果和过期超过 24 小时的会话由 `Fyrlet.PruneWorker` 每 10 分钟分批清理（每批 5000 行）；`mix fyrlet.prune` 仍可手动执行。
- Oban 已完成作业由 `pruner` 清理：保留 1 小时、每 10 秒最多删 50000 条。Oban 默认每 30 秒最多删 10000 条，持续写入超过约 333 次/秒时清理会跟不上，所以这里调高了。
- `POOL_SIZE` 设置数据库连接池大小（默认 10）。写入事务会在整个事务期间占用连接；这个值是否限制吞吐尚未实测。

Telemetry 事件包括 fyrlet.operation.stop、fyrlet.subscription.query、fyrlet.subscription.snapshot、fyrlet.subscription.delta 和 fyrlet.subscription.count，另有 Ecto / Oban 自身事件。duration 为 monotonic native 单位，snapshot 的 bytes 为完整数据 JSON 字节，delta 的 bytes 为 patch JSON 字节（不含事件外壳），active 为当前本节点订阅数。默认关闭 Phoenix 连接参数及 channel 参数日志，业务异常只记录异常类型，客户端得到统一错误。

fyrlet.auth.batch 事件包含 duration、requests（本批请求数）与 sessions（去重后会话数），metadata.result 表示查询成功或失败。fyrlet.transport.batch 包含 messages 与 bytes（被聚合的 Phoenix 帧字节之和，不含 batch 外壳）。默认 Phoenix JSON serializer 配合 Jason 时，快照和 delta 可复用 Observer 已编码的 JSON；其他 serializer 或 JSON 库保留普通数据推送路径。

### 传输批处理与故障恢复

SocketTransport 保持单帧为标准 Phoenix 五元素数组；多帧出站消息包装为 `{"batch":[...]}`，保留帧顺序。只聚合同轮 transport mailbox 已有的推送，通过自发送 flush 消息提交，不设置等待凑批定时器。socket_batch_max_messages 默认 64 且硬上限为 64；socket_batch_max_bytes 默认 256 KiB，是聚合预算，单条超预算消息单独发送，不截断。入站 Socket 帧 64 KiB 限制与出站批处理预算不同。批处理可混合不同 topic，不提供跨订阅事务或原子可见性；自写客户端必须支持此包装，不能假定原生 Phoenix decoder 即可处理。

channel 监控 Observer，运行中的 Observer 退出时发送 retryable 的 INTERNAL_ERROR；会话检查 worker 故障或超时也返回 retryable 内部错误，不绕过认证。SDK 收到 retryable status 后重建连接和订阅，以新 generation 的完整快照恢复，不重放未确认的业务写入。attach 遇到 Observer 调用退出会内部重试一次，仍失败则返回 retryable 错误；当前 SDK 的 join error 分支只有 UNAUTHENTICATED 自动恢复，其他 join 错误需显式 reconnect，不能把它等同于运行中 retryable status 的自动恢复。

### 运行时调优

早期在本机 M3 Pro 的低负载实时推送测试中，下面的可选配置降低过累计 CPU 消耗。该历史对照报告已移除，**没有在同限额环境中复测**，请把它当作待验证的可选项：

```sh
ERL_FLAGS='+S 4:4 +sbwt none +sbwtdcpu none +sbwtdio none' \
MIX_ENV=prod mix phx.server
```

此配置需要已有的生产数据库、密钥与其他环境变量。它没有写入全局默认值；调度器数量应结合部署 CPU 预算和实际负载重新测试。当前结果不能证明最大吞吐提升，低负载延迟也没有随 CPU 消耗同比下降。最新的同资源测试使用容器 cgroup 限额，BEAM 自动只启用 1 个调度器，没有使用上述手动配置。

## 当前发布边界

当前完成单节点参考应用及本地 SDK；尚未发布独立 Hex 包、npm 包或商业托管平台。完整容量基线、跨节点部署、全局配额、管理 UI、OIDC 验证器与密钥轮换界面后续实现。
