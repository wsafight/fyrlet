# 本地验收记录

## 2026-11-08：预发布生产就绪

`feat/pre-release-production-readiness` 基于已合并 PR #10 的 `c03e7e72bd8383f876590a6c081ebbfca5ade075`，完整冻结源码本地验收的 **21 个阶段全部通过**。报告为 `.local/readiness/pre-release-20261108-final/result.json`，逐阶段日志位于同目录。SHA-256 源码指纹 `21167b253602163d9a1bb37696a7bd06d989eae1604bdb69afc35fa371343723` 覆盖 712 个 Git 已跟踪／未忽略文件。这是补写本验收记录前的代码快照；记录更新后会重跑 package／site，分发产物还必须在干净的最终提交上再次重建。

```sh
node scripts/acceptance.mjs --out .local/readiness/pre-release-20261108-final
```

| 验证 | 结果 | 报告目录中的证据 |
| --- | --- | --- |
| Elixir 格式、无警告编译与 Credo | 通过 | `core-1.log` 至 `core-3.log` |
| 核心、示例与独立包 | **788 项通过**：核心 718、示例 35、包 35 | `core-4.log` |
| TypeScript SDK 与类型检查 | **304 项通过**；行／分支覆盖率 **99.27% / 95.66%** | `client-1.log`、`client-2.log` |
| React 适配与类型检查 | **20 项通过**；行／分支覆盖率 **100% / 100%** | `client-3.log`、`client-4.log` |
| 宿主单元／启动／部署检查 | **68 项通过** | `client-5.log` |
| 含真实 PostgreSQL 共享存储的宿主检查 | **78 项通过**；已加载服务端模块行／分支覆盖率 **90.47% / 91.78%** | `host-1.log` |
| 性能／就绪工具 | **46 项通过** | `bench-1.log` |
| staging、多主机与发布辅助离线回归 | **96 项通过** | `bench-2.log` |
| 契约导出与检入的生成类型 | 通过 | `contract-1.log`、`contract-2.log` |
| 真实本地 HTTP／WebSocket 集成 | **20 项通过** | `integration-1.log` |
| 独立快照恢复与重复迁移 | 通过 | `restore-1.log`；嵌套报告 `.local/readiness/restore-1794151426766/result.json` |
| 浏览器流程 | **14 项通过**，含父用例；签名本地测试 IdP | `browser-1.log` |
| 四产物构建与仓库外安装 | 通过，包括解包 Hex 编译、离线 SDK／React 导入及 `skipLibCheck=false` 的严格 TypeScript 消费方编译 | `package-1.log`、`package-2.log` |
| 文档站点 | 构建 **70 页**；检查 **3,498 个内部链接与 35 个仓库目标**，无失效链接 | `site-1.log`、`site-2.log` |

本轮覆盖合并后的唯一迁移基线及预发布兼容入口删除。当前能力协商、显式定义版本固定、安全校验和快照恢复继续保留。已选择 Apache-2.0 及 Fyrlet Core／`@fyrlet/client`／`@fyrlet/react` 0.1.0 协同首发范围，其余七种 SDK 仍为实验性。四份本地产物分别是源码、Hex、TypeScript 和 React 包。预提交清单记录了 `working_tree_clean: false`，因此它不是发布批准。

本轮未执行真实 24 小时稳定性运行。真实外部 IdP／staging 生命周期、生产备份恢复、不同物理主机故障、实体设备及真实邮件仍为 `not-run`；本地测试 IdP、隔离数据库、浏览器模拟、打桩控制钩子和同机演练不能替代这些证据。多主机示例配置检查保持 `not-run`；staging 示例因缺少私有环境文件而失败关闭。`publicationApproved` 与 `ownershipVerified` 仍为 false，未执行 Hex／npm 发布；本分支新提交仍需精确 head 的 Core PR CI。缺少该运行的发布预检查必须失败，不能复用 PR #10 的基线结果。

## 2026-11-08：按顺序推进路线图

继续在 `feat/readiness-and-performance` 按 CI、共享宿主存储、性能、可靠性、发布准备的顺序处理。最终代码验收的 **15 个阶段全部通过**：`.local/readiness/followup-20261108-guarded/result.json`，SHA-256 源码指纹 `ff647bdd4eacfe1e87225da197cb60056df1973dfef2e9298f5b55ff46ade615`，覆盖 683 个 Git 已跟踪／未忽略文件。这是补写本记录前的代码快照；下方较早的 13 阶段记录保留当时数量。

