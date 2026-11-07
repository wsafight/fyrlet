# 服务端业务开发

当前应用是可运行的参考实现，核心在 lib/fyrlet，传输在 lib/fyrlet_web，参考业务（收件箱）是独立的示例应用 examples/inbox，安装方式与公共接口见 [INSTALL.md](INSTALL.md)。通过配置注册受信任的业务模块，不提供动态加载租户代码。

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
| update_subscription/5（可选） | 根据订阅名称、Actor、规范化参数、上一份 `%Fyrlet.Subscriptions.View{}` 和变更，返回局部替换、重置、上下文更新、不变或重载 |

在 config/config.exs 的 definitions 列表中注册模块。启动时验证回调、名称、操作类型和 schema。完整示例为 examples/inbox/lib/inbox_example/inbox.ex。

schema 支持封闭对象、字符串及字符串 enum、boolean、JavaScript 安全整数、array、null、anyOf，以及 uuid / date-time 字符串格式。它不是完整 JSON Schema；不支持浮点数、任意属性对象、引用或递归类型。高精度业务值应使用明确的字符串编码。

## 查询与授权

Actor 的 project_id / subject_id / session_id 来自已验证会话，不来自业务输入。以收件箱为例：

```elixir
from item in InboxExample.Item,
  where: item.project_id == ^actor.project_id and item.subject_id == ^actor.subject_id
```

上述数据库过滤负责行级数据范围。authorize 的 :ok 只表示允许执行这个业务，不能替代查询过滤。拥有记录 UUID 或命中 Scope 都不授予权限。角色和团队关系可以加入应用自己的表与 authorize 逻辑；参考应用只实现个人所有权。

结果范围必须有界。参考订阅只包含最近一页，历史记录通过 inbox.history 的 keyset 游标读取。快照超限关闭订阅并返回 LIMIT_EXCEEDED，不截断成看似完整的数据。

## Observer 与共享边界

Observer 默认空闲 1000 ms 后进入 GenServer 休眠，压缩进程堆；消息到达时恢复，刷新、鉴权和 ACK 逻辑照常执行。可通过 `observer_hibernate_after` 或 `FYRLET_OBSERVER_HIBERNATE_AFTER_MS` 调整，环境变量 `infinity` 关闭休眠。这是内存与唤醒 CPU 的取舍，持续忙碌的 Observer 不会进入休眠。

共享 Observer 的 `init/1` 只注册通知与有界状态，首次 attach 执行初始业务加载，受 15 秒调用超时约束。一个慢加载不会阻塞 DynamicSupervisor 启动其他共享 Observer；私有视图直接在 Channel 中加载。`:max_observers` 默认限制 10,000 个共享 Observer 进程，达到上限的新共享视图返回 `LIMIT_EXCEEDED`。加入已有共享视图无需新建 Observer，但仍消耗独立的 `:max_subscriptions_per_node` 名额（默认 10,000），与私有、append 和 Presence Channel 合并计数。两个上限都不是连接容量结论。

私有订阅由 Channel 内的 `Fyrlet.Subscriptions.Observation` 维护规范化 View，不创建独立 Observer 进程或监视器。显式共享的订阅由 Observer 运行同一状态机。Channel 负责各客户端的 generation、seq、ACK 与到期定时器。同 session 共享需在服务端契约设置 `"shared": true`；跨成员共享需声明 `"sharing": "identical"` 并实现独立查询和成员检查。两者都不会根据 `public` 自动推断，也不是客户端 join 选项。当前 `inbox.recent` 已启用 session 共享。

共享使用节点本地 Registry / DynamicSupervisor，key 为 `{actor, subscription}`，不是 Scope 或仅 project / subject。完整 Actor 包含 project_id、subject_id、session_id、expires_at；准备后的完整 subscription 包含 module、name、规范化 parameters、specification、scope。同 session 的多设备在这些值一致时可复用，不同 session 即使同 project / subject 也不共享；不同节点不共享。客户端 topic UUID 与 delivery 不在共享 key 中，全量和增量客户端可以复用同一个 Observer。

