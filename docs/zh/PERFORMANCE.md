# 性能对比

测量日期：2026-11-07。本文只保留最新一次的 Fyrlet / Meteor 同资源对照，以及共享房间与追加流的端到端对照；优化的做法、证据和回退的试验见 [OPTIMIZATIONS.md](OPTIMIZATIONS.md)。更早几轮的历史报告已移除，其结论不再作为依据。

原始运行数据在本机 `.local/fair/`（已被版本控制忽略），不随仓库提交。对照条件与结论门槛见 [bench/FAIRNESS.md](../../bench/FAIRNESS.md)。

## 结论边界

- 这是**单核组**（应用各 1 vCPU / 1 GiB）、**单机虚拟机**里的结果，每个负载点 2 次重复，负载持续 20 秒。
- 趋势明确：500 writes/s 下 Fyrlet 完成了绝大部分目标写入，Meteor 只完成 20–29%。但 Meteor 的重复间波动很大，**不能据此给出稳定倍数**。
- 双方业务保障**没有对齐**（见下文“没有对齐的条件”）。不能把它当成“同保障下的引擎排名”。
- 没有做多核组、长时间稳定性、冷启动与断线恢复对照。

## 测试条件（已由操作系统强制）

| 项目 | 配置 |
| --- | --- |
| 环境 | Colima Linux 虚拟机（10 vCPU / 24 GiB），Docker 容器，cgroup v2 |
| 应用 | Fyrlet 与 Meteor 各 `--cpus 1 --memory 1g --memory-swap 1g`，`--cpuset-cpus 0` |
| 数据库 | PostgreSQL 17 与 MongoDB 7.0（副本集 + oplog）各 2 vCPU / 2 GiB，`cpuset 1-2` |
| 生成器 | 独立容器，`cpuset 4-9`，与应用和数据库不共享核 |
| 构建产物 | Fyrlet：`mix release`；Meteor：`meteor build` 的 production bundle，Node 24.22.1 |
| 负载 | 1000 用户 × 2 设备（3000 连接），`sessions=shared`，每用户 50 条 × 128 B，20 秒，concurrency 64，warmup 1，timeout 60 秒 |
| 顺序 | Fyrlet / Meteor / Meteor / Fyrlet 交替；每轮重新灌数据 |
| 限额证据 | 每轮前后读取容器 cgroup 的 `cpu.stat`（usage、nr_throttled）、`memory.events`（oom_kill）、`memory.peak` |
| BEAM | cgroup 下 `schedulers_online=1`（宿主 10 核） |

容器的文件描述符软限制默认只有 1024，3000 个连接会卡在约 1050 个；双方应用和生成器都提高到了 65536。

## 对照结果

| 轮 | 实现 | 目标 writes/s | 完成写入 | 传播 P95 ms | 应用 CPU 秒 | 被节流周期 | 应用内存峰值 MiB* | OOM |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Fyrlet | 500 | 9732 | 9.74 | 15.3 | 1 | 636 | 0 |
| 2 | Meteor | 500 | 2917 | 498.84 | 34.1 | 22 | 554 | 0 |
| 3 | Meteor | 500 | 1995 | 933.48 | 38.8 | 21 | 539 | 0 |
| 4 | Fyrlet | 500 | 9895 | 1.98 | 12.4 | 3 | 727 | 0 |
| 5 | Fyrlet | 100 | 2000 | 3.25 | 6.8 | 2 | 680 | 0 |
| 6 | Meteor | 100 | 2000 | 14.15 | 31.1 | 3 | 553 | 0 |
| 7 | Meteor | 100 | 2000 | 253.96 | 35.6 | 5 | 524 | 0 |
| 8 | Fyrlet | 100 | 1975 | 4.56 | 9.5 | 1 | 627 | 0 |

\* `memory.peak` 含页缓存，不等于 RSS，只适合比较同一实现内部的相对变化。应用 CPU 秒包含建连与预热阶段，100 writes/s 时建连占比大，不能直接除以写入数当作 CPU/写入。

读数：

- 500 writes/s：Fyrlet 完成约 97–99% 的目标写入；Meteor 只完成 20–29%，CPU 被节流 21–22 个周期，即已打满 1 核。
- 100 writes/s：双方都完成了全部目标写入。Fyrlet 的 P95 为 3.3 与 4.6 ms；Meteor 的两次分别是 14.2 与 254.0 ms，相差 18 倍，只能说明 Meteor 在此负载下已接近单核上限，给不出稳定数值。
- 两边内存都在 1 GiB 内，没有 OOM。
- 所有轮次的最终完整视图都校验正确，已接受写入的中间投递覆盖率为 100%。