```sh
node scripts/acceptance.mjs --groups core,client,host,bench,contract,integration,restore,browser \
  --out .local/readiness/followup-20261108-guarded
node scripts/acceptance.mjs --groups package,site \
  --out .local/readiness/followup-20261108-artifacts
node scripts/release_check.mjs --out .local/readiness/followup-20261108-release-check.json
```

| 验证 | 结果 | 最终代码报告同目录证据 |
| --- | --- | --- |
| Elixir 格式／编译及测试 | 通过，**776 项**：核心 706、示例 35、包 35 | `core-1.log` 至 `core-3.log` |
| TypeScript SDK 与类型检查 | **304 项通过**，行／分支覆盖率 **99.27% / 95.66%** | `client-1.log`、`client-2.log` |
| React 适配与类型检查 | **20 项通过**，行／分支覆盖率 **100% / 100%** | `client-3.log`、`client-4.log` |
| 宿主单元／启动／部署检查 | **68 项通过** | `client-5.log` |
| 含真实 PostgreSQL 的宿主检查 | **78 项通过**（相同的 68 项加 10 项集成）；已加载服务端模块行／分支覆盖率 **90.47% / 91.49%** | `host-1.log` |
| 性能／就绪工具 | **37 项通过** | `bench-1.log` |
| 契约导出与生成类型 | 通过 | `contract-1.log`、`contract-2.log` |
| 真实 HTTP／WebSocket 集成 | **20 项通过** | `integration-1.log` |
| 独立快照恢复与重复迁移 | 通过 | `restore-1.log` |
| 浏览器流程 | **14 项通过**，含父用例；签名本地 IdP | `browser-1.log` |

CI 使用同一冻结源码入口，包含 host／restore 阶段，并始终上传报告；未宣称这个未推送分支已有新的托管结果。共享宿主现支持 PostgreSQL 加密状态、登录 state 原子消费、跨池续期／退出和重启，要求直接／session-affine 连接，不支持 transaction pooling。回归覆盖杀死持锁进程、scope 容量、锁等待、超过池连接数的签发、退出保留入口，以及持久化／活跃检查失败时撤销已知令牌。启动配置错误已脱敏；本地数据库演练在建连前拒绝 URL 查询参数／片段重定向。中间的 `.local/readiness/followup-20261108-verified/` 在宿主阶段被主动停止以补强 URL 守卫，不计完整通过。覆盖率纳入启动模块的失败路径，不包含浏览器执行的全部静态服务代码。

混合负载／密度的六次短跑在 10 个用户、每用户 1／4 个设备、目标每秒 20 次写入、每点三次重复下通过正确性及工具阈值。见 [PERFORMANCE.md](PERFORMANCE.md) 与[脱敏证据](../bench/mixed-density-2026-11-08.json)。它们不证明饱和、加速或生产容量，仍有物理宿主 CPU 干扰。PostgreSQL 失效通知继续默认关闭。原生 `promtool` 再次验证四条告警规则通过。

长时包装器的短演练以四客户端运行 30 秒通过：**527 次写入、10 次重连、10 次续期**，全量历史核对通过，订阅／Observer／读取缓存归零。共 10 个数据库样本，无采样失败；数据库从 27,784,883 增至 28,169,907 字节。节点样本保留内存及累计数据库排队／查询遥测，Chat／Agent 的切换／幂等检查通过。报告 `.local/readiness/stability-followup-20261108/result.json`，实测工具指纹 `b2a60f44f74e7054bf65fdf8512f09097c3ff0da1f3cf68375e25e53de13b806`。这仍是同机短演练，明确保留 24 小时未验证；未选择生产资源阈值。

另一次 Notify 快照／恢复保留全部 22 张 public 表的事实清单，包括 **11 个 Run、10 个 Effect、16 条幂等记录、10 条通知**；两次 Notify 迁移均未改变事实。只删除本次新建的目标库，私有 dump 已移除。报告 `.local/readiness/restore-notify-followup-20261108/result.json`。这些是本地模拟供应商的事实，不是真实邮件、生产恢复或跨版本升级证明。

该较早文档快照对应的分发包／安装／站点检查另记于 `.local/readiness/followup-20261108-artifacts/result.json`；发布预检查为 `.local/readiness/followup-20261108-release-check.json`，应独立查看结果，不从上述代码回归推断。打包记录源码指纹、提交、干净／脏状态及校验和。在这个历史检查点，分支尚未提交／推送，也尚无维护者批准的许可证／发布策略和精确提交托管 CI；当前预发布记录已替代这些许可证／产物状态。预检查从不发布。外部 IdP／生产共享宿主、多主机故障、24 小时执行、实体设备与真实邮件仍是[发布检查单](RELEASE_CHECKLIST.md)中的独立关卡。

