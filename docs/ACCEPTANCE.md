# 本地验收记录（2026-11-07）

本轮继续完成本机可执行的开发与验证；Hex/npm 正式发布及许可证决策按要求暂缓。真实邮件凭证与收件人尚未提供，实体移动设备、多主机生产环境与 24 小时稳定性仍待验收，不计入已通过结果。

## 已通过的验证

下表是 2026-11-07 当天的运行记录。此后核心测试增至 527 项、SDK 单元测试增至 63 项（新增项目配额、Prometheus 指标、在线状态、乐观写入、租约与并发上限、加入失败恢复等），其余套件尚未按此重跑。能力级别的实现状态与验收矩阵见 [STATUS.md](STATUS.md)。

| 验证 | 结果 | 入口 / 证据 |
| --- | --- | --- |
| Elixir 核心、应用与独立包 | 550 项：核心 495、应用 20、包 35 | `bash scripts/test_all.sh` |
| TypeScript SDK | 单元 44、类型检查、真实服务端 13 | `npm --prefix sdks/typescript test`、`npm --prefix sdks/typescript run typecheck`、`bash scripts/integration.sh` |
| 四领域 HTTP / WebSocket | 8 个业务与资源场景 | `DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh` |
| 浏览器交互与布局 | 四应用 × 三种视口，12 个流程 | `bash scripts/browser.sh`、[原始报告](bench/browser-2026-11-07.json) |
| 同机双节点 | Chat 2 个场景、Agent 1 个场景；含 120 秒流量 | `bash scripts/cluster.sh`、[原始报告](bench/cluster-2026-11-07.json) |
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
bash scripts/integration.sh
DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh
bash scripts/package.sh
bash scripts/install_smoke.sh
```

SDK 集成脚本使用独立的 `fyrlet_integration` 数据库及 4100 端口，验证 13 个真实 HTTP / WebSocket 场景，覆盖多设备、幂等并发、隔离、撤销、重启、Run 与 append。领域脚本默认用 4180/4181 端口，可按上例改端口，依次运行四个应用的 8 个业务与网页资源场景。所有脚本启动和关闭自己的服务，凭证和日志在 `.local/integration/`。分发包和 SHA256 清单在 `.local/releases/`，未发布到外部注册表。浏览器、双节点和真实邮件的验证见下文各节。

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
