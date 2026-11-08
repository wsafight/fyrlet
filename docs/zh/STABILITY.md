# 稳定性采样与阈值关卡

[English](../STABILITY.md) | 简体中文

`scripts/stability.mjs` 运行现有的同机 Chat／Agent 集群负载，独立采样 `chat_cluster` 与 `agent_cluster`，收集 Chat 节点遥测，并可执行显式、带版本号的阈值配置。它不能证明多主机容错、生产容量或生产 SLO。

## 安全默认值与运行标签

现有 CLI 继续有效：

```sh
# 短时正确性演练；不运行阈值关卡。
node scripts/stability.mjs --seconds 30 --clients 4 --sample-ms 5000

# 完整时长的正确性运行；86400 秒也是默认值。
node scripts/stability.mjs --seconds 86400 --clients 20
```

未指定 `--profile` 时，`thresholdGate.status` 为 `not-run`；运行完成只代表正确性可以通过，不代表任何资源阈值通过。默认值保持 86,400 秒、20 个客户端、数据库采样间隔 30,000 ms、基础端口 4250。限制保持 5–86,400 秒、2–50 个客户端、1,000–60,000 ms 采样间隔及端口 1024–65530。离线辅助逻辑测试不会启动 24 小时负载。

每次少于 86,400 秒的运行都标记为 `short-smoke-correctness-only`，包括用短时运行调试阈值配置的情况；绝不会把 `stability24h` 或 `productionSLO` 标为已验证。24 小时配置通过也只记录同机阈值关卡结果，不是生产 SLO 认证。

包装器拒绝 `CLUSTER_DATABASE_URL` 覆盖，只构造 PostgreSQL 55432 端口上固定的回环 `chat_cluster` 与 `agent_cluster` URL。**负载会迁移并写入这些数据库；它们不是每次运行新建的一次性数据库。** 不要对存有重要本地数据的现有数据库运行包装器。已有报告文件和每次运行日志不会覆盖，且源码指纹必须保持不变。

## Schema 准备、基线与看门狗

在启动 `scripts/cluster.sh` 或任何 fixture 写入之前，包装器会：

1. 分别对固定的 Chat 与 Agent 示例应用／数据库运行 `mix fyrlet.migrate --create --quiet`，迁移输出进入本次运行的私有日志。
2. 为每个数据库打开一个只读采样连接池，并成功查询**两个**数据库的全部必需表。缺表或基线查询失败会在负载启动前中止。
3. 把每个数据库首个成功样本保存为对应数据库的增长基线，并写入带 `baselinePersisted: true` 的 running 报告。只有该写入完成后才启动负载。

因此 fixture 写入不会与基线竞争。集群脚本之后可能重复执行幂等迁移，但其 fixture 与负载只会在基线持久化后启动。

外层看门狗预算为：

```text
(requested seconds + max(60, ceil(requested seconds / 20)) + 600) * 1000 ms
```

中间项是内部 Chat soak 测试自身的宽限时间，包括 soak 后的全量历史核对；额外 600 秒是准备／收尾预算。因此 24 小时运行的外层预算为 91,320 秒，不会在 soak 后仅十分钟就被停止。

看门狗与信号处理器会持续安装到最终源码指纹检查、清理及最终报告持久化阶段。即使负载正确性已经完成，后期 SIGINT、SIGTERM 或看门狗到期仍会使报告失败、进程非零退出。只有最终持久化后才清除 timeout。初始报告建立后的错误会经过脱敏，并尽力写入 failed／finished 报告。如果最终写入本身遇到文件系统故障，仍可能无法持久化；此时会向 stderr 输出脱敏错误并非零退出。

## 版本 1 JSON 配置

使用 `--profile FILE`。文件最大 64 KiB，必须只含一个带 `workload` 与 `limits` 的版本 1 对象。三个 workload 字段均为必填。未知字段、缺少必填字段、类型错误、非有限数／负数、范围无效、空 `limits` 或空 `tableRowGrowth` 都会在迁移或负载执行前被拒绝。

