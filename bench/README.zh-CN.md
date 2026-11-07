# Fyrlet 基准测试

[English](README.md) | 简体中文

最新的同资源对照见 [性能对比](../docs/zh/PERFORMANCE.md)，优化记录见 [优化记录](../docs/zh/OPTIMIZATIONS.md)。

本目录提供可重复的 Fyrlet 基线、Meteor 收件箱参考应用、共享场景和结果报告。先验证业务正确性，再解释性能数字；本地 smoke 不用于宣称容量或产品排名。

后续用于性能结论的 Meteor / Fyrlet 对照遵循 [同等条件规范](FAIRNESS.md)：相同应用与数据库资源限额、业务保障、负载及预热，单核和多核预算分别测。当前本地启动器没有落实资源限额，跨实现报告统一标记 `observational-only`，不能据此作同资源排名。报告会核对完整负载、源码指纹与主机信息；启动器在计时前后发现源码变化时中止整套对照。

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
| soak | 100 用户 × 2 观察者 | 按全局目标速率持续发起写入，每用户最多一个写入等待全部观察者收敛；记录未服务的目标时隙 |

每个用户额外创建一个写入客户端。Fyrlet 写入端通过 SDK 的 Socket RPC 调用业务，不建立订阅；Meteor 写入端通过 DDP 调用 Method，不建立 publication。两边观察者都订阅相同范围，写入者不参与传播延迟样本。

standard 每个用户预置 50 条记录，每条 text 128 字节；每场景先预热 5 次写入，再正式写入 30 次，默认重复 3 轮。smoke 使用更小数据和单轮执行。每次修改保持记录数和 text 字节数不变；初始数据使用受信任预置路径，预置过程不计入性能。

```sh
bash scripts/bench.sh --scenario isolated --users 100 --devices 2 \
  --rows 50 --payload-bytes 512 --writes 100 --warmup 10 \
  --concurrency 10 --repeats 3 --label local-100-users
```

`--writes` 是每用户写入次数；`--concurrency` 控制同时运行的用户写入循环，各用户内部顺序写入，避免无意制造版本冲突。观察者恢复时同时发起重连。可通过 `--interval-ms` 控制相邻写入间隔，`--idle-ms` 控制空闲持续时间，`--delay-ms` 控制慢客户端消费间隔。慢客户端模拟的是应用读取延迟，并非操作系统 TCP 限速；其接收队列有上限，报告记录单客户端队列峰值。

## 持续负载与容量阶梯

本地 Meteor 负载直连固定 `--app-port`（公开端口 + 2），绕过开发代理；资源仍分开记录实际 Node 与完整进程树。旧报告经过代理，需按报告日期与启动模式区别，不能把旧代理结果当成当前直连基线。用户数上限 5000，观察者总数仍限制为 5000；5000 用户 × 1 观察者包含写入端后共有 10000 个连接。

`all` 保留原六个功能场景，长时间 `soak` 需显式选择。`--rate` 是全局目标写入/秒，`--duration-ms` 默认 60 秒、最大 10 分钟，二者替代此场景的 `--writes`。执行器按时隙轮转用户，用户仍在等待上次收敛或达到并发上限时直接记录未服务时隙，执行器落后也不会补发突发流量。报告区分 busy / concurrency / generator 三类跳过，并保留每 10 秒的延迟与交付统计。

```sh
npm --prefix sdks/typescript run build
ERL_FLAGS='+S 4:4 +sbwt none +sbwtdcpu none +sbwtdio none' \
node bench/capacity.mjs --levels 100,500,1000 --rates 200 \
  --devices 2 --duration-ms 60000 --repeats 2 \
  --out .local/bench/capacity-example

bash scripts/bench.sh --target all --scenario soak --users 1000 --devices 2 \
  --concurrency 64 --rate 200 --duration-ms 180000 --warmup 1 --repeats 1
```

`capacity.mjs` 串行启动独立服务，输出逐轮原始结果及 `capacity.json` / `capacity.md`。默认每轮要求最终正确、传播 P95 ≤ 250 ms、交付覆盖率 ≥ 99%、跳过目标时隙 ≤ 1%，且执行器没有超过 1 秒的停顿；可用 `--p95-ms`、`--min-coverage`、`--max-drop-rate` 调整。任意一轮失败就不能宣称该点通过。它报告实测负载点，不外推生产最大用户数。不同用户数与目标速率可以组合，以区别连接规模和活跃写入压力。