## 2026-11-08：就绪性与性能后续

分支 `feat/readiness-and-performance`，基于 main 的 `7f97e40005b901fa11fd16ca4020210af94f6862`。下列冻结源码验收的 **13 个阶段全部通过**；报告为 `.local/readiness/2026-11-08-final-pass/result.json`，逐阶段日志在同一目录。SHA-256 源码指纹 `c445871cd7a55269c35d8de7dab968563a65acb31b9dcaa846fa63626c910394` 覆盖 670 个 Git 已跟踪及未忽略文件。此验收之后仅更新了验收记录；分发包检查另用报告记录更新后的文档。

```sh
node scripts/acceptance.mjs --groups core,client,bench,contract,integration,browser \
  --out .local/readiness/2026-11-08-final-pass
node scripts/acceptance.mjs --groups package,site \
  --out .local/readiness/2026-11-08-artifacts
```

| 验证 | 结果 | 冻结源码报告目录中的证据 |
| --- | --- | --- |
| Elixir 格式与编译 | 通过，编译警告视为错误 | `core-1.log`、`core-2.log` |
| 核心、示例与插件包 | **776 项通过**：核心 706、示例 35、插件包 35 | `core-3.log` |
| TypeScript SDK | **304 项通过**，类型检查通过；行/分支覆盖率 **99.27% / 95.66%** | `client-1.log`、`client-2.log` |
| React 适配器 | **20 项通过**，类型检查通过；行/分支覆盖率 **100% / 100%** | `client-3.log`、`client-4.log` |
| OIDC 宿主与部署检查 | **60 项通过**；已加载服务端模块的行/分支覆盖率 **98.24% / 97.67%** | `client-5.log` |
| 性能与验收工具 | **30 项通过** | `bench-1.log` |
| 契约导出与生成类型 | 通过 | `contract-1.log`、`contract-2.log` |
| 真实 HTTP/WebSocket 集成 | **20 项通过** | `integration-1.log` |
| 真实浏览器流程 | **14 项通过**，含父用例；使用本地签名测试 IdP，不是外部供应商 | `browser-1.log` |

补充验证：会话批处理测试使用曾出问题的种子 `926877`，9 项通过；通知与模式测试 18 项通过；启用 `FYRLET_POSTGRES_INVALIDATION=true` 的真实集成测试 20 项通过。日志分别为 `/tmp/fyrlet-session-final.log`、`/tmp/fyrlet-notify-final.log`、`/tmp/fyrlet-pg-integration.log`。原生 `promtool` 3.1.0 检查 **4 条告警规则通过**（`/tmp/fyrlet-promtool-native.log`），官方压缩包已按发布版 SHA-256 清单核对。最初 Docker 镜像拉取失败，因此这不是托管 CI 容器检查通过的证据。重复使用已有扫描与 ABBA 标签均在执行前被拒绝，原证据校验和未变。

上游 main 的 CI `42451376341` 在两个共享 worker 遥测断言上失败。本分支隔离测试 worker 和发出事件的进程，限制排队等待，并在调用进程内检查绕过批处理的数据库查询。更早的 PR 运行 `42450925475` 成功，但它和本地回归都不是本分支的托管结果。工作流已加入工具测试、告警规则检查和手动触发；**新的托管 CI 仍待运行**。被源码指纹守卫中止的中间尝试（包括 `.local/readiness/2026-11-08-verified/result.json`）是失败尝试，不能作为完整验收通过的证据。

性能证据见 [PERFORMANCE.md](PERFORMANCE.md) 和[脱敏 JSON](../bench/readiness-performance-2026-11-08.json)：100/s、500/s 共 6 次基线均通过所设 SLO，投递覆盖率 100%、无 OOM，但不能据此确定容量上限。PostgreSQL 通知的同镜像 ABBA 共 8 次，正确性均通过，目标负载与延迟 SLO 则为默认模式 3/4、通知模式 2/4。物理主机 CPU 干扰且波动明显，**没有提速证据**，新选项仍默认关闭。最终 10 用户、单生成器、通知模式冒烟也通过（`/tmp/fyrlet-smoke.log`）。