```json
{
  "version": 1,
  "workload": {
    "seconds": 86400,
    "clients": 20,
    "sampleMs": 30000
  },
  "limits": {
    "memoryGrowthBytes": 536870912,
    "databaseGrowthBytes": 1073741824,
    "tableRowGrowth": {
      "sessions": 1000,
      "idempotency_results": 250000,
      "jobs": 1000
    },
    "pendingRuns": 10,
    "pendingAgeSeconds": 60,
    "unresolvedEffects": 0,
    "databaseLockWaiters": 0,
    "poolQueuePerQueryMs": 5,
    "sampleGapMs": 45000
  }
}
```

以上数字只用于说明结构，**不是默认值、推荐生产限制或 SLO**。应根据目标负载、基线测量、保留策略及运行环境选择限制。至少设置一个限制；其余支持的限制均可选，表增长对象可选择三张表中任意非空子集。比较包含等号：`observed <= limit` 即通过。零也是有效的显式限制。

只要选择了数据库增长、表、pending、Effect 或锁阈值，就必须设置 `sampleGapMs`，且该限制独立应用于两个数据库。只含内存／连接池限制的配置不要求该字段。

`--seconds`、`--clients` 与 `--sample-ms` 覆盖配置中的对应负载值；`--base-port` 与 `--out` 仍只能由 CLI 指定。报告记录实际生效的数值负载和已验证限制，不记录配置路径或任意输入字段。

```sh
node scripts/stability.mjs --profile .local/readiness/stability-profile.json

# 短时配置调试运行仍只属于正确性证据。
node scripts/stability.mjs --profile .local/readiness/stability-profile.json \
  --seconds 30 --clients 4 --sample-ms 5000
```

## 必需的数据库采样覆盖

每个已选数据库阈值（包括 `sampleGapMs`）都要求 Chat 与 Agent 分别满足以下全部条件：

- 至少有 `max(2, ceil(seconds * 1000 / sampleMs) + 1)` 个成功样本。24 小时、30 秒采样间隔需要 2,881 个样本，两个孤立端点不能通过。
- 样本时间戳有效且严格递增。
- 基线样本不晚于 `workloadStartedAt`，最终样本不早于 `workloadFinishedAt`。
- 基线到负载开始、相邻成功样本、负载结束到最终样本这三类间隔的最大值不得超过 `sampleGapMs`。

如果数量、单调性、开始／结束覆盖或时间戳无效，该数据库所有已选观测值均为 `unverified`，不会把两个点的增长当作通过。采样查询失败与不完整运行也会独立阻止运行成功。Agent 样本流缺失时绝不借用 Chat 样本。

离线评估必须提供 `samples: { chat: [...], agent: [...] }` 和 `runWindow: { workloadStartedAt, workloadFinishedAt }`；时长与采样节奏来自 profile。裸数组或数据库样本流缺失都是无效证据，只会得到 `unverified`，不会推断为 Chat 单库通过。

## 阈值的准确含义

数据库限制分别应用于 `chat_cluster` 与 `agent_cluster` 各一次。检查名和结果摘要使用 `chat.` 或 `agent.` 前缀。只评估包装器及当前 Chat 集群报告已经产生的指标。证据缺失、畸形或不可用时得到 `unverified`，绝不假定其值为零或通过。

| 配置限制 | 每个数据库的观测值与所需证据 |
| --- | --- |
| `databaseGrowthBytes` | `pg_database_size(current_database())` 峰值减去该数据库已持久化基线，最小计为零。取峰值可保留最终大小回落前的中间增长。 |
| `tableRowGrowth.sessions` | `sessions` 行数峰值减去同一数据库的基线，最小计为零。 |
| `tableRowGrowth.idempotency_results` | `idempotency_results` 行数峰值减去其基线，最小计为零。 |
| `tableRowGrowth.jobs` | `oban_jobs` 行数（报告中为 `jobs`）峰值减去其基线，最小计为零。 |
| `pendingRuns` | 状态为 `pending` 的 `fyrlet_runs` 采样计数最大值。 |
| `pendingAgeSeconds` | 采样 `oldest_pending_seconds` 最大值，由最老 pending Run 的 `inserted_at` 得出；现有查询在没有 pending Run 时返回零。 |
| `unresolvedEffects` | `resolution_required` 为真或状态为 `unknown` 的 Effect 采样计数最大值。 |
| `databaseLockWaiters` | 当前数据库 `pg_stat_activity` 中 wait event type 为 `Lock` 的采样行数最大值。这是等待者数量，不是锁等待时长。 |
| `sampleGapMs` | 上述成功样本最大间隔，包括预期的负载开始／结束覆盖。 |

