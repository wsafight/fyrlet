# 数据库

PostgreSQL 是业务数据、幂等结果、持久任务和变更通知的唯一事实来源（原因见 [PRODUCT.md](PRODUCT.md#一致性与可靠性承诺)）。表结构的权威定义是迁移 [`priv/repo/migrations/20261106000000_create_fyrlet.exs`](../../priv/repo/migrations/20261106000000_create_fyrlet.exs)，Ecto schema 在 `lib/fyrlet/schemas.ex`、`lib/fyrlet/runs/schemas.ex`、`lib/fyrlet/effects/schemas.ex` 等处。本文解释**设计**——为什么这样建表、哪些约束承担了哪些保证、谁来清理——不逐列复述。

## 约定

- **主键是 UUID**（`binary_id`），时间都是 `utc_datetime_usec`，JSON 用 `map`（`jsonb`）。
- **每张租户表都带 `project_id`**，并对 `projects` 级联删除（`on_delete: :delete_all`）。项目隔离的第一道防线是查询里的 `project_id` 条件，不是数据库角色。
- **同项目复合外键**：`sessions`、`idempotency_results`、`fyrlet_runs` 的 `(subject_id, project_id)` 引用 `subjects(id, project_id)`，`sessions` 的 `(service_key_id, project_id)` 引用 `service_keys(id, project_id)`。所以 `subjects`、`service_keys` 上有 `(id, project_id)` 唯一索引。这保证一行记录的主体、密钥一定属于同一项目，即使应用代码出错也写不进跨项目的引用。
- **凭证只存哈希**：`service_keys`、`sessions`、`fyrlet_executors` 的 `token_hash` 是 SHA-256，且唯一。数据库里没有任何可直接使用的令牌。
- **热点路径用部分索引**：只索引活跃状态的行（运行中的 Run、待派发的 Effect、持有租约的尝试、匿名会话等），终态数据再多也不拖慢它们。
- **事件表只追加**：`fyrlet_run_events`、`fyrlet_effect_events` 在各自父行的锁下分配 `seq`，写入后不再改写。
- **有意不加外键的地方**：`fyrlet_execution_grants.initiator_subject_id`、`fyrlet_ingest_*.subject_id`、`fyrlet_run_attempts.project_id`、`fyrlet_stream_entries.project_id` 只存标识，不建外键。这是为写入路径省去外键检查，隔离由应用查询保证（`fyrlet_run_attempts` 仍随 Run 级联删除）。

## 表总览

| 分组 | 表 | 作用 |
| --- | --- | --- |
| 身份 | `projects`、`service_keys`、`subjects`、`sessions` | 项目、服务密钥、外部身份映射、短期会话（含匿名） |
| 幂等 | `idempotency_results` | 写入的幂等结果 |
| Run | `fyrlet_execution_grants`、`fyrlet_runs`、`fyrlet_run_steps`、`fyrlet_run_attempts`、`fyrlet_run_signals`、`fyrlet_run_events` | 持久运行的状态、步骤、租约、信号、审计事件，见 [RUNS.md](RUNS.md) |
| Effect | `fyrlet_effects`、`fyrlet_effect_events` | 外部副作用的意图与尝试记录，见 [EFFECTS.md](EFFECTS.md) |
| 执行器 | `fyrlet_executors` | 外部执行器凭据与队列 |
| 摄取 | `fyrlet_ingest_batches`、`fyrlet_ingest_items` | 批量摄取的受理记录 |
| 追加流 | `fyrlet_streams`、`fyrlet_stream_entries` | 追加订阅的流位置与条目，见 [STREAMS.md](STREAMS.md) |
| 任务队列 | `oban_jobs`、`oban_peers` | Oban 的表，由 `Oban.Migration` 创建 |

引用关系（缩进表示“引用上一级”）：

```text
projects
├─ service_keys
├─ subjects
│   ├─ sessions                 (同时引用 service_keys；匿名会话没有服务密钥)
│   ├─ idempotency_results
│   └─ fyrlet_runs              (同时引用 fyrlet_execution_grants)
├─ fyrlet_execution_grants
├─ fyrlet_runs
│   ├─ fyrlet_run_steps
│   │   ├─ fyrlet_run_attempts
│   │   └─ fyrlet_effects ─ fyrlet_effect_events
│   ├─ fyrlet_run_signals
│   └─ fyrlet_run_events
├─ fyrlet_executors
├─ fyrlet_ingest_batches ─ fyrlet_ingest_items
└─ fyrlet_streams           (fyrlet_stream_entries 只按 project_id + stream 关联，无外键)
```

## 身份与会话

- **`subjects`**：外部身份到内部主体的映射，`(project_id, issuer, external_id)` 唯一。客户端不能自行选择主体。
- **`sessions`**：`kind` 为 `user` 或 `anonymous`。匿名会话没有服务密钥，所以 `service_key_id` 可为空。`expires_at` 到期、`revoked_at` 撤销；`sessions_anonymous_index`（只含匿名会话）支撑匿名入口的签发速率与活动数统计。写入事务对会话加 `FOR SHARE` 锁，撤销用更新锁，所以撤销返回后旧会话不能再提交写入（见 [AUTH.md](AUTH.md#授权与隔离)）。
- **`service_keys`**：`revoked_at` 只阻止签发新会话，不影响既有会话。

## 幂等

`idempotency_results` 在 `(project_id, subject_id, operation, key)` 上唯一，保存规范化输入的哈希 `input_hash` 与完整返回值 `result`。相同键与相同输入重放原结果，不同输入返回冲突；并发提交靠这个唯一约束保证最多写入一次。`expires_at` 上有索引，供清理使用。它与业务数据、Oban 任务在同一事务提交。

## Run

- **`fyrlet_runs`**：`status` 驱动状态机；`execution_epoch` 在每次领取步骤时递增，旧执行者的结果凭它被隔离；`event_seq`、`current_step_seq` 是给事件和步骤分配序号的计数器。`(project_id, operation, business_key)` 上的**部分唯一索引只覆盖非终态**的 Run，所以“同一业务键同时只有一个活跃 Run”，已结束的 Run 不阻挡新建。
- **`fyrlet_run_steps`**：`(run_id, seq)` 唯一；`queue` 非空表示交给外部执行器，对应的部分索引只含待领取的步骤；等待节点用 `wait_deadline` 的部分索引找超时。
- **`fyrlet_run_attempts`**：一次尝试一条租约（`lease_id`、`lease_expires_at`、`execution_epoch`）。`project_id` 是**有意冗余**的：“这个项目现在持有多少租约”在每次领取前都要问，有它就不必把全系统的租约与 Run 做连接；`(project_id, lease_expires_at)` 的部分索引只含持有租约的行。
- **`fyrlet_run_signals`**：`(run_id, idempotency_key)` 唯一，相同键重放返回同一回执。
- **`fyrlet_execution_grants`**：Run 创建时记录的执行授权，不保存用户令牌。

Run 删除时，步骤、尝试、信号、事件、Effect 都级联删除。

## Effect

`fyrlet_effects` 在 `(step_id, effect_key)` 上唯一，同一步骤的同一副作用不会重复创建；`operation_id` 是发给接收方的稳定幂等键。`fyrlet_effects_open_index` 只含 `pending / claimed / accepted / unknown` 的行，派发和对账靠它找活。`fyrlet_effect_events` 记录每次尝试和人工决定，`(effect_id, receipt_id)` 的部分唯一索引使同一回执只被记录一次。

## 执行器、摄取与追加流

- **`fyrlet_executors`**：凭据哈希唯一，`queues` 限定它能领取的队列。
- **`fyrlet_ingest_items`**：`(project_id, subject_id, operation, item_key)` 唯一，“一个键一条记录”使重发批次无害；`fyrlet_ingest_pending_index` 只含待处理项，`fyrlet_ingest_finished_index` 只含已处理项并按处理时间排序，供保留期清理使用。
- **`fyrlet_streams`**：复合主键 `(project_id, name)`，每流一行。`head` 是最后分配的位置，追加者对这一行持锁直到提交，所以位置按提交顺序可见、不会出现空洞；`epoch` 在流被重写时变化，使此前的游标全部失效；`trimmed_before` 是被裁剪掉的位置边界。
- **`fyrlet_stream_entries`**：复合主键 `(project_id, stream, pos)`，`bytes` 记录条目大小用于窗口预算。

## 清理与保留

`Fyrlet.PruneWorker`（Oban 定时任务，每 10 分钟）分批清理，单批不持有长锁。

| 表 | 清理条件 | 说明 |
| --- | --- | --- |
| `idempotency_results` | `expires_at` 已过 | 保留期默认 24 小时（`idempotency_ttl`），即客户端可安全重试同一键的窗口 |
| `sessions` | `expires_at` 过期超过 24 小时 | |
| `subjects`（仅匿名） | 发行者为 `anonymous`，且没有未过期（24 小时内）的会话 | 其会话随主体级联删除 |
| `fyrlet_runs` 及其子表 | 终态且 `finished_at` 超过 `terminal_retention`（默认 30 天） | **仍有未决 Effect 的 Run 不删** |
| `fyrlet_run_signals` | 终态 Run 的信号，超过 `signal_retention`（默认 7 天） | |
| `fyrlet_execution_grants` | 不再被任何 Run 引用 | |
| Run 的输入输出负载 | `payload_retention`（默认不启用） | 只清除内容，保留标识、状态、时间戳、哈希和审计事件 |
| `fyrlet_stream_entries` | 每流保留最近 `retention_items` 条（默认 10 000） | |
| `oban_jobs` | Oban 的 pruner（已完成作业保留 1 小时） | |
| `fyrlet_ingest_items`、`fyrlet_ingest_batches` | 条目已处理（`done` / `dead`）且超过 `ingest_seconds`（默认 7 天，可按项目覆盖，`nil` 永久保留）；批次在条目清空后一并删除 | **待处理（`pending`）的条目无论多旧都不删**。这个保留期同时是重发批次仍被识别为重复的窗口，过了之后相同的键会被当作新数据处理 |
| `fyrlet_stream_entries`（项目删除时） | **不会级联** | 它没有指向 `projects` 的外键；删除项目需同时清理这张表 |
| `fyrlet_executors`、`service_keys`、真实用户的 `subjects` | 不清理 | 撤销只置 `revoked_at` |

### 按项目配置保留期

保留期有一个全局默认，也可以给个别项目单独设置（`Fyrlet.Retention`）：

```elixir
config :fyrlet,
  retention: [
    default: [ingest_seconds: 604_800],                       # 所有项目默认 7 天
    projects: %{
      "7c1f…" => [ingest_seconds: 86_400],                    # 这个项目只留 1 天
      "9a2e…" => [ingest_seconds: nil]                        # 这个项目永久保留
    }
  ]
```

项目条目只覆盖它写出的键，没写的用默认；`nil` 表示永久保留（作为默认值时表示关闭清理）；秒数至少 60，写错会让应用启动失败。默认值也可用环境变量 `FYRLET_INGEST_RETENTION_SECONDS` 设置（秒数或 `forever`）。按项目覆盖只能写在应用配置里。

**目前只有摄取保留期支持按项目设置。** 上表其余的期限（幂等结果、会话、终态 Run、信号、追加流条数）仍是全局配置。

容量估算与相关配置见 [OPERATIONS.md](OPERATIONS.md#数据保留与容量)。

## 宿主应用的表

宿主应用与 Fyrlet 共用同一个 `Fyrlet.Repo`，这样业务写入、幂等结果和失效通知才能在一个事务里提交（见 [INSTALL.md](INSTALL.md#共享仓库的约束)）。宿主的业务表应当：

- 带 `project_id` 与 `subject_id`，并建议加上同样的复合外键 `(subject_id, project_id) → subjects(id, project_id)`；
- 每个私有查询都在 SQL 里同时约束 `project_id` 与 `subject_id`；
- 迁移放在宿主自己的目录并写进 `migration_paths`，版本号排在核心迁移之后。

插件只能创建以插件名为前缀的新表，不得修改或重建 Fyrlet 的表（见 [PLUGINS.md](PLUGINS.md#插件-api)）。

## 迁移

核心迁移只有一份（含 Oban 的表），`up` / `down` 都能完整执行，`down` 会清空 Fyrlet 与 Oban 的表。执行方式：

```sh
mix fyrlet.migrate --create          # 核心、宿主和插件的迁移一次执行
bin/app eval "Fyrlet.Release.migrate()"   # 发布版本
```

项目尚未发布，迁移在发布前仍可能调整；开发库如果执行过更早的迁移，请重建数据库。