`FYRLET_POSTGRES_INVALIDATION=true CLUSTER_SOAK_SECONDS=300 CLUSTER_CLIENTS=20 CLUSTER_BASE_PORT=4240 bash scripts/cluster.sh` 的 Chat、Agent 检查通过。Chat 共 5,070 次写入、101 次重连、102 次续期，全量历史无空洞/重复，p50 为 32.12 ms、p95 为 36.43 ms（含 25 ms 轮询）；两节点订阅、Observer、读取缓存均归零。Agent 覆盖跨节点 Run 幂等、所有权与故障切换。报告为 `.local/cluster/chat.json`、`.local/cluster/agent.json`。这仍是本机双节点证据，**不是多主机或 24 小时验收**。

在这个较早检查点，外部预检查仍未通过：OIDC 缺少 `PUBLIC_ORIGIN`、`FYRLET_ENDPOINT`、`FYRLET_PROJECT_ID`、`FYRLET_SERVICE_KEY`、`OIDC_PROVIDERS`；真实邮件缺少 `RESEND_API_KEY`、`MAIL_FROM`、`MAIL_TO`。报告在 `.local/readiness/oidc-preflight.json`、`.local/readiness/mail-preflight.log`。未进行真实登录、邮件发送或注册表发布。当时多实例宿主共享存储尚未实现，部署检查拒绝 `HOST_INSTANCES != 1`；上方后续记录已替代此项存储限制。实体设备、外部 IdP 生命周期、多主机故障、长时稳定性、生产恢复/升级与告警阈值仍是 [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) 中的独立门槛。

分发包分组另行记录源码归档/npm 构建、外部消费者安装冒烟、文档站构建与链接检查。它们是本地检查，不等于 Hex/npm 发布或生产上线。

## 2026-11-08：路线图回归测试扩充

本轮在 `feat/react-contract-auth-retry` 新增 **108 项可执行测试**，另补充编译期契约断言；未修改生产实现。下表统计完整 SDK、React、宿主单元测试，以及包含父用例的浏览器测试；更早的实现记录保留当时数量。

| 测试集 | 原数量 → 当前数量 | 单元测试行 / 分支覆盖率 | 命令 / 证据 |
| --- | --- | --- | --- |
| TypeScript SDK | 253 → **304 项通过**（+51） | **99.27% / 95.66%** | `npm --prefix sdks/typescript run test:coverage`；`.local/roadmap-sdk-coverage.log` |
| React 适配包 | 7 → **20 项通过**（+13） | **100% / 100%** | `npm --prefix sdks/react run test:coverage`；`.local/roadmap-react-coverage.log` |
| OIDC 宿主桥接 | 16 → **56 项通过**（+40） | **100% / 98.26%** | `npm --prefix examples/inbox-react run test:coverage`；`.local/roadmap-auth-coverage.log` |
| 真实浏览器流程 | 10 → **14 项通过**（+4） | 不计入单元测试覆盖率 | `bash scripts/react.sh`；`.local/roadmap-browser-tests.log` |

SDK 回归覆盖重试默认值与非法预算、Run 受理回执恢复、临时与永久错误、并发幂等键及取消隔离、其他调用认证失败时终止退避、回执查询期间取消 / 关闭、HTTP 日期及数字重试等待、选择器生命周期和状态元数据、确定性生成、全部操作种类，以及嵌套 schema / 默认值语义。编译期断言验证操作种类筛选、Run 输入与结果、Presence 必填参数和 meta，以及 React 投影数据与原始订阅句柄的类型；该历史轮次中的旧契约兼容断言已在预发布清理时移除，当前断言要求缺少 kind 或 presence 的契约编译失败。

React 回归覆盖无需 Provider 的直接调用、缺失 Provider 报错、客户端 / 查询名 / 模式切换、旧私有消息隔离、选择器切换、等价参数、独立监听释放、连续 120 次参数切换、已有客户端数据时的 SSR、非法及超大 JSON、重复释放和满容量时共享查询。OIDC 回归覆盖回调歧义、state 到期、签名 / 声明失败、发现及配置拒绝、机密客户端认证、错误项目令牌、签发与轮换失败、并发刷新、待登录 / 宿主会话容量上限、到期、撤销并发与退避，以及关闭和签发竞态。假时钟身份测试的签名 `iat` 使用同一时钟生成。

新增浏览器场景验证生产静态资源与源码边界、永久错误时乐观回滚、自动恢复耗尽后的手动恢复，以及退避期间退出。测试连接真实 PostgreSQL 和 Fyrlet，使用签名本地测试 IdP。未知预测仍遵循文档中的显示 TTL；手动恢复断言只执行一次业务写入，最终只显示一条记录。不生成截图。

