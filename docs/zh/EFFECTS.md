# Effect 与 Outbox

外部副作用（发邮件、调用第三方 HTTP 等）不能放进数据库事务里。Effect 把**意图**和本地事务一起提交，由统一的派发器在事务外执行，并如实记录不确定的结果。Outbox 保证意图与本地事务一起提交，**不自动保证外部系统只执行一次**。

Effect 总是归属某个 [Run](RUNS.md) 的 Step。适配器协议、重试规则和人工处置见下文；开发者视角的用法见 [SERVER.md](SERVER.md)。

## 问题

写入的幂等只覆盖同一数据库事务内的写入（见 [PRODUCT.md](PRODUCT.md) 的 FR-04）。外部副作用需要统一记录外部工作的意图、派发尝试与不确定结果，并按适配器能力声明重试边界。Outbox 保证意图与本地事务一起提交，不自动保证外部系统只执行一次。

## 模型

表 `fyrlet_effects`：

| 字段 | 说明 |
| --- | --- |
| `operation_id` | 持久化的稳定业务请求 ID；作为对外幂等键，重试复用 |
| `project_id` / `run_id` / `step_id` / `effect_key` | 归属与逻辑唯一键；同一 Step 的同一 Effect 不重复创建 |
| `adapter` / `adapter_version` / `delivery_policy` | 适配器、能力版本与明确的重试策略 |
| `payload` / `payload_hash` | 固定的规范化请求，不含凭据；同一逻辑键对应不同请求时冲突 |
| `status` | `pending`（待派发）/ `claimed`（已认领、外部调用进行中或结果未回写）/ `accepted`（接收方已受理，等待回执或查询）/ `succeeded` / `failed` / `unknown` / `cancelled` |
| `lease_id` / `execution_epoch` / `lease_expires_at` | 派发所有权与旧结果隔离；独立于 Step Attempt 租约（见 [RUNS.md](RUNS.md#状态与数据)） |
| `attempts` / `claimed_at` / `next_attempt_at` | 尝试记录与调度；`claimed_at` 不代表外部已执行 |
| `secret_ref` | 适配器所需凭据的引用名；凭据本体由适配器在派发时从项目密钥存储解析，不进入 `payload`、日志与事件 |
| `external_ref` / `result` / `last_error` / `resolution_required` | 外部引用、已知结果与人工处置标记 |

规则：

1. Step 返回 Effect 意图后，核心在同一事务中创建 Effect、将 Step 置为 `awaiting_effect`（释放当前 Attempt 租约，Run 的 `wait_reason` 为 `effect`），并创建派发任务；事务回滚则三者均不存在。
2. 仅统一的 Effect dispatcher 可以派发。Oban 唤醒 dispatcher；Step 执行器不能再次直接调用适配器。派发认领先在短事务中记录租约与 `claimed`，外部调用在事务外完成。
3. 派发进程失联或响应不确定（`claimed` 且租约过期、或适配器返回 `:unknown`）时进入 `unknown`，不能因为本地没有成功记录就判定外部未执行。
4. Effect 完成与 Step 输出、后续推进同事务提交；Run 已取消或过期时只保存 Effect 的真实结果，不推进 Run。
5. 幂等保证取决于接收方对稳定业务键的约束及保留窗口。**查询对账不等于去重；框架不统一承诺 exactly-once 或至多一次外部副作用。**

适配器必须声明能力与策略：

| 外部能力 | 允许的默认行为 | 保证边界 |
| --- | --- | --- |
| 幂等键或唯一业务键 | 在有效幂等窗口内复用 `operation_id` 重试 | 去重依赖接收方契约；超过窗口不能继续宣称安全重试 |
| 仅可查询结果 | 优先对账；结果不明时暂停派发 | 查不到可能仍在处理中，不能据此证明可安全重发 |
| 无幂等、无查询 | 不确定结果暂停并要求人工处置 | 仅业务显式选择 `retry_allow_duplicates` 后允许可能重复的重发 |

确定未执行的临时失败可按退避重试；不确定失败不能伪装成“确定未执行”。自动重试期限不得超过供应商去重窗口，相关能力未知时按不支持处理。

## 适配器协议

```elixir
defmodule Fyrlet.Effects.Adapter do
  @callback capabilities() :: map()
  @callback dispatch(effect :: map()) ::
              {:succeeded, term()} | {:accepted, term()} | {:failed, term()} |
              {:retryable, term()} | :unknown
  @callback query(effect :: map()) ::
              {:succeeded, term()} | {:failed, term()} | :pending | :not_found | :unknown
  @callback cancel(effect :: map()) :: :ok | {:error, term()}
  @optional_callbacks query: 1, cancel: 1
end
```

`capabilities` 至少声明幂等方式与有效期、是否可查询、是否可撤销，以及成功结果代表“供应商受理”还是“最终业务完成”。例如邮件服务受理不能自动解释为用户已收到邮件。

`accepted` 使 Effect 进入 `accepted` 状态，等待可验证的回执或查询结果（回执经受限集成主体调用核心 API 提交，见 [PROTOCOL.md](PROTOCOL.md#副作用回执)）；`retryable` 只用于适配器能够确认尚未产生业务效果的失败。查询的 `not_found` 本身不是安全重发依据。

`unknown` 的处置：支持查询时按退避对账；超过 `effect_reconcile_ttl`（默认 24 小时）后仍保持 `unknown`，设置 `resolution_required: true` 并告警，不自动转成 `failed`。只有可信结果证明失败时才进入 `failed`。人工确认、放弃等待或允许重发必须记录证据、操作者和决策，不能覆盖原始尝试记录。

客户端可读取 Effect 状态；依赖该结果的操作可返回 `EFFECT_UNKNOWN`（HTTP 409，`retryable: false`），禁止 SDK 因该错误自动重发外部业务。

## 与写入路径的关系

- `write` 仍保持“事务提交即成功”，成功只表示本地业务写入完成，不代表任何外部工作完成。受管写入回调不得直接调用外部系统。
- Effect 必须归属 Run/Step；只需异步投递的业务也可使用单 Step Run。不提供由独立 write 直接产生 Effect 的 API，避免两套调度与完成语义。
- 请求幂等窗口、Effect 对账窗口、供应商去重窗口与 Run 历史保留期分别配置。未解决 Effect 的逻辑唯一键和尝试记录不能随请求幂等记录一起清理。