两个非数据库限制使用 Chat soak 样本：

- `memoryGrowthBytes`：对每个 Chat 节点计算峰值 `memory_bytes` 减去该节点初始值，再取各节点最大值。需要初始节点集合以及至少两个完整且节点一致的样本。这是 BEAM VM 内存遥测，不是 OS RSS，也不是泄漏速率估计。
- `poolQueuePerQueryMs`：对两个 Chat 节点及所有相邻节点样本区间，累计 `db_queue_microseconds` 的非负增量之和除以 `db_queries` 增量之和，再换算为毫秒。要求总查询增量为正且计数器单调。这是每次已发出 DB 查询的算术平均值，**不是**最大值、百分位，也不是只对实际等待查询求平均。计数器回退或查询增量为零时为 unverified。

Agent 报告没有等价的节点内存／连接池序列。包装器不会推断 Agent 内存、单表字节数、锁等待时长、连接池等待百分位、OS RSS 或整台主机的资源占用。峰值减基线的增长限制不能证明泄漏速率，平均连接池排队比也可能掩盖个别慢等待。

## 每数据库结果、日志与退出状态

`result.json` 分别保存 `samples.chat` 与 `samples.agent`，每数据库采样计数位于 `databaseSampling`。每项阈值检查包含固定名称、`database` 字段（`chat`、`agent`，节点级检查则为 `null`）及数值证据：

```json
{
  "name": "agent.databaseGrowthBytes",
  "database": "agent",
  "status": "failed",
  "observed": 1073741825,
  "limit": 1073741824,
  "unit": "bytes",
  "aggregation": "peak-minus-baseline-sample"
}
```

`thresholdGate.databaseResults.chat` 与 `.agent` 分别包含独立的 `status`、`violations`、`unverified` 与 `samplingCoverage` 摘要。因此，仅 Agent 违反阈值会使 Agent 和总关卡失败，但不会改变 Chat 的通过观测。检查状态为 `passed`、`failed` 或 `unverified`；顶层 `violations` 只列出实际 `observed > limit` 的失败。

关卡状态如下：

- `not-run`：未选择配置，不声称得到任何阈值结果。
- `running`：准备或负载运行时的初始状态。
- `passed`：运行及必要采样完成，且所有已选检查通过。
- `failed`：阈值违反、证据 unverified，或带关卡运行不完整／被中断。

实际阈值违反、负载不完整／失败、采样失败、源码变化、配置无效、中断或所需证据不可用都会使进程以非零状态退出。unverified 或 not-run 绝不会转成关卡通过。阈值结果只含固定名称、单位、聚合方式、状态、数据库标识及数值／布尔覆盖证据；数据库错误、机密及任意配置内容不会复制到其中。

唯一报告目录包含 `cluster.log`，以及 `cluster/chat-node-0.log`、`cluster/chat-node-1.log`、`cluster/agent-node-0.log`、`cluster/agent-node-1.log`。这些每次运行日志以 0600 创建；报告／集群目录请求以 0700 创建。此包装器之外的默认集群 fixture 保留原有日志行为。

## 离线辅助逻辑测试

```sh
node --test bench/test/stability.test.mjs
node --test bench/test/readiness.test.mjs
npm --prefix bench test
```

专项测试使用合成的独立数据库样本流与临时配置文件，不启动集群、不连接 PostgreSQL、不运行迁移、不运行 24 小时负载，也不验证生产阈值数值。
