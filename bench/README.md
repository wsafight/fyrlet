# Fyrlet benchmarks

第一轮通知链路优化的实现、前后实测与限制见 [优化报告](OPTIMIZATION.md)。

本目录提供可重复的 Fyrlet 基线、Meteor 收件箱参考应用、共享场景和结果报告。先验证业务正确性，再解释性能数字；本地 smoke 不用于宣称容量或产品排名。

## 快速运行

需要项目所用的 Elixir / Erlang、PostgreSQL 和 Node ≥ 22。Fyrlet 本地启动器使用生产配置，默认连接独立的 `fyrlet_bench` 数据库，端口 4200。

```sh
bash scripts/postgres.sh start
bash scripts/bench.sh --profile smoke
bash scripts/bench.sh --scenario fanout --devices 50 --repeats 3
```

启动器构建 SDK，编译服务端、迁移数据库、创建测试项目，随后启动服务、执行测试并关闭自己启动的服务进程。默认清理本轮测试项目，保留数据库和报告。它不会删除开发项目；`BENCH_DATABASE_URL` 可指定另一个数据库，`--port` 可指定本地服务端口。

结果默认写入 `.local/bench/<run-id>/`：

```text
<target>/results.json    原始样本、每轮统计、环境与能力说明
<target>/report.md       单个实现的报告
comparison.md           本轮所有实现的报告
private/<target>/       0600 凭证和日志，上层目录权限 0700
```

`--out PATH` 可以指定报告目录。凭证始终位于忽略的 `.local/` 目录，不写入 JSON 报告。`--keep-data` 保留本轮测试数据，适合排查失败。默认会话有效期为 15 分钟，超长负载需要另行管理会话续期。

## Meteor 对照

参考应用位于 `apps/meteor/`，固定 Meteor 3.5.4。它使用 MongoDB 副本集、游标 publication、DDP 增量同步、版本条件更新，以及业务修改与成功幂等结果同事务提交。

安装脚本将官方工具链放入 `.local/meteor-toolchain/`，不会安装系统命令或修改 shell 配置。下载约 486 MiB，解压后占用更多空间；可使用现有 Meteor CLI，通过 `METEOR_BIN` 指定绝对路径。

```sh
bash scripts/bench-meteor.sh
bash scripts/bench.sh --target meteor --profile smoke
bash scripts/bench.sh --target all --profile smoke
```

如果需要代理，给安装与运行命令都传入代理环境变量。`NO_PROXY` 保证本地测试流量直接访问服务。

```sh
HTTPS_PROXY=http://127.0.0.1:7890 \
HTTP_PROXY=http://127.0.0.1:7890 \
NO_PROXY=localhost,127.0.0.1,::1 \
bash scripts/bench-meteor.sh

HTTPS_PROXY=http://127.0.0.1:7890 \
HTTP_PROXY=http://127.0.0.1:7890 \
NO_PROXY=localhost,127.0.0.1,::1 \
bash scripts/bench.sh --target all --profile smoke
```

Meteor 首次运行还需解析及下载应用包，启动等待默认 180 秒，可用 `--startup-timeout-ms 600000` 调整。启动器使用 `meteor run --production`，应用优化构建，但资源统计包含 Meteor CLI 和代理；这与直接部署构建后的 Node bundle 有区别。Meteor 自带 MongoDB 使用独立本地数据库；Fyrlet 默认使用项目已有的 PostgreSQL 集群，资源统计包含该集群的其他后台活动。报告明确记录这些差异。

参考应用仅用于隔离的本地测试，启动时必须设置随机 `BENCH_SECRET`。本地启动器生成该值，预置和清理接口只接受它；不把该应用部署为公开业务服务。

## 场景

| 场景 | standard 默认规模 | 行为与正确性 |
| --- | --- | --- |
| fanout | 1 用户 × 10 观察者 | 修改已有记录，每次等所有观察者应用结果后继续 |
| isolated | 10 用户 × 1 观察者 | 多个用户并行，验证每个视图只包含本人的记录 |
| burst | 1 用户 × 5 观察者 | 连续等待写入确认，最后等待所有视图收敛；允许合并中间状态 |
| reconnect | 5 用户 × 2 观察者 | 观察者断开，写入更新后同时重新连接，验证最新完整视图 |
| slow | 1 用户 × 2 观察者 | 每组最后一个观察者延迟消费每条传输消息，验证最终收敛 |
| idle | 10 用户 × 2 观察者 | 保持订阅，不写入，观察资源与周期性流量 |

每个用户额外创建一个写入客户端。Fyrlet 写入端使用 HTTP，不建立订阅；Meteor 写入端通过 DDP 调用 Method，不建立 publication。两边观察者都订阅相同范围，写入者不参与传播延迟样本。

standard 每个用户预置 50 条记录，每条 text 128 字节；每场景先预热 5 次写入，再正式写入 30 次，默认重复 3 轮。smoke 使用更小数据和单轮执行。每次修改保持记录数和 text 字节数不变；初始数据使用受信任预置路径，预置过程不计入性能。

```sh
bash scripts/bench.sh --scenario isolated --users 100 --devices 2 \
  --rows 50 --payload-bytes 512 --writes 100 --warmup 10 \
  --concurrency 10 --repeats 3 --label local-100-users
```