每用户还包含一个写入连接，1000 用户 × 2 观察者实际是 3000 个 WebSocket 连接。报告分别保留建连/预热、稳定负载和关闭后资源，`--settle-ms` 在 soak 默认 2000，用于观察关闭后的资源；RSS 不下降本身不证明泄漏。Meteor 的运行时诊断读取固定版本的私有 `_observeMultiplexers` / `_observeDriver`，记录实际驱动与已登录会话数；正常关闭发送 DDP disconnect，避免默认 15 秒的断线恢复保留窗口污染下一轮，短时非正常断线则使用 session / receivedCount 恢复，失配时重新订阅。

长期运行的延迟样本每序列最多保留 100,000 条，超出后使用均匀蓄水池采样计算分位数，count / min / max / mean 仍为精确值；待交付标记全部完成后立即释放，未完成标记上限 100,000。应用、数据库和执行器资源每 250 ms 采样，保留 RSS 起止/均值/趋势及执行器 heap/事件循环停顿。`applicationWorker` 单独统计实际服务的 BEAM / Node PID，是 `application` 进程树的子集，两者不可相加；Meteor CLI 和代理因此不会混入单个 Node 应用的数字。进程树 RSS 仍可能重复计算共享页面。

测试期间保持代码冻结，不并行运行构建、测试或其他压测。macOS 可在命令前加 `caffeinate -is`，防止空闲睡眠；休眠、宿主暂停或执行器饱和造成的长停顿会令容量推断无效。会话默认 15 分钟，长时间测试需留出初始化余量。

默认 `--sessions shared` 让同一用户的所有设备与写入端共用会话，能复用 Fyrlet Observer。`--sessions device` 为写入端和每台设备分别签发会话，但保留同一用户和相同业务数据；Fyrlet 此时按 session 隔离 Observer，Meteor 相同查询仍可共享其 Mongo observer。两种模式须分开解释，不能把共用登录态的结果直接当成独立设备登录的容量。

```sh
bash scripts/bench.sh --target all --scenario soak --users 1000 --devices 5 \
  --sessions device --rate 200 --duration-ms 60000 --concurrency 64 --warmup 1 --repeats 1
```

传播计时与在线收敛检查使用 id / text / version；计时结束并停止资源采样后，执行器再对每条完整记录作严格比较，包含日期和其他业务字段。这个最终检查不会混入传播延迟或目标速率窗口。

## 测量口径

- `propagationMs`：发起写入之前，到另一客户端应用相同服务端 text 标记的耗时。由同一执行器的单调时钟测量，包含请求、事务、通知、传输和客户端应用过程，不包含写入端乐观结果。
- `writeMs`：写入请求至成功返回的耗时。Meteor 驱动等待 DDP `result` 与 `updated`；当前 Fyrlet 驱动等待 Socket RPC 成功回复，旧报告使用 HTTP 成功结果。两者协议完成条件不同，报告保留实现说明。
- `firstReadyMs`：建立一个观察者至其完整视图 ready，包含身份和连接初始化。这组样本在预热前采集，并行初始化会产生排队影响。
- `recoveryMs`：同一批观察者开始重连，到各自应用离线期间最新数据的耗时。它测应用重新入会，Meteor 驱动由执行器显式重连。
- `writeRequestsPerSecond`：本轮闭环执行观察到的请求速率。fanout / isolated 每次等待观察者，burst / slow 只等待写入确认；这不是服务端最大吞吐。`convergedWritesPerSecond` 只用于逐次等待收敛的场景。
- `deliveryCoverage`：实际观察到的中间变更次数 / 潜在观察次数。高频、离线与慢客户端场景允许合并；必须结合该比例解释延迟分位数，最终完整视图仍必须正确。
- `traffic`：预热之后的 HTTP JSON body 与 WebSocket 应用 payload 字节，不含握手、帧头、HTTP header、TLS 或压缩后的线速。两边分别物化快照与增量，记录量和字段范围相同。
- `resources`：每 250ms 采样进程树 RSS 与累计 CPU 时间差，应用和数据库分开记录；同时记录执行器 RSS、CPU、事件循环延迟。短命子进程可能被采样遗漏，RSS 求和也可能重复计入共享内存。短轮测试的 CPU 精度有限。

结果包含全部原始延迟样本，每轮独立计算 nearest-rank 分位数，不平均多轮的 p95。场景失败保留已完成结果并以非零状态退出；不会生成成功排名。