每次全量或局部计算都在开始前重新验证会话并调用 `authorize/3`，计算后再次验证会话。每次 attach 也独立执行会话检查、业务授权、再次会话检查与大小检查，即使已有 Observer 且复用缓存快照也不跳过；没有授权 TTL 缓存。attach 不强制重新查询业务数据，数据新鲜度仍由失效通知、显式刷新与周期复核保证。

## 事务与失效通知

各租户表保留项目与用户过滤索引，并为 subject / service key 的外键补充以关联字段开头的索引。项目删除触发的级联删除和外键检查可使用这些索引；项目优先的复合索引无法替代仅以 subject_id 查询时所需的索引。

write 操作的 execute 运行于框架事务内。应用可以使用 Repo 或 Ecto.Multi 处理自己的领域数据，成功后返回有变化的 Scope 列表。框架在输出校验通过后写入幂等结果及 Oban 任务，最后一起提交。最外层事务成功提交后立即广播失效通知，订阅刷新不必等待 Oban 调度；持久化任务仍会执行，覆盖提交后进程退出或即时广播失败的情况。命中幂等缓存不再次广播。若调用方已开启 Repo 事务，框架无法确定外层何时提交，因此仅使用持久化任务通知，避免广播尚未提交或最终回滚的写入。

不要在回调中提前广播正文或产生不可回滚的外部副作用。异步外部工作应由单独的持久化任务执行，并自行定义重试与补偿。

收件箱 Scope 形式为 `projects:<project>:subjects:<subject>:inbox`。持久化任务只保存 Scope 与项目，广播 `{:invalidated, job_id}`。即时通知可广播 `{:invalidated, job_id, change}`，change 只在内存中传递，不写入 Oban 参数。视图状态保存最近 64 个通知 ID，跳过已处理的持久化重试；不按 ID 大小丢弃乱序通知，旧 ID 被淘汰后重放只会触发安全刷新。视图所属进程先监听通知再读取初始数据；同轮多个待处理刷新合并后丢弃局部变更提示，回退全量加载。持久化兜底没有变更正文，也走全量加载。

每个私有 Channel 或共享 Observer 只有一个协调（reconciliation）定时器，默认每 30 秒重新授权并全量加载以修复遗漏通知；共享成员复用 Observer 的定时器。无论 delivery 是否为 delta-v1，都保留用于判等和增量更新的规范化 View。私有 Channel 按需编码快照，发出后释放编码正文；共享 Observer 缓存当前修订的编码正文。自动刷新可见数据不变时不推送、不增加视图修订或客户端序号；私有 context 的变化不算可见数据变化。显式 refresh 重新加载，并在请求客户端可接收时发送完整快照，即使数据未变。

ACK 按客户端独立维护，每个客户端最多一条待确认更新；等待 ACK 不阻止 Observer 计算或向其他 ready 客户端推送，也不积累每个客户端的补丁队列。落后客户端 ACK 后会触发重新授权的全量加载，并以完整快照追平；只有跟上上一视图修订、已请求 delta-v1 且未强制刷新时才可接收增量。channel 的 seq 与 Observer 内部 revision 不是同一个计数器。

### 规范化 View 与回调

`%Fyrlet.Subscriptions.View{}` 对唯一字符串 id 的记录数组维护 records（ID → 记录）、order（ID 顺序）、sizes（逐记录 JSON 字节数）、bytes（完整可见数据 JSON 字节数），并保存私有 context、patch、unchanged。其他数据保存在 value，走完整加载路径。`View.data/1` 还原对外数据；context 不进入快照、delta 或对外字节数，但业务必须自行限制其大小，不能把它当作无界缓存。

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

## 可选能力的开发要点

各能力的语义见 [RUNS.md](RUNS.md)、[EFFECTS.md](EFFECTS.md)、[STREAMS.md](STREAMS.md)、[SHARING.md](SHARING.md)、[PLUGINS.md](PLUGINS.md)，线上协议见 [PROTOCOL.md](PROTOCOL.md)。以下是业务开发要点。