### 为什么没有测更高速率

*更新（分片生成器）：* 生成器现在可以拆到多个进程（`GENERATORS=N`，见 [`bench/fair/`](../../bench/fair/README.md)）。在 1 vCPU、1000 writes/s 的一组对照里，单个生成器进程自己丢了 20000 个 tick 中的 5204 个，4 个分片只丢 271 个，所以这个速率下生成器不再是最先到极限的一环。这**不能**说明服务端的容量：同样的 4 分片配置重复运行，完成的写入占比从 70% 到 99% 不等（13.9k/20k、26.9k/30k、28.1k/30k、19.9k/20k），而 1000 writes/s 正处在一个 vCPU 能持续承受的边缘。要得到容量，需要做速率扫描，每个点至少 3 次交替重复。下文描述的是此前单生成器的运行。

把目标速率提到 900 和 1300 writes/s 时，是**负载生成器**（单线程 Node）先掉拍（`generatorDropped`），Fyrlet 的 cgroup 节流为 0。按 FAIRNESS.md 的规则，生成器掉拍的点不能证明服务端容量上限，所以这套对照给不出 Fyrlet 的容量上限。

## 没有对齐的条件

- **鉴权保障**：Fyrlet 每次推送前重新读会话，检查过期与撤销，写入事务对会话加 `FOR SHARE` 锁并用 advisory lock 串行化同 key 请求，另有持久化的兜底通知。Meteor 只在登录与订阅时检查一次会话，到期靠定时器。Fyrlet 做的事更多。
- **写确认强度**：Meteor 的写入用 MongoDB 多文档事务，`readConcern: snapshot` 加 `writeConcern: majority`；PostgreSQL 一侧使用默认提交。两边没有逐项对齐，这一点对 Meteor 不利。
- **架构固定成本**：Meteor 在单个 Node 事件循环里同时处理 DDP、EJSON、oplog 监听与每连接的 mergebox，一核限额下互相争用；Fyrlet 对同一订阅只计算一次。这是读代码得出的推断，**没有对 Meteor 做 CPU 剖析**。
- 多核组（4 vCPU / 4 GiB，Meteor 多进程加粘性代理）未做；数据库刷盘与写确认未逐项对齐；负载只覆盖“更新已有记录”。

## Fyrlet 单核剖析（500 writes/s）

稳定写入阶段，用 `:msacc` 与按进程类型汇总的 reductions 观察：

- 调度器约 53% 忙，**500 writes/s 在 1 vCPU 下并未使 Fyrlet 饱和**。
- reductions 占比：写入处理（`OperationChannel`）约 51%，Bandit 连接进程约 9%，会话检查分片合计约 10%，Oban 生产者约 5.8%，Observer 约 5%。
- 把应用压到 0.4 vCPU 才使 CPU 成为瓶颈，但同一基线两次重复就差约 ±20%（完成写入 7464 对 9909），能测出的收益需要至少 3 次交替重复。
- 曾设想把 advisory lock 与幂等 SELECT 合并成一条语句，**不成立**：READ COMMITTED 下同一语句内等锁后快照已固定，会读不到刚提交的幂等行，导致重复执行。

写入路径剩下的候选（会话检查与 advisory lock 合并、幂等先插占位行）预计各省 1 次数据库往返，约 10% 量级，低于当前噪声，未实施。

## 复现与现状

**Fyrlet 一侧**现在可以用 [`bench/fair/`](../../bench/fair/README.md) 里的脚本复现（受限 PostgreSQL、release 镜像、单次运行、A B B A 交替、分片生成器）。**Meteor 一侧**（Dockerfile、MongoDB 副本集、运行器）仍只在本机 `.local/fair/`，含本机绝对路径，尚未整理成可复用工具。最初的复现步骤是：

1. 用 `mix release` 构建 Fyrlet 镜像（运行层需与构建层的 glibc 版本一致，本次用 `debian:trixie-slim`）；用 `meteor build --server-only --architecture os.linux.aarch64` 打 Meteor bundle 并装进 `node:24.22.1`。
2. 在 Linux 虚拟机里用 `--cpus`、`--memory`、`--memory-swap`、`--cpuset-cpus` 起应用、数据库和生成器容器，并把文件描述符限制提高到 65536。
3. 用 `bench/runner.mjs --endpoint ... --fixtures ...` 的外部端点模式运行，每轮重新灌数据，交替执行顺序，并在运行前后读取容器 cgroup 计数。