`--writes` 是每用户写入次数；`--concurrency` 控制同时运行的用户写入循环，各用户内部顺序写入，避免无意制造版本冲突。观察者恢复时同时发起重连。可通过 `--interval-ms` 控制相邻写入间隔，`--idle-ms` 控制空闲持续时间，`--delay-ms` 控制慢客户端消费间隔。慢客户端模拟的是应用读取延迟，并非操作系统 TCP 限速；其接收队列有上限，报告记录单客户端队列峰值。

## 测量口径

- `propagationMs`：发起写入之前，到另一客户端应用相同服务端 text 标记的耗时。由同一执行器的单调时钟测量，包含请求、事务、通知、传输和客户端应用过程，不包含写入端乐观结果。
- `writeMs`：写入请求至成功返回的耗时。Meteor 驱动等待 DDP `result` 与 `updated`；Fyrlet 等待 HTTP 成功结果。两者协议完成条件不同，报告保留实现说明。
- `firstReadyMs`：建立一个观察者至其完整视图 ready，包含身份和连接初始化。这组样本在预热前采集，并行初始化会产生排队影响。
- `recoveryMs`：同一批观察者开始重连，到各自应用离线期间最新数据的耗时。它测应用重新入会，Meteor 驱动由执行器显式重连。
- `writeRequestsPerSecond`：本轮闭环执行观察到的请求速率。fanout / isolated 每次等待观察者，burst / slow 只等待写入确认；这不是服务端最大吞吐。`convergedWritesPerSecond` 只用于逐次等待收敛的场景。
- `deliveryCoverage`：实际观察到的中间变更次数 / 潜在观察次数。高频、离线与慢客户端场景允许合并；必须结合该比例解释延迟分位数，最终完整视图仍必须正确。
- `traffic`：预热之后的 HTTP JSON body 与 WebSocket 应用 payload 字节，不含握手、帧头、HTTP header、TLS 或压缩后的线速。两边分别物化快照与增量，记录量和字段范围相同。
- `resources`：每 250ms 采样进程树 RSS 与累计 CPU 时间差，应用和数据库分开记录；同时记录执行器 RSS、CPU、事件循环延迟。短命子进程可能被采样遗漏，RSS 求和也可能重复计入共享内存。短轮测试的 CPU 精度有限。

结果包含全部原始延迟样本，每轮独立计算 nearest-rank 分位数，不平均多轮的 p95。场景失败保留已完成结果并以非零状态退出；不会生成成功排名。

所有视图都验证记录数量、ID 范围、重复 ID 和最终 text/version。记录来自其他用户、漏掉最终记录或最终版本错误均使测试失败。当前负载只覆盖已有记录更新，不代表新增、删除、窗口移入移出、团队权限、服务崩溃、撤销或幂等竞争的完整验收；这些另由应用测试覆盖或后续扩展。

## 对照边界

Fyrlet 使用完整快照与 ACK，Meteor 使用 DDP 增量，两者保持各自正常同步路径。Meteor 驱动是本目录的小型 Node DDP 物化器，没有完整 Minimongo、客户端乐观 stub 或自动恢复策略，因此客户端 CPU 不能解释为两套完整前端 SDK 的性能对比。

两边都提供项目/用户过滤、版本条件修改、短期随机会话与事务幂等。Fyrlet 会对快照重新查询鉴权、串行化撤销与写入，在最外层事务提交后立即广播并保留持久化 Oban 通知兜底，自动刷新会跳过内容未变化的快照；Meteor 参考实现对 Method/publication 加入验证会话，以定时器处理订阅到期，没有实现相同的逐次快照重新鉴权及撤销/写入串行化。数据库与持久化通知路径也不同。报告附带能力矩阵，不把这些数字描述成保障完全相等的引擎排名。

当前不包含纯 Phoenix 的连接/广播分项基线、跨节点容量、数据库每次写入查询数、系统级网络限速或故障恢复压测。下一步可按独立场景加入，避免混合成一个 QPS 数字。

## 外部部署与多份报告

本地启动器用于开发回归。正式对比应固定机器和资源预算，使用独立压测机，记录数据库拓扑、持久化与复制配置、负载发生器规模和全部版本。可用 runner 连接自己管理的服务；fixture 格式参见预置脚本和 Meteor seed 返回值，文件含短期用户令牌，应私密保存。

```sh
node bench/runner.mjs --target fyrlet --endpoint https://benchmark.example \
  --fixtures /private/credentials.json --out .local/bench/remote \
  --scenario isolated --users 10 --devices 1 --rows 50

node bench/report.mjs .local/bench/run-a/fyrlet/results.json \
  .local/bench/run-b/meteor/results.json > .local/bench/comparison.md
```

可通过 `--app-pid` / `--database-pid` 采集本机进程；远端服务的资源需要另外采集。`BENCH_REVISION` 可以记录源码版本，结果还包含实际源码 SHA256 指纹。`BENCH_APPLICATION_MODE`、`BENCH_VERSIONS`（JSON）、`BENCH_TOPOLOGY`、`BENCH_DATABASE_SHARED` 用于描述外部部署条件。

## 验证

```sh
npm --prefix bench test
bash scripts/bench.sh --target all --profile smoke
```

单元测试覆盖统计口径、视图校验、工作负载边界、进程树资源计算、并发失败收尾和 DDP 数据/Method 完成语义。真实 smoke 验证两边服务与执行器可以协同工作，不产生性能优劣结论。