### 可选的 Definition 回调

| 回调 | 用途 |
| --- | --- |
| `run/3`、`step/3` | 静态规划的 Run：`run/3` 返回 `{:ok, steps: […], business_key: …, ttl_seconds: …}`，`step/3` 执行一步 |
| `advance/3`、`plan_options/3` | 动态规划（操作声明 `planning: :dynamic`），与 `run/3` 二选一 |
| `run_authorize/4` | 授权 `:start`、`:view`、`:signal`、`:cancel`；缺省只有发起者可以 |
| `definition_version/1`、`implementation/2` | 固定运行所用的定义版本；版本缺失时运行暂停为 `definition_unavailable` |
| `data_scope/3` | 受管数据访问的行级策略 |
| `shared_query/3`、`membership/3`、`policy_version/1` | `sharing: "identical"` 的共享订阅 |
| `ingest/3` | 批量摄取的单条处理，在完成该条的同一事务内执行 |
| `stream/3` | 追加订阅（`mode: "append"`）：返回 `Fyrlet.Features.Stream` 的流名，在 `authorize/3` 之后调用 |

操作种类：`read`、`write`、`run`（`Fyrlet.Runs.operation/2`）、`ingest`（`Fyrlet.Features.Ingest.operation/2`）。

### 步骤的返回

`{:ok, 输出}`、`{:ok, 输出, commit: fn -> … end}`（受管提交，与步骤结果同事务）、`{:error, %Fyrlet.Error{}}`（`retryable: true` 且未超过 `max_attempts` 时按退避重试）、`{:effect, %{adapter:, key:, payload:}}`（交给 Effect 派发）。步骤输出必须是对象，上限默认 64 KiB。

### Effect 的重试规则

按适配器声明的能力：有幂等键则在去重窗口内用同一个 `operation_id` 重发；只能查询则只对账，查不到也不重发；都没有则结果不确定时暂停等待人工，除非步骤显式 `retry_allow_duplicates: true`。**结果不确定的副作用不会被自动判成失败。** 人工处置用 `Fyrlet.Effects.resolve/5`，需要操作者与证据，只追加记录；重发需 `acknowledge_duplicates: true`（接收方仍能去重时除外）。

### 追加订阅与 `Fyrlet.Features.Stream`

订阅声明 `"mode" => "append"`、`"max_items" => n`、`"capability" => "append"`，输出为数组，并实现 `stream/3`；服务端需开启 `capabilities: %{"append" => 1}`。写操作在 `execute/3`（已在事务内）里追加：

```elixir
{:ok, _cursor} = Fyrlet.Features.Stream.append(actor.project_id, "room.#{room}", [%{"text" => text}])
{:ok, result, [scope]}   # 照常返回受影响 Scope，订阅者据此读取新条目
```

要点：`append/3` 必须在事务内调用（否则抛 `ArgumentError`），事务持有该流的位置锁直到提交，因此同一流的追加按提交顺序编号、不会出现空洞；条目必须是 JSON 对象（至多 16 KiB，一次至多 100 条）。**更正或删除已发布条目时调用 `Fyrlet.Features.Stream.reset/2`**（新 epoch），不要直接改表，否则客户端会把旧条目当作不可变事实。保留由清理任务按 `config :fyrlet, :streams, retention_items:`（默认 10 000）裁剪。所有成员看到相同条目；需要按成员过滤的数据请用私有快照订阅。

### 邮件副作用（`packages/fyrlet_effect_email`）

`config :fyrlet, effect_adapters: %{"email" => FyrletEffectEmail}` 与 `config :fyrlet_effect_email, provider: MyApp.Mailer, allowed_senders: [...]`。`MyApp.Mailer` 实现 `FyrletEffectEmail.Provider`（`capabilities/0`、`deliver/2`，可选 `status/2`）。适配器负责校验地址与正文、拒绝头注入（不接受自定义头）、限制发件人与收件域；供应商只负责与服务通信，且必须如实声明幂等窗口和可查询性。供应商“受理”是 `accepted`，不是送达；送达与退信经回执接口（退信为 `failed`）或 `status/2` 对账进入。HTTP 适配器同理：`{:fyrlet_effect_http, …}`，`config :fyrlet_effect_http, allowed_hosts: [...]`。