Fyrlet 的灌数据用 `bench/fixtures/seed.exs`；Meteor 用 `bench/adapters/meteor.mjs` 的 `seed()`，`runId` 必须符合 `bench-<数字>-<8 位十六进制>`。

## 仍未覆盖

端到端的新增/删除压测、24 小时稳定性、多核组、Meteor 的 CPU 剖析、鉴权与写确认保障对齐、冷启动与断线恢复对照。

## 共享房间与追加流端到端对照（2026-11-07）

本组使用 Chat 领域应用、真实 PostgreSQL / HTTP / WebSocket。25 个不同主体、不同会话的用户加入同项目房间，逐次写入后等待全部客户端收到对应内容。每模式每轮 20 次写入，共 3 轮；消息模式先填满 100 条实时窗口，每条文本 128 字节。SDK 关闭字段级 `delta-v1`，分别比较普通私有快照与 `sharing: identical`、全量消息快照与 append。原始报告：[shared-2026-11-07.json](../bench/shared-2026-11-07.json)。

| 模式 | 每轮视图构建 | 每轮快照数据编码 | 每轮数据库查询 | 每轮下行应用载荷字节 | 每轮 p50 范围（ms） | 每轮 p95 范围（ms） |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 房间私有快照 | 500 | 500 | 2435–2478 | 240300 | 14.04–15.24 | 16.66–21.57 |
| 房间公共共享投影 | 20 | 20 | 1586–1590 | 240300 | 13.33–13.78 | 14.21–16.28 |
| 最近 100 条消息全量快照 | 500 | 500 | 3036–3053 | 13531300 | 13.51–14.32 | 14.87–25.35 |
| 最近 100 条消息 append | 0 | 0 | 2330–2358 | 209300 | 13.93–16.20 | 15.45–18.79 |

相同房间投影的查询构建和快照数据编码均减少 **96%**，从每次更新 25 份降为 1 份；每连接封套与网络发送仍保留，因此共享前后下行载荷相同。编码计数来自实际 `fyrlet.subscription.serialize` 调用，不由连接数推算，也不包含每连接协议封套编码。消息 append 相对发送整个 100 条窗口减少 **98.45%** 下行应用载荷；它没有走普通 Observer 的快照编码路径，表中 0 不表示没有序列化成本。

三个 append 正常更新轮次中 `gap` / `overflow` / `refresh` 回退均为 0。每轮另对一个订阅显式刷新，断言恰好发生 1 次 `refresh` 快照回退；刷新流量与计数在表格测量窗口之外。慢客户端、窗口溢出和游标失效仍由核心通道测试覆盖，本组不以顺利路径代替这些故障测试。

统计边界：数据库查询包含会话与逐成员授权、操作事务、持久化通知及后台作业，没有关闭安全检查。字节数是客户端 WebSocket 接收到的应用消息 UTF-8 大小，不含 HTTP 响应、初始快照、TLS 或 WebSocket 帧头。延迟包含 HTTP 写入及等待所有客户端的 10ms 轮询；表中范围是三个轮次各自的分位数范围，不是合并样本的分位数。测试顺序固定、没有 CPU / 内存隔离，是本机开发构建单节点对照，不能作为延迟优势或生产容量承诺。本次在共享订阅撤销修复后重跑，原始数据与表格已替换为本轮结果。

另有同机双节点 120 秒、12 客户端的正确性与资源清理验证，实测 2056 条消息、41 次重连/续期，全部历史无空洞或重复，关闭连接后订阅、Observer 和读取缓存归零；见 [ACCEPTANCE.md](ACCEPTANCE.md) 与 [双节点原始报告](../bench/cluster-2026-11-07.json)。它不包含隔离的缓存性能对照，不能推导跨主机容量或长期稳定性。

复现（独立 `chat_benchmark` 数据库，HTTP 4185、统计 4186）：

```sh
bash scripts/shared_bench.sh
FANOUT=10 POSTS=10 ROUNDS=3 bash scripts/shared_bench.sh
```

可用 `SHARED_BENCH_DATABASE_URL`、`SHARED_BENCH_PORT`、`SHARED_BENCH_METRICS_PORT` 覆盖连接。统计服务只在明确启用的本地非生产测试中启动；测试后服务进程关闭，报告写入 `.local/bench/`。它以独立常驻进程持有计数表，避免启动脚本返回后丢失统计；任何统计接口失败或遥测计数为空都会使验收失败。
