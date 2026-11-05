# 服务端业务开发

当前应用是可运行的参考实现，核心在 lib/fyrlet，传输在 lib/fyrlet_web，示例在 Fyrlet.Example.Inbox。首版通过配置注册受信任的业务模块，不提供动态加载租户代码。

## 注册定义

业务模块实现 Fyrlet.Definition：

| 回调 | 责任 |
| --- | --- |
| contract/0 | 声明 operations / subscriptions、输入输出 schema、操作 read / write 类型 |
| authorize/3 | 根据服务端 Actor 和规范化输入进行操作级授权 |
| execute/3 | 查询或执行业务，返回 `{:ok, data, affected_scopes}` 或 `{:error, %Fyrlet.Error{}}` |
| scope/3 | 返回该订阅依赖的内部通知主题 |

在 config/config.exs 的 definitions 列表中注册模块。启动时验证回调、名称、操作类型和 schema。完整示例为 lib/fyrlet/example/inbox.ex。

schema 支持封闭对象、字符串及字符串 enum、boolean、JavaScript 安全整数、array、null、anyOf，以及 uuid / date-time 字符串格式。它不是完整 JSON Schema；不支持浮点数、任意属性对象、引用或递归类型。高精度业务值应使用明确的字符串编码。

## 查询与授权

Actor 的 project_id / subject_id / session_id 来自已验证会话，不来自业务输入。以收件箱为例：

```elixir
from item in Fyrlet.InboxItem,
  where: item.project_id == ^actor.project_id and item.subject_id == ^actor.subject_id
```

上述数据库过滤负责行级数据范围。authorize 的 :ok 只表示允许执行这个业务，不能替代查询过滤。拥有记录 UUID 或命中 Scope 都不授予权限。角色和团队关系可以加入应用自己的表与 authorize 逻辑；本期参考应用只实现个人所有权。

## 事务与失效通知

write 操作的 execute 运行于框架事务内。应用可以使用 Repo 或 Ecto.Multi 处理自己的领域数据，成功后返回有变化的 Scope 列表。框架在输出校验通过后写入幂等结果及 Oban 任务，最后一起提交。最外层事务成功提交后立即广播失效通知，订阅刷新不必等待 Oban 调度；持久化任务仍会执行，覆盖提交后进程退出或即时广播失败的情况。命中幂等缓存不再次广播。若调用方已开启 Repo 事务，框架无法确定外层何时提交，因此仅使用持久化任务通知，避免广播尚未提交或最终回滚的写入。

不要在回调中提前广播正文或产生不可回滚的外部副作用。异步外部工作应由单独的持久化任务执行，并自行定义重试与补偿。

收件箱 Scope 形式为 `projects:<project>:subjects:<subject>:inbox`。即时通知与持久化任务都只广播 `{:invalidated, job_id}`，不携带业务正文。channel 保存最近 64 个通知 ID，跳过已处理的持久化重试；不按 ID 大小丢弃乱序通知，旧 ID 被淘汰后重放仅导致一次安全的重新查询。新通知与周期校验都会为当前 Actor 重新授权和读取，周期校验也负责修复遗漏通知。每个 channel 串行查询，先建立通知监听再读取初始数据；确认未到达时合并后续刷新请求。自动刷新使用快照内容的 SHA-256 指纹识别相同结果，无变化时不推送、不增加序号；仍执行完整授权和大小校验。显式 refresh 即使结果未变化也推送快照。channel 仅保存指纹，不保留上一份完整数据；快照大小与指纹共用一次 JSON 编码。

结果范围必须有界。参考订阅只包含最近一页，历史记录通过 inbox.history 的 keyset 游标读取。快照超限关闭订阅并返回 LIMIT_EXCEEDED，不截断成看似完整的数据。

## 运维入口

```sh
mix fyrlet.project --output .local/project.json "My App"
mix fyrlet.contract priv/contract.json
mix fyrlet.revoke_key KEY_ID
mix fyrlet.prune
```

project 输出文件权限为 0600，已有文件会拒绝覆盖。prune 可由部署环境定时执行。密钥管理命令属于受信任控制面，本期不开放 HTTP 管理项目或密钥接口。

当前配置中的关键限制包括 max_subscriptions、max_snapshot_bytes、max_channel_queue、snapshot_ack_timeout、reconciliation_interval、idempotency_ttl。单个数据库语句超时由 Repo 的 PostgreSQL statement_timeout 控制；任意 Elixir CPU 任务没有通用强制隔离超时，业务回调应保持短小。

Telemetry 事件包括 fyrlet.operation.stop、fyrlet.subscription.query、fyrlet.subscription.snapshot 和 fyrlet.subscription.count，另有 Ecto / Oban 自身事件。duration 为 monotonic native 单位，bytes 为快照 JSON 字节，active 为当前本节点订阅数。默认关闭 Phoenix 连接参数及 channel 参数日志，业务异常只记录异常类型，客户端得到统一错误。

## 当前发布边界

当前完成单节点参考应用及本地 SDK；尚未发布独立 Hex 包、npm 包或商业托管平台。完整容量基线、跨节点部署、全局配额、管理 UI、OIDC 验证器与密钥轮换界面后续实现。
