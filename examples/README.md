# 领域应用

Notify、Flow、Agent、Chat 是四个独立 Mix 应用，共用 Fyrlet 的公共接口、仓库与运行时，各自拥有领域模型、迁移、配置和测试。网页由普通宿主 Plug 提供，资源在 `support/`，使用真实 TypeScript SDK，编译时嵌入资源，无需 CDN。

## 本地启动与登录

先在仓库根目录准备依赖：

```sh
bash scripts/postgres.sh start
mix deps.get
npm --prefix sdks/typescript ci
npm --prefix sdks/typescript run build
```

以下以 Chat 为例；另三个应用将目录替换为 `notify`、`flow` 或 `agent`：

```sh
cd examples/chat
mix fyrlet.migrate --create
PHX_SERVER=false mix run ../../scripts/example_session.exs alice
PHX_SERVER=true PORT=4180 mix phx.server
```

打开 `http://127.0.0.1:4180/`，输入脚本输出的 `project_id` 和 `token`。应用默认连接本机 55432 上的 `<domain>_example_dev` 数据库；需要覆盖时，会话脚本、迁移和服务都使用同一个 `DATABASE_URL`。不同应用并行运行时分别指定端口。

会话脚本仅允许开发环境，项目服务密钥保存在忽略目录 `.local/examples/<domain>.json`，文件权限为 0600；输出只含项目、主体、用户会话令牌与过期时间。令牌 15 分钟有效，过期后重跑即可。同一 `alice` 会回到同一项目和主体；传 `bob` 可签发同项目另一用户，用另一个浏览器窗口验证邀请或隔离。页面只在内存保存用户令牌，不接收服务密钥。生产系统需接入宿主的真实登录流程。

## 验证

各应用目录运行 `mix test`。仓库根目录运行：

```sh
bash scripts/test_all.sh
DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh
(cd sdks/typescript && npx playwright install chromium webkit)
bash scripts/browser.sh
bash scripts/cluster.sh
```

领域端到端脚本创建独立测试项目，使用 `<domain>_integration` 数据库，启动并清理自己的服务；Notify / Flow 的外部 HTTP 由本地测试供应商模拟。浏览器脚本另外运行三种视口的交互、布局检查与截图，使用 `<domain>_browser` 数据库和 4210/4211 端口；双节点脚本使用 `<domain>_cluster` 数据库和 4200–4204 端口，默认持续流量 120 秒。可分别指定应用名缩小验证范围。真实邮件、实体移动设备与生产容量另行验收，详细证据与命令见 [ACCEPTANCE.md](../docs/ACCEPTANCE.md)。

## 应用边界

| 应用 | 已实现 | 未包含 |
| --- | --- | --- |
| [Notify](notify/README.md) | 私有站内通知、Resend 邮件、Run / Effect 与投递对账 | 真实投递验收、多渠道、模板与偏好 |
| [Flow](flow/README.md) | 保存私有流程、顺序 HTTP / 等待节点、信号与重启恢复 | 分支、循环、画布、跨节点数据传递 |
| [Agent](agent/README.md) | 两个有限文本工具、审批 / 拒绝、任务记录与取消 | LLM、RAG、任意工具执行 |
| [Chat](chat/README.md) | 登录与邀请、成员分配、人工接管、共享状态、append 消息和分页历史 | 匿名可写入口、搜索、附件、生产客服系统 |

安装与公共接口见 [INSTALL.md](../docs/INSTALL.md)，实现状态见 [STATUS.md](../docs/STATUS.md)。
