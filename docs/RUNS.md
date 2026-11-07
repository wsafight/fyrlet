# 持久 Run

可选能力 `runs`。Run 表达需要跨请求、跨进程恢复的工作：长时运行、等待外部信号、需要人工介入或取消。普通读写和订阅无需创建 Run；Run 的状态通过既有订阅机制观察。

> **一句话目标：** 业务既能完成可靠的事务调用，也能启动可观察、可介入、可取消的持久任务；恢复时以已经提交的事实继续。

Run 在外部副作用上依赖 [Effect 与 Outbox](EFFECTS.md)，鉴权边界见 [ARCHITECTURE.md](ARCHITECTURE.md#鉴权的分层边界)，线上入口见 [PROTOCOL.md](PROTOCOL.md#run能力-runs)，业务回调见 [SERVER.md](SERVER.md)。

## 操作种类

`operations` 的 `kind` 有三种取值：

| kind | 语义 | 返回 |
| --- | --- | --- |
| `read` | 有界查询 | 结果 |
| `write` | 单事务业务写入 | 结果 + 受影响 Scope |
| **`run`** | 创建一次长时运行，事务内只落记录，立即返回 | `run_id` + 初始状态 |

`run` 操作必须携带 `Idempotency-Key`。在幂等保留期内，同一 `(project, subject, operation, key)` 与相同规范化输入返回同一 `run_id`；输入不同返回冲突。默认保留期为 24 小时，过期后再次使用该键可能创建新 Run。

需要长期唯一的业务（如"同一事件只通知一次"）使用可选的 `business_key`：`run/3` 可返回该键，核心在 `fyrlet_runs` 上建立 `(project_id, operation, business_key)` 唯一约束（仅对非空键生效，不随请求幂等记录清理）。冲突时返回已有 `run_id` 与其当前状态，不创建新 Run；是否允许在终态后重建由操作声明（`on_conflict: :return_existing | :reject_if_active`，默认 `:return_existing`）。

创建 Run、持久化计划和创建首个 Oban 任务在同一事务内完成；HTTP 成功表示运行已受理，不表示业务已经完成。

## 定义方式

执行工作与决定下一步分开：

| 回调 | 职责 |
| --- | --- |
| `run/3` | 根据操作名、已验证发起者与输入生成顺序计划；不执行外部调用 |
| `step/3` | 根据步骤名、已持久化输入和执行上下文返回业务结果或 Effect 意图 |
| `advance/3` | 根据已持久化状态、事件和上下文决定下一步；不执行 IO（动态推进） |

静态计划包含工作节点与显式等待节点：

```elixir
{:ok, steps: [
  %{type: :step, name: "prepare", input: %{"source_id" => source_id}},
  %{type: :wait, name: "approval", signal: "user_approval", timeout_ms: 86_400_000, on_timeout: :fail},
  %{type: :step, name: "publish", input: %{}}
]}
```

`step/3` 的返回值为 `{:ok, output}`、`{:error, %Fyrlet.Error{}}` 或 `{:effect, effect_spec}`；也可返回 `{:ok, output, commit: fun}`——`fun` 在提交结果的**同一事务**内执行，用于把业务写入与步骤结果原子提交（受管提交）。`fun` 返回 `{:error, error}` 或抛出异常时，整个提交回滚，随后作为一次尝试失败记录。Effect 意图交给核心提交和派发，见 [EFFECTS.md](EFFECTS.md)；Step 不返回“下一步”指令。执行上下文提供先前已提交的输出，当前 Step 的解析后输入在首次执行前固定，重试复用。

计划创建时分配稳定的 Step 实例与 `wait_id`，同名步骤以实例 ID/序号区分。每个节点的输入、输出和信号负载必须有契约与大小上限。

`run/3` 与 `advance/3` 两种规划模式按操作显式二选一。`advance/3` 可返回 `{:step, name, input}`、`{:wait, wait_spec}`、`{:done, output}` 或 `{:error, error}`；推进决定与新节点在同一事务内持久化，不能在恢复时重新执行已提交的决定。操作声明 `planning: :dynamic`（`Fyrlet.Runs.operation/2`），定义实现 `advance(operation, state, event)`；`state` 含 `input`、已完成节点的 `outputs`、`run_id`、`project_id`、`initiator_subject_id`；`event` 为 `:start`、`{:step_succeeded, name, output}`、`{:wait_satisfied, name, payload}` 或 `{:wait_timed_out, name}`。业务键与有效期由可选的 `plan_options/3` 提供。动态节点与静态节点经过同一套校验，总节点数受同一上限约束；`advance/3` 抛出异常以 `ADVANCE_CRASHED` 终止运行，且不泄露异常内容。

## 状态与数据

数据表：

| 表 | 主要字段 |
| --- | --- |
| `fyrlet_runs` | id、project_id、subject_id、operation、business_key、definition_version、plan、execution_grant_id、status、wait_reason、version、input、output、error、current_step、cancel_deadline、cancellation_outcome、started_at、finished_at、expires_at |
| `fyrlet_run_steps` | id、run_id、type、name、seq、status、input、output、wait_id、wait_deadline、wait_timeout_action、current_attempt、error、started_at、finished_at |
| `fyrlet_run_attempts` | id、step_id、attempt、execution_epoch、lease_id、lease_expires_at、status、error、started_at、finished_at |
| `fyrlet_run_signals` | id、run_id、wait_id、name、payload、idempotency_key、input_hash、status、received_at、consumed_at |
| `fyrlet_run_events` | id、run_id、step_id、type、payload、seq、created_at |
| `fyrlet_execution_grants` | id、project_id、发起者引用、执行主体、操作与资源范围、expires_at、revoked_at |

Run 状态机：

```text
pending → running ⇄ waiting
running → completed
pending | running | waiting → failed
pending | running | waiting → cancelling → cancelled
pending | running | waiting → expired
cancelling → expired
```

各状态的进入条件：

| 转换 | 条件 |
| --- | --- |
| `→ failed`（来自 `pending`/`waiting`） | 执行授权撤销或过期（见下文“执行身份与代码版本”）、`definition_unavailable` 超过 `definition_unavailable_ttl`（默认 1 小时）仍未恢复、等待节点超时且 `wait_timeout_action: :fail`、重试耗尽 |
| `waiting → running` | 信号被消费，或等待节点超时且 `wait_timeout_action: :continue`（负载为 `timeout` 标记，供后续 Step 区分） |
| `cancelling → expired` | 取消期限前 Run 先到 `expires_at`：按 `expired` 终态处理并保留 `cancellation_outcome: fenced_timeout`，不再等待执行器确认 |
| `waiting` 的 `wait_reason` | `signal`（等待用户/集成信号）、`effect`（等待 Effect 结果）、`definition_unavailable`（定义版本缺失，调度暂停） |

等待节点必须声明 `wait_timeout_action`（`:fail` | `:continue`，默认 `:fail`）；到期判定与信号消费竞争同一状态锁（见下文“信号、取消与介入”）。

Step 与 Attempt 状态：

| 对象 | 状态 | 说明 |
| --- | --- | --- |
| Step | `pending` → `running` → `succeeded` \| `failed` \| `cancelled` | 工作节点；`running` 期间可挂起为 `awaiting_effect` 后回到 `running` 或进入终态 |
| Step（wait） | `pending` → `waiting` → `satisfied` \| `timed_out` \| `cancelled` | 等待节点；`satisfied`/`timed_out` 后不再变更 |
| Attempt | `leased` → `succeeded` \| `failed` \| `abandoned` | `abandoned` 表示租约失效或被取消隔离；Attempt 终态不可改写 |

Step 返回 Effect 意图后进入 `awaiting_effect`：此时当前 Attempt 的租约**释放**（`succeeded` 并标注 `effect_pending`），后续推进由 Effect 状态驱动；Effect 的派发所有权（`lease_id`/`execution_epoch`，见 [EFFECTS.md](EFFECTS.md)）独立于 Step Attempt。Effect 结果提交时仍校验 Run 未处于终态。

约束：

- Run/Step 当前状态是推进事实来源；Event 是同事务写入的审计记录。不引入通过重放全部事件重建状态的执行模型。
- 行锁、条件更新与唯一约束保护状态转换；每个 Run 最多一个当前有效的 Step 执行所有权。领取时持久化租约与递增的 `execution_epoch`，结果提交必须匹配当前代次、租约及 Run 状态。
- 租约失效后的旧执行器仍可能继续运行，但不能提交状态或推进 Run。框架不承诺事务外代码绝不重复执行；已持久化完成的 Step 不重跑，未确认完成的尝试可能重跑。
- 唯一约束至少覆盖 Step 表的 `(run_id, seq)`、Attempt 表的 `(step_id, attempt)`、Event 表的 `(run_id, seq)` 与 Signal 表的 `(run_id, idempotency_key)`。信号负载哈希覆盖等待实例、名称与 payload。Event 序号在锁定 Run 的事务中分配，不使用跨事务自增 ID 推断提交顺序。
- Step 输出、下一节点、关联业务变更与后续任务通过受管提交接口原子写入；Step 自行发起的独立 Repo 写入不自动获得这一保证。事务中不包裹外部调用。
- 重试有最大次数、退避、总运行期限与可重试错误分类。超过上限进入 `failed`，保留已提交输出；重试不重新生成已存在的 Effect 身份。
- `expires_at` 是运行期限，不是数据删除时间。到期时使执行代次失效并进入 `expired`，拒绝新信号与后续推进；已派发 Effect 的真实结果仍需记录和对账。
- `completed`、`failed`、`cancelled`、`expired` 不再推进；迟到结果可追加审计记录，不能改写终态。

## 执行策略

框架只定义"谁来执行一个 step"，执行方式可插：

| 策略 | 适用 | 说明 |
| --- | --- | --- |
| `:oban` | 默认，所有工作 Step | Oban 负责唤醒与排队，Run 状态表决定是否执行；重复或迟到任务必须安全退出 |
| `:local` | 短 Step 的连续执行 | 同样遵守租约与代次检查，不能只有内存中的 Task 状态 |
| `:external` | 特定语言与重计算 | 使用下文外部执行器协议的租约，不托管用户代码 |

`:oban` 为默认。`:local` 以配置 `runs: [local_chain: n]` 实现：同一次唤醒连续执行至多 n 个步骤，每一步仍独立领取租约、独立提交，崩溃或迟到结果的处理不变。`:external` 见下文外部执行器协议。业务重试状态以 Run/Attempt 记录为准，Oban 的任务重投不能额外消耗或重置业务重试次数。恢复扫描器检查到期租约与缺失唤醒任务，不依赖进程存活或一次通知。

## 信号、取消与介入

框架提供三个用户入口（用户令牌 + `X-Project-Id`）；Webhook 通过已认证的受限集成主体调用同一核心 API：

| 入口 | 语义 |
| --- | --- |
| `POST /api/v1/runs/:run_id/signals` | 持久化 `{wait_id, name, payload, idempotency_key}`，返回信号回执；受理与消费分开 |
| `POST /api/v1/runs/:run_id/cancel` | 幂等受理取消，返回当前状态与取消期限 |
| `GET /api/v1/runs/:run_id` | 读取 run、step 摘要与最近事件（有界） |

权限由 `run_authorize/4` 决定，动作包括 `:view` / `:signal` / `:cancel` / `:start`。Run 归属项目、当前调用者、信号负载和目标等待节点都要参与校验。信号与取消入口按「项目 + 调用者 + Run」限流，超限返回 `LIMIT_EXCEEDED`；被拒绝和限流的请求同样计入 `fyrlet.run.signal`。

信号语义：

- 对已登记且未关闭的 `wait_id`，允许信号早于 Run 进入 `waiting` 到达；先写入收件箱，进入该等待节点后再消费。受理成功不代表已经推进。
- 收件箱插入、幂等结果和唤醒任务原子提交；消费信号、关闭等待节点与推进状态也原子提交。同一等待实例只消费一个有效信号。
- 同一幂等键与相同负载返回同一回执，负载不同返回冲突。错误名称、未知等待实例，以及针对终态或已关闭等待实例的新信号被拒绝；成功回执的重放不重复消费。
- 等待期限与信号竞争由同一状态锁决定；已经超时的等待节点不能被迟到信号复活。动态等待必须先登记 `wait_id`，再派发可能产生回执的外部请求。

取消语义：

- 取消与结果提交、Effect 派发认领竞争同一状态锁。受理后不再领取新 Step、消费信号或认领后续 Effect；未认领的 Effect 标为 `cancelled`。已提交认领事务的 Effect 按在途请求处理，即使外部调用尚未返回。
- 无执行中工作时可立即结束；有执行中工作时进入 `cancelling`，请求协作停止，并设置 `cancel_deadline`（默认 60 秒，可配置）。
- **在途 Effect 不阻塞取消终态**：Run 在执行器确认或期限到达后即进入 `cancelled`，不等待已认领 Effect 返回；Effect 继续按 [EFFECTS.md](EFFECTS.md) 记录真实结果（含 `unknown`），并在运行视图中独立展示。SDK 在 `cancelled` 的 Run 上仍须显示未结 Effect 的状态。
- 执行器确认后进入 `cancelled`，`cancellation_outcome: confirmed`；到期仍未确认时，使租约与代次失效并结束，标记 `fenced_timeout`。后者只表示禁止后续推进，不代表外部代码已停止。
- 取消后的迟到结果只记录，不调用推进逻辑。已经派发的副作用仍可能完成，Effect 继续记录真实结果；撤销或补偿必须是独立、显式的业务操作。
- SDK 区分“取消已受理”“已确认停止”和“超时后禁止推进”，不能把它们都展示为外部工作已停止。

## 运行视图（核心订阅）

框架注册内建订阅，无需业务重复实现：

| 名称 | 参数 | 输出 |
| --- | --- | --- |
| `fyrlet.run` | `run_id` | Run 状态、Step 摘要、等待原因、取消结果、Effect 摘要、最近 N 条事件与历史分页位置 |
| `fyrlet.runs.recent` | `limit` | 当前 Actor 可见的最近 run |

运行视图使用完整有界快照，复用失效通知、ACK 与断线重取路径。Run/Step/Effect 的可见变化都应触发刷新；事件与 Step 历史超过上限后分页读取，不能让长任务突破快照大小限制。

`fyrlet.runs.recent` 必须在查询阶段执行可见性过滤后再分页，不能先读取项目内全部 Run 再在客户端过滤。高频日志的增量传输使用追加订阅，见 [STREAMS.md](STREAMS.md)。

## 外部执行器协议

外部执行器负责领取、续租、上报结果与响应取消，复用核心执行所有权规则：

- 领取返回固定输入、定义版本、`attempt_id`、`lease_id`、`execution_epoch` 与到期时间。
- 续租与结果上报必须携带当前租约和代次；已过期、被取消或被替换的租约不能推进状态。**过期立即生效**：`lease_expires_at` 一过，心跳（不再续期）、状态查询（返回 `lease_valid: false` 并要求停止）和结果上报（返回 `LEASE_LOST`，只记一条 `attempt.late_result` 审计事件）都立刻拒绝，不必等恢复扫描或接管先发生。取舍：执行器干完了活但租约已过期、恢复扫描尚未接管时，这份结果会被丢弃并重做。进程内（`:internal`）步骤不心跳，不受此限，仍由恢复扫描处理。
- 同一尝试的相同结果重复上报幂等；不同结果冲突。无权限和过期租约的结果不得被当作有效完成。
- 执行器长轮询获取取消标记；取消受理后不延长执行租约，失联按取消期限处理。
- 执行器凭据按项目、队列和能力限制，可单独撤销；只能领取授权的工作，不等同于用户身份。

传输为 HTTP，取消标记用长轮询。需要能力 `executors`（服务端配置）。执行器凭据 `rtx_…`（`Fyrlet.Features.Executors.create/3`）限定项目与队列，可单独撤销，不是用户令牌。操作以 `executor: %{"default" => "队列", "步骤名" => "队列"}` 把步骤路由到队列；进程内工作者不领取带队列的步骤。

| 端点 | 作用 |
| --- | --- |
| `POST /api/v1/executor/claim` `{queues}` | 领取一个步骤，返回 `attempt_id`、`lease_id`、`execution_epoch`、`input`、`definition_version`、`lease_expires_at`；无工作时 `data` 为 `null` |
| `POST /api/v1/executor/attempts/:id/heartbeat` `{lease_id, epoch}` | 续租；取消受理后不再延长，返回 `cancel: true` |
| `GET /api/v1/executor/attempts/:id?lease_id=&epoch=&wait=` | 长轮询取消标记（`wait` 至多 25 秒）；租约已失效时返回 `cancel: true, lease_valid: false` |
| `POST /api/v1/executor/attempts/:id/result` `{lease_id, epoch, status, output \| error}` | 上报一次结果；同一结果重复上报返回 `duplicate`，不同结果冲突；租约失效返回 `LEASE_LOST`（409） |

执行器只能领取自己队列、自己项目的步骤，只能操作自己持有的尝试。服务端不托管也不运行执行器代码。

## 执行身份与代码版本

- 创建 Run 时记录发起者及一个由核心持久化的执行授权引用，限定项目、操作、资源范围与期限；不保存或重用原始用户令牌。
- 执行授权期限默认取 `min(Run 的 expires_at, 授权策略上限)`，创建时若授权期限短于 Run 计划的等待总时长则拒绝创建（`VALIDATION_FAILED`），避免长等待 Run 在中途因授权先过期而失败。
- 用户会话自然过期不自动取消已受理的 Run。每次领取新 Step 或认领 Effect 派发前复核执行授权；授权撤销后拒绝新工作并使 Run 失败。正在外部执行的请求仍需按真实结果记录。
- 查看、投递信号与取消仍按当前调用者重新授权。执行器凭据仅赋予执行指定尝试的能力，不自行扩大 Run 的业务权限。
- Run 固定 `definition_version`，关联适用的 Step 输入输出契约与实现。固定要通过 `definition_version → implementation` **显式注册**实现：仅记录版本号却仍调用被覆盖的同名模块，不构成版本固定。升级时保留活跃 Run 依赖的实现与契约。部署必须保留未结束 Run 所需版本；版本缺失时停止调度并以 `definition_unavailable` 等待原因告警，禁止静默使用新代码。
- 不提供运行中迁移；若将来提供，必须显式记录旧版本、新版本、状态映射与操作者，不能通过替换模块隐式改变既有 Run。