所有视图都验证记录数量、ID 范围、重复 ID 和最终 text/version。记录来自其他用户、漏掉最终记录或最终版本错误均使测试失败。当前负载只覆盖已有记录更新，不代表新增、删除、窗口移入移出、团队权限、服务崩溃、撤销或幂等竞争的完整验收；这些另由应用测试覆盖或后续扩展。

## 对照边界

当前 ACK 为无回执通知，增量统一使用紧凑字段及元组格式。SDK 对不可变视图的纯字段替换复用 ID 索引，仍复制结果数组并保持历史快照不可变。可用 `node --expose-gc bench/views.mjs` 单独测量 50 / 100 条记录的 SDK 更新路径；默认每轮 10,000 次、交替执行 5 轮，原始 JSON 写入 `.local/bench/views-*.json`。这只衡量 SDK 局部处理，不是服务端容量或端到端延迟。

Fyrlet 使用协商后的字段增量与 ACK，初始与恢复使用完整快照；当前驱动通过公开 SDK 的 operationTransport: socket 调用业务。Meteor 使用 DDP 增量与 Method，两者保持各自正常同步路径。旧报告的 Fyrlet 可能使用 HTTP 写入或完整快照，以报告 capability 和源码指纹为准。Meteor 驱动是本目录的小型 Node DDP 物化器，没有完整 Minimongo、客户端乐观 stub 或自动恢复策略，因此客户端 CPU 不能解释为两套完整前端 SDK 的性能对比。

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

## 诊断与 JSON 编码实验

`FYRLET_OBSERVER_HIBERNATE_AFTER_MS=infinity` 关闭 Observer 空闲休眠，默认 1000 ms。启动器记录此选项，允许在相同源码下分别测量内存和 CPU 取舍。两侧必须固定其余参数并串行运行。

诊断模式可额外指定 `BENCH_MEMORY_INTERVAL_MS=10000`，写入 `memory.ndjson`，按初始模块统计进程数量、堆内存、排队消息和二进制引用，并采集 BEAM 总内存与 TCP 缓冲区配置。进程二进制引用可能跨进程重复计数，不能相加当作独占内存。关闭后的 `runtime.json` 记录 Observer 注册表、监督器数量及 BEAM 内存，用于区分存活状态和分配器保留的 RSS；诊断运行不用于正常性能排名。

诊断模式只支持本地 Fyrlet。它额外统计按 SQL 命令和表归类的次数、累计时间与连接排队时间；BENCH_EPROF=1 同时生成函数调用与耗时报告。诊断报告在 applicationMode 中明确标记有插桩，不能与普通跑分直接比较时间或 CPU：

```sh
BENCH_DIAGNOSTICS=1 BENCH_EPROF=1 \
bash scripts/bench.sh --target fyrlet --scenario fanout \
  --devices 20 --rows 50 --writes 500 --warmup 20 --repeats 1
```

queries.json 与可选 eprof.txt 位于本轮 private/fyrlet 目录。eprof 使用当前 Erlang 安装自带的 tools，不新增生产依赖。进程在开始测量前确认诊断已就绪，结束后先落盘诊断文件再退出。

下面的微基准比较大小检查与发送重复编码、复用已有编码、Jason 编译期宏加复用三条路径。它验证 JSON 值和字节数一致，包含中文、换行、引号和反斜杠；每种路径交替执行 5 轮：

```sh
ERL_FLAGS='+S 4:4 +sbwt none +sbwtdcpu none +sbwtdio none' \
mix run --no-start bench/json.exs
```

BENCH_JSON_ITERATIONS 默认 10000，可调整每轮循环次数。结果保存在 .local/bench/json-*.json。50 条记录快照的复用仅作为实验；当前生产推送仅对 delta 包复用已编码正文。该脚本比较局部编码过程，不代表应用吞吐或完整业务耗时。

运行时调优可在普通 bench 命令前设置相同 ERL_FLAGS。报告仅记录调度器相关选项，不复制可能包含凭证的整段虚拟机参数。4 个调度器与关闭忙等是当前机器上的可选方案，不是所有部署的默认建议。

## 验证

```sh
npm --prefix bench test
bash scripts/bench.sh --target all --profile smoke
```

单元测试覆盖统计口径、视图校验、工作负载边界、进程树资源计算、并发失败收尾和 DDP 数据/Method 完成语义。真实 smoke 验证两边服务与执行器可以协同工作，不产生性能优劣结论。