Node 覆盖率仅统计单元测试加载的 SDK / React `dist/**/*.js` 和宿主 `server/*.mjs` 模块，不覆盖浏览器构建产物、Elixir 或生产身份服务。CI 已改为运行这三组覆盖率命令和浏览器测试；远程 CI 仍待执行。

SDK、React 类型检查及 **20 项真实 HTTP/WebSocket 集成测试**也已通过（`INTEGRATION_PORT=4203 bash scripts/integration.sh`；`.local/roadmap-integration-tests.log`）。文档站和本地产物随本轮扩充记录重新构建。

## 2026-11-08：React、契约类型、登录桥接与有界重试

分支 `feat/react-contract-auth-retry` 在本地完成路线图里程碑 2–5：独立 React 适配包及 Inbox 页面、Presence 与操作种类类型生成、宿主 OIDC 登录桥接，以及可选的有界重试。下方可靠性记录属于更早一轮，保留当时的数量。

| 验证 | 结果 | 命令 / 证据 |
| --- | --- | --- |
| Elixir 核心、示例与独立包 | **764 项通过**：核心 694、示例 35、包 35 | `bash scripts/test_all.sh`；`.local/roadmap-server-tests.log` |
| TypeScript SDK | **253 项通过**，类型检查通过 | `npm --prefix sdks/typescript test`、`npm --prefix sdks/typescript run typecheck`；`.local/roadmap-sdk-tests.log` |
| React 适配包 | **7 项通过**，类型检查通过 | `npm --prefix sdks/react test`、`npm --prefix sdks/react run typecheck`；`.local/roadmap-react-tests.log` |
| OIDC 宿主桥接 | **16 项通过** | `npm --prefix examples/inbox-react test`；`.local/roadmap-auth-tests.log` |
| 真实 HTTP / WebSocket 集成 | **20 项通过**，含响应丢失后的回执恢复与不重放验证 | `INTEGRATION_PORT=4203 bash scripts/integration.sh`；`.local/roadmap-integration-tests.log` |
| 浏览器流程 | **10 项通过**：1 个父用例与 9 个场景，连接真实 PostgreSQL、Fyrlet 和签名测试 OIDC 提供方 | `bash scripts/react.sh`；`.local/roadmap-browser-tests.log` |
| CORS | **10 项通过**，含向浏览器暴露 `Retry-After` | `mix test test/fyrlet_web/cors_test.exs`；`.local/roadmap-cors-tests.log` |
| Elixir 质量与契约一致性 | 格式、无警告编译、Inbox 新导出契约比较通过 | `mix format --check-formatted`、`mix compile --warnings-as-errors`、`node scripts/check_contract.mjs .local/roadmap-contract.json` |
| 生产示例与文档 | 应用生产构建、文档站构建及链接检查通过 | `npm --prefix examples/inbox-react run build`、`npm --prefix site run build`、`npm --prefix site run check`；`.local/roadmap-web-build.log`、`.local/roadmap-site-build.log`、`.local/roadmap-site-check.log` |
| 分发 | 当时构建 3 个本地产物，核心与 React 安装包在外部消费者中导入通过 | `bash scripts/package.sh`、`bash scripts/install_smoke.sh`；`.local/roadmap-package.log`、`.local/roadmap-install.log`、`.local/releases/manifest.json` |

React 验证覆盖多组件共享与最后引用释放、参数规范化、客户端及模式隔离、Strict Mode、未提交渲染、选择器、查询数量上限，以及一致的 SSR / hydration 初态。浏览器场景覆盖登录、共享订阅、乐观写入与权威视图确认、提交后丢失响应、仅响应头提供的重试等待、双标签页、参数切换、断线重连、令牌刷新、退出、用户 / issuer 隔离和宿主撤销。浏览器流程保留窄屏布局检查，不生成截图。

重试默认关闭，启用时必须提供操作元数据；所有尝试固定序列化输入与幂等键。写入或 Run 一旦结果未知，后续只恢复回执；回执不存在或过期时继续保持未知，不重放业务操作。测试覆盖尝试次数与总时长上限、取消、认证失败和 `Retry-After`；操作结果与视图确认仍分别报告。

[Inbox 配置说明](../../examples/inbox-react/README.zh-CN.md)提供真实身份服务的接入方式。本地 OIDC 测试使用签名测试提供方，验证 PKCE、state、nonce、issuer / audience 校验和服务端持有会话，不等于完成生产身份服务验收。宿主在单进程内维护有界会话，退出、到期或宿主作废会清理登录态；外部 IdP 撤销仍依赖宿主作废或到期。远程 CI、实体设备、多主机部署、24 小时稳定性和注册表发布不计入本次验收。