### Webhooks（插件 `FyrletWebhooks`）

`config :fyrlet, plugins: [FyrletWebhooks]`，`config :fyrlet_webhooks, sources: %{"billing" => %{project_id:, secret:, handler:}}`；`POST /api/v1/plugins/webhooks/<source>`。事件 ID 记在插件自己的表 `webhooks_events`，由插件内的定时任务按 `retention_seconds` 清理。

### Ops（插件 `FyrletOps`）

`config :fyrlet, plugins: [FyrletOps]`。`FyrletOps.Status.status/1` 与 `alerts/1` 提供有界状态与告警；`config :fyrlet_ops, thresholds: %{...}, alert_handlers: [Mod], interval_ms: 30_000`，处理器实现 `FyrletOps.AlertHandler.handle_alert(:firing | :resolved, alert)`，只在状态转换时调用，崩溃会被记录并跳过。`mix fyrlet.ops [--fail-on-alert]` 可作定时检查；项目级状态在 `GET /api/v1/plugins/ops/status`。

### 写自己的插件的测试

`Fyrlet.Testing` 提供 `project/0`、`user/2`、`drive/1` 等辅助，不依赖测试框架；用 `Fyrlet.Conformance.Plugin.failures/1` 检查插件。可参考 `packages/fyrlet_ops/test`。

### 插件

接口与规则见 [PLUGINS.md](PLUGINS.md#插件-api)。`config :fyrlet, plugins: […]`；必需插件失败阻止启动，可选插件失败被隔离；用 `Fyrlet.Conformance.Plugin.failures/1` 在自己的测试里检查插件。

## 代码组织

`lib/` 的目录与模块名一一对应，测试目录镜像 `lib/`；可选能力放在 `packages/`，各是独立的 Mix 项目。

| 位置 / 命名空间 | 内容 |
| --- | --- |
| `lib/fyrlet/`（根） | 契约与运行时：`Runtime`、`Registry`、`Schema`、`Definition`、`Capabilities`、`Scope`、`Auth`、`Error`；测试辅助 `Testing` |
| `lib/fyrlet/subscriptions/` | 订阅管线：`Observation`、`Observer`、`View`、`Delta`、`RecordIndex`、`Limits`、`SessionChecks`、`Tracker` |
| `lib/fyrlet/runs/` | 持久 Run：状态机、引擎、恢复、执行器协议、限额 |
| `lib/fyrlet/effects/` | Outbox：`Effects`（创建、派发、对账）、`Receipt`、`Resolution`、`Recovery`、`Store`、`Worker`、适配器行为 `Adapter` |
| `lib/fyrlet/features/` | 核心可选特性（按能力开关）：`Anonymous`、`Ingest`、`Stream`（追加订阅）、`Executors`。它们改变主体类型、操作种类、通道或协议，只能由核心定义，**不是插件** |
| `lib/fyrlet/plugin*.ex`、`conformance/` | 插件接口、加载与一致性套件 |
| `lib/fyrlet_web/` | HTTP、Socket 与频道 |
| `packages/fyrlet_webhooks`、`packages/fyrlet_ops` | **插件**（`Fyrlet.Plugin`）：自带迁移、进程、路由 `/api/v1/plugins/<name>/…` |
| `packages/fyrlet_effect_http`、`packages/fyrlet_effect_email` | **副作用适配器包**（`Fyrlet.Effects.Adapter`），经 `effect_adapters` 注册 |

接入一个包：在宿主 `mix.exs` 加路径依赖（如 `{:fyrlet_ops, path: "packages/fyrlet_ops"}`），插件再写进 `config :fyrlet, plugins: [FyrletOps]`，然后 `mix fyrlet.migrate`（插件迁移随之执行）。包有各自的测试：`cd packages/fyrlet_ops && mix test`；`scripts/test_all.sh` 一次跑完所有套件。
