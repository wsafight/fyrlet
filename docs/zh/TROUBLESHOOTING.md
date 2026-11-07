# 常见问题与排查

[English](../TROUBLESHOOTING.md) | 简体中文

先定位失败发生在哪一层：宿主启动、后端会话交换、浏览器 HTTP、Socket 订阅或外部 Effect。重试前记录错误码和请求 ID。[协议](PROTOCOL.md#http)定义错误语义，[接入教程](TUTORIAL.md)提供最小参考流程。

## 宿主启动与数据库

| 现象 | 检查 | 处理 |
| --- | --- | --- |
| 服务已启动，但 `inbox.add` 返回 `NOT_FOUND` | 根目录配置默认没有业务定义 | 启动 `examples/inbox`，或在宿主的 `definitions` 中注册自己的定义 |
| 连接被拒绝或数据库不存在 | PostgreSQL 端口、`DATABASE_URL`、数据库名和当前宿主目录 | 在根目录用 `bash scripts/postgres.sh start` 启动本地数据库，再到目标宿主运行 `mix fyrlet.migrate --create` |
| 缺少表或字段 | 迁移与运行是否使用相同数据库和 `migration_paths` | 执行宿主迁移，见[安装步骤](INSTALL.md#安装步骤) |
| 项目输出文件已存在 | `mix fyrlet.project` 会主动拒绝覆盖凭证 | 只在原数据库复用该文件，或使用其他输出路径创建新项目 |
| 切换数据库后，格式正确的服务密钥被拒绝 | 凭证对应的是另一个数据库中的项目 | 在目标数据库创建项目，并配置配套的项目 ID 与服务密钥 |

核心迁移在发布前合并过，较早的开发数据库可能需要重建，见[安装文档](INSTALL.md)。修改数据库前保留需要的数据；生产迁移与备份策略由宿主部署决定。

## 浏览器连接与 Origin

在浏览器 Network 面板核对真实的协议、主机与端口。`localhost` 和 `127.0.0.1` 是不同源，不同端口也是不同源。SDK 的 `endpoint` 指向 Fyrlet 服务，`/api/fyrlet/session` 是宿主自己的登录后端路由，不要把 SDK 指向 Astro 文档站。

假设浏览器应用在 `http://localhost:5173`，在 Inbox 宿主目录启动：

```sh
ALLOWED_ORIGINS=http://localhost:5173 CORS_ORIGINS=http://localhost:5173 PHX_SERVER=true PORT=4000 mix phx.server
```

`CORS_ORIGINS` 控制跨源 HTTP，`ALLOWED_ORIGINS` 控制 Socket 的 Origin 校验。浏览器与服务分源时两项都要配置。HTTPS 页面需要 HTTPS 服务，网关还需转发 WebSocket 升级请求。配置见[必需配置](INSTALL.md#必需配置)。

## 登录与授权

- 宿主会话接口返回 401，表示应恢复宿主登录。浏览器 `getToken` 应抛出 `UNAUTHENTICATED` 的 `ApiError`，结束自动恢复并清空私有数据。
- Fyrlet 返回 401，可能是令牌过期、撤销或不匹配。核对 endpoint、项目、过期时间和后端服务密钥。服务密钥以 `rtk_` 开头，只用于后端；用户会话令牌以 `rts_` 开头。
- `FORBIDDEN` 表示身份已验证，但业务操作或订阅未获授权。检查业务定义的授权，以及项目、用户和成员约束。应用可以用 `NOT_FOUND` 隐藏不可访问记录。
- 切换账号时先 `close()` 旧客户端，再创建新实例。相同客户端切换到另一个 Subject 会被拒绝。

详见[鉴权](AUTH.md)和[后端会话交换](../../sdks/typescript/README.zh-CN.md#后端交换会话)。问题报告中不要包含令牌或服务密钥。

## 订阅为空或持续恢复

`ready` 状态下的数据为空可能符合预期：当前主体没有记录、记录已归档，或参数过滤了结果。先核对规范化输入和 SQL scope，再排查传输恢复。`inbox.recent` 属于当前登录主体，并非项目内所有用户。

`connecting` 表示首次加入，`recovering` 表示保留旧视图并恢复订阅。持续恢复时检查错误码与服务端日志。可重试的首次加入错误会在该订阅上重试，连续失败超过 10 次才进入错误状态；认证失败可能重建整个连接。详见[订阅状态](../../sdks/typescript/README.zh-CN.md#订阅状态)。

写入成功但视图一直不更新，检查是否通过 Fyrlet 的受管事务提交、是否返回正确失效范围，以及订阅是否仍有效。`refresh()` 只确认服务端接受刷新请求，收到新数据要观察 `onChange`。共享订阅仍会复核成员与授权；断线恢复获取完整快照，不补放历史 delta。

## 写入、冲突与限制

| 错误或现象 | 含义 | 处理 |
| --- | --- | --- |
| 超时、取消或 `NETWORK_ERROR` | 客户端无法确认服务端是否提交 | 只在保留期内复用原幂等键与相同输入重试 |
| `CONFLICT` | 同一键被用于不同输入，或 `expected_version` 已过时 | 确认冲突类型，刷新记录并由用户解决，避免盲目重试 |
| `VALIDATION_FAILED` | 输入不符合服务端契约 | 检查 `details` 并修正；契约变动后重新生成类型 |
| `LIMIT_EXCEEDED` | 请求、速率、快照、Observer 或订阅达到限制 | 检查 `details` 与 `retryable`；减小数据或窗口，释放无用订阅，或调整对应宿主限制 |

幂等保留期有限，也不覆盖外部副作用。乐观界面是本地预测，失败会回滚；提交前计算的推送可能使预测短暂消失，它不提供离线写入队列。详见 [SDK](../../sdks/typescript/README.zh-CN.md) 和[容量](OPERATIONS.md#数据保留与容量)。

## 可选能力与生成类型

`UNSUPPORTED_CAPABILITY` 表示服务端配置、客户端声明或最终协商交集中缺少所需能力。检查两端 `capabilities` 与业务定义的操作种类，Run、append、presence 都需要对应能力，见[能力协商](PROTOCOL.md#能力协商)。

变更契约后，从正确宿主导出，再生成类型并重建消费端应用。生成业务类型当前不包含 `presence` 段，`fyrlet.run` 是内置订阅而非生成内容。未知操作也可能说明实际运行的宿主或定义与生成类型时不同。

## Run 与外部 Effect

Run 或信号被受理，不代表已完成或已消费。通过 Run 视图检查等待、步骤与 Effect。`fenced_timeout` 取消只阻止后续推进，不能证明外部工作已停止，见[持久 Run](RUNS.md)。

`EFFECT_UNKNOWN` 或邮件 `unknown` 需要与供应商对账，不能自动重新发送。`accepted` 只表示受理，`delivered` 才表示供应商报告投递。Flow 还要检查 HTTP 适配器的 `allowed_hosts`；明文 HTTP 需要显式配置 `allow_http: true`。详见 [Effect](EFFECTS.md)、[Notify](../../examples/notify/README.zh-CN.md) 和 [Flow](../../examples/flow/README.zh-CN.md)。

## 收集可复现证据

记录宿主应用、服务端与 SDK 版本、操作或订阅名、脱敏输入，以及错误的 `code`、`details`、`retryable`、`status` 和 `requestId`。说明重新连接后能否稳定复现，并附上移除凭证和私有数据后的相关服务端日志与浏览器请求时间。

尽量收敛到一个主体、操作或订阅，从 [Inbox 示例](../../examples/inbox/README.zh-CN.md)开始，再执行[验收记录](ACCEPTANCE.md)中的对应检查。性能测量与功能复现分开进行；生产容量与实体移动设备行为仍不在本地验收范围内。