## 2026-11-08：可靠性修复与订阅能力补齐

分支 `fix/reliability-and-subscription-improvements` 完成业务 403 隔离、监听器异常隔离、关联式权威视图确认、可选客户端查询复用、带续排和指标的清理预算、数据库就绪探针与核心 CI。React 接入、生产容量和远程 CI 执行不计入本轮本地验收。下方按日期保留旧轮次的数量与状态。

| 验证 | 结果 | 命令 / 证据 |
| --- | --- | --- |
| Elixir 核心、示例与独立包 | **764 项通过**：核心 694、示例 35、包 35 | `bash scripts/test_all.sh`；`.local/all-tests.log` |
| TypeScript SDK | **232 项通过**，类型检查通过 | `npm --prefix sdks/typescript test`、`npm --prefix sdks/typescript run typecheck`；`.local/sdk-review-tests.log` |
| 真实 HTTP / WebSocket 集成 | **19 项通过**，含客户端查询复用、提交后确认及结果不变时确认 | `INTEGRATION_PORT=4197 bash scripts/integration.sh`；`.local/integration-review.log` |
| Elixir 质量检查 | 格式检查、无警告编译通过 | `mix format --check-formatted`、`mix compile --warnings-as-errors` |
| 契约一致性 | Inbox 最新导出与已检入契约、生成 SDK 类型一致 | 导出后执行 `node scripts/check_contract.mjs .local/ci/contract.json` |
| 文档站点 | 构建 62 页，检查 3080 个内部链接与 27 个仓库目标，无失效链接 | `npm --prefix site run build`、`npm --prefix site run check` |

确认回归覆盖无关与旧快照、delta、连续写入、多订阅、结果不变 / 空 append 快照、超时、取消、重连、权限撤销、旧服务端与畸形确认列表。写入响应前退订会返回视图未确认，保留操作的已提交结果；重复确认 ID 不影响其他等待者。服务端覆盖私有 / 共享查询、热缓存旁路和旧快照尚未 ACK 时的 append 重置。清理测试验证共享行数 / 时间预算、续排、流 floor 与保留保护；就绪测试验证正常查询及脱敏 HTTP 503。

CI 配置在 Elixir 1.18 / OTP 27 与 Elixir 1.20 / OTP 29 上运行上述测试、类型检查、契约比较和集成，使用 PostgreSQL 17 与 Node 24。本轮仅执行下文记录的本地环境，不宣称 GitHub 托管运行已通过。该历史轮次之后，会话到期索引已折入唯一核心基线；执行过旧拆分迁移的开发／测试数据库需重建，不能靠重复迁移原地升级。清理时间在 SQL 之间检查，不中断运行中的语句；行数统计不含外键级联。本轮未新增吞吐、多主机或长期稳定性的性能结论。

## 2026-11-07：历史验证

本历史轮次继续完成当时本机可执行的开发与验证；彼时 Hex/npm 正式发布及许可证决策按要求暂缓。真实邮件凭证与收件人尚未提供，实体移动设备、多主机生产环境与 24 小时稳定性仍待验收，不计入已通过结果。

### 已通过的验证

同日路线图 1A 开发通过：**687 项 Elixir 测试**（核心 617、示例 35、独立包 35）、**132 项 SDK 单元测试**、SDK 类型检查与 **18 项真实服务端集成**。相较上一轮新增 16 项 Elixir、29 项 SDK 单元与 3 项集成测试。覆盖读完成 / 写提交 / 持久受理、确定失败与未知结果、发送前后取消、响应体停滞、监听清理、回执过期、规范化输入、权限与身份隔离。真实 HTTP 和 Socket 用例在数据库提交后故意丢弃回复，恢复原回执，并断言只存在一条业务记录、没有重放。复现命令：`bash scripts/test_all.sh`、`npm --prefix sdks/typescript test`、`npm --prefix sdks/typescript run typecheck`、`INTEGRATION_PORT=4197 bash scripts/integration.sh`。恢复边界见[操作结果文档](MUTATIONS.md)；订阅权威视图确认（1B）尚未交付。

下表保留 2026-11-07 较早一轮的运行记录。同日后续架构、订阅内存与代码质量回归最终通过：核心 601 项、示例 35 项（含 Inbox 18 项）、独立包 35 项、SDK 单元 103 项、SDK 类型检查、真实服务端集成 15 项（`INTEGRATION_PORT=4197 bash scripts/integration.sh`）。最新一轮增加 9 项通道生命周期、3 项 SDK 句柄与控制消息回归。覆盖包括事务清理与去重、定义校验、请求取消与刷新总超时、通道故障隔离、乐观写入乱序完成，以及私有视图嵌入、snapshot/delta 推送、ACK 恢复、权限撤销、快照预算、跨通道节点配额与定时器清理。Inbox 的 360 步混合变更逐步对照独立窗口模型和实时快照。共享查询计数用例在同步初始 ACK 后连续 11 轮通过。内存和 Tracker 测量见 [OPTIMIZATIONS.md](OPTIMIZATIONS.md#13-私有订阅进程与编码缓存2026-11-07)，代码精简及 Presence 归属修复见第 14 节。其余验收结果沿用下表记录。能力级别的实现状态与验收矩阵见 [STATUS.md](STATUS.md)。

代码质量回归首次全量运行时，两项 `SessionChecksTest` 用例收到额外批处理遥测事件，结果为 599/601。随后会话检查与生命周期子集 17 项通过，原种子 `926877` 加 `--trace` 的全量 601 项通过，最终 `bash scripts/test_all.sh` 的 671 项 Elixir 测试全部通过。首次事件计数干扰保留在记录中，来源尚未确定。

| 验证 | 结果 | 入口 / 证据 |
| --- | --- | --- |
| Elixir 核心、应用与独立包 | 550 项：核心 495、应用 20、包 35 | `bash scripts/test_all.sh` |
| TypeScript SDK | 单元 44、类型检查、真实服务端 13 | `npm --prefix sdks/typescript test`、`npm --prefix sdks/typescript run typecheck`、`bash scripts/integration.sh` |
| 四领域 HTTP / WebSocket | 8 个业务与资源场景 | `DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh` |
| 浏览器交互与布局 | 四应用 × 三种视口，12 个流程 | `bash scripts/browser.sh`、[原始报告](../bench/browser-2026-11-07.json) |
| 同机双节点 | Chat 2 个场景、Agent 1 个场景；含 120 秒流量 | `bash scripts/cluster.sh`、[原始报告](../bench/cluster-2026-11-07.json) |
| 共享 / append 性能复验 | 共享视图构建与数据编码减少 96%；append 应用载荷减少 98.45% | [PERFORMANCE.md](PERFORMANCE.md#共享房间与追加流端到端对照2026-11-07) |
| 本地分发与仓库外安装 | 源码包、SDK tgz、SHA256；仓库外 Inbox / Agent 测试与 npm consumer | `bash scripts/package.sh`、`bash scripts/install_smoke.sh` |

环境为 macOS 26.6.2、Elixir 1.20.5 / OTP 29、Node 24.5.0、本机 PostgreSQL。各脚本新建独立项目，使用独立测试数据库；服务与浏览器由脚本启动并清理。原始报告不含服务密钥或用户令牌。

## 验证脚本

```sh
mix format --check-formatted
mix compile --warnings-as-errors
bash scripts/test_all.sh
npm --prefix sdks/typescript test
npm --prefix sdks/typescript run typecheck
(cd examples/inbox && mix fyrlet.contract ../../.local/ci/contract.json)
node scripts/check_contract.mjs .local/ci/contract.json
bash scripts/integration.sh
DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh
bash scripts/package.sh
bash scripts/install_smoke.sh
```

SDK 集成脚本使用独立的 `fyrlet_integration` 数据库，默认端口为 4100，可用 `INTEGRATION_PORT` 覆盖；当前验证 20 个真实 HTTP / WebSocket 场景，覆盖多设备、幂等并发、隔离、撤销、重启、Run、append、客户端查询复用、视图确认与混合通道。领域脚本默认用 4180/4181 端口，可按上例改端口，依次运行四个应用的 8 个业务与网页资源场景。所有脚本启动和关闭自己的服务，凭证和日志在 `.local/integration/`。分发包和 SHA256 清单在 `.local/releases/`，未发布到外部注册表。浏览器、双节点和真实邮件的验证见下文各节。

## 浏览器覆盖

先准备仓库依赖和数据库，再安装浏览器：

```sh
npm --prefix sdks/typescript ci
(cd sdks/typescript && npx playwright install chromium webkit)
bash scripts/browser.sh
bash scripts/browser.sh chat
```

默认服务 / 模拟供应商端口为 4210/4211，可用 `BROWSER_PORT` / `BROWSER_PROVIDER_PORT` 覆盖。数据库为 `<domain>_browser`。截图和每应用 JSON 写到 `.local/browser/`，登录表单遮蔽；本轮检查了 12 张截图。

| 模式 | 引擎 | 视口 |
| --- | --- | --- |
| 桌面 | Chromium 153.0.8010.12 | 1280 × 900 |
| Android 模拟（Pixel 5） | 同一 Chromium | 393 × 727，移动触控配置 |
| iPhone 模拟（iPhone 13） | WebKit 26.6 | 390 × 664，移动触控配置 |

覆盖登录、令牌输入清空、无持久存储、Notify 提交到模拟投递确认、Flow 信号与非法 JSON 拒绝、Agent 批准/拒绝/取消、Chat 双用户邀请/历史/人工接管/关闭/离开及纯文本防注入。每个流程断言无页面 JavaScript 异常和页面横向溢出，长英文标题另覆盖窄列换行。

这轮浏览器验证修复了两个实际问题：同源模块请求被 CORS 拦截；长标题撑宽桌面列或移动页面。CORS 现在按完整 scheme/host/port 放行同源来源，其他来源仍由允许列表约束；非法来源与不同端口有回归测试。

移动配置是浏览器模拟，不能代替实体 Android/iPhone 的键盘、系统字体、后台挂起与网络切换验收。截图用于本轮人工布局检查，尚未建立像素差分基线。

## 双节点、故障切换与持续流量

```sh
bash scripts/cluster.sh
CLUSTER_SOAK_SECONDS=600 CLUSTER_CLIENTS=20 bash scripts/cluster.sh chat
```

默认使用端口 4200–4204、两个命名 BEAM 节点、相同随机 cookie、共享 PostgreSQL、本地 HTTP/WebSocket 转发代理。数据库为 `<domain>_cluster`，`CLUSTER_BASE_PORT`、`CLUSTER_DATABASE_URL` 可覆盖。`CLUSTER_SOAK_SECONDS` 支持 5–86400 秒、`CLUSTER_CLIENTS` 支持 2–50；长时运行会在轮换重连和分页期间签发同主体新会话，不依赖延长 15 分钟会话上限。

Chat 验证跨节点共享和 append 通知、同幂等键并发写入只有一次提交、跨节点撤销即时清空、SIGKILL 后经代理重连另一节点、继续写入以及原节点重入。Agent 验证两节点启动同一 Run 的幂等性、owner 信号隔离、节点退出后持久等待可批准完成且任务只落库一次。此代理用于测试新连接目标切换；生产负载均衡器仍需独立配置和验收。

持续流量实测为 12 客户端、120 秒、2056 条持久消息、41 次重连和 41 次会话续期。全量历史逐条核对无空洞和重复，所有客户端实时窗口不超过 100 条。写入到全部客户端看到数据的 p50 为 32.01ms，p95 为 35.85ms，包含 25ms 状态轮询。运行中每约 10 秒采样一次资源；两节点读取缓存采样峰值为 29/34 项。连接关闭后两节点订阅、Observer 和读取缓存均归零。

测试还修复了共享订阅的撤销延迟：普通失效通知在投影内容未变化时也会复核全部成员，失权者立即关闭并清空，其他成员不收到多余快照；回归测试使用普通失效而非特殊成员变更信号。

本机双进程共享数据库的结果不等于多主机生产容量、网络分区恢复或 24 小时稳定性证明。生产部署步骤见 [OPERATIONS.md](OPERATIONS.md#可选双节点部署)。

## 真实邮件验收入口

```sh
bash scripts/mail_live.sh --check
bash scripts/mail_live.sh
```

必须在环境中显式设置 `RESEND_API_KEY`、Resend 已验证的 `MAIL_FROM` 和自己的 `MAIL_TO`。`--check` 只检查配置，不发送；正常运行向 `MAIL_TO` 发送一封邮件。工具使用真实 Notify 应用与 Resend，不启动模拟供应商；验证同幂等键返回同一 Run，并等待供应商查询确认 delivered 与站内记录、Run 完成。

默认端口 4212、数据库 `notify_live`、等待 180 秒；可覆盖 `MAIL_SMOKE_PORT`、`MAIL_SMOKE_DATABASE_URL`、`MAIL_SMOKE_TIMEOUT_SECONDS`（30–600 秒）。报告在 `.local/mail-live/result.json`，包含 Run ID，不包含密钥或地址。失败或超时会标为 `unverified` 并返回失败；先检查原 Run 后再决定是否重新发送。供应商确认不等于用户亲自看到收件箱，还需人工检查收件箱与垃圾邮件。

本轮预检查确认这三个变量缺失，未发送真实邮件。真实成功投递、退信、真实供应商中断仍未验收；本地协议模拟和浏览器中的 delivered 均不代替它们。
