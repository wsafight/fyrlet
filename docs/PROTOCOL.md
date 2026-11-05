# v1 业务与订阅协议

框架协议版本 `1`，业务契约版本 `0.1.0`。HTTP 使用 JSON，Socket 使用 Phoenix Channels v2 传输。UUID 与 UTC 时间是字符串，整数限 JavaScript 安全整数。契约采用项目实现的 `realtime-subset-v1`，不是完整 JSON Schema。

产品更名为 Fyrlet 后保留 `realtime-subset-v1` 这一已有协议标识。各语言 SDK 使用同一协议，不因语言或包名变化而另建服务端接口；SDK 目录和实现要求见 [SDK 总览](../sdks/README.md)。

## HTTP

所有响应不缓存。成功为 `{"request_id":"…","data":…}`，失败为 `{"request_id":"…","error":{"code":"…","message":"…","details":{},"retryable":false}}`。

| 入口 | 凭证 | 请求 / 结果 |
| --- | --- | --- |
| `GET /health` | 无 | 存活状态；不代表数据库就绪 |
| `POST /api/v1/sessions` | 服务密钥 Bearer | `{external_subject, issuer?, ttl_seconds?}` → token、project_id、subject_id、session_id、expires_at |
| `DELETE /api/v1/sessions/:id` | 服务密钥 Bearer | 撤销同项目会话 |
| `DELETE /api/v1/session` | 用户 Bearer + X-Project-Id | 撤销自身会话 |
| `GET /api/v1/contract` | 用户 Bearer + X-Project-Id | 导出的业务契约 |
| `GET /api/v1/identity` | 用户 Bearer + X-Project-Id | 当前 project_id / subject_id，用于 SDK 绑定身份 |
| `POST /api/v1/operations/:name` | 用户 Bearer + X-Project-Id | `{"input":{…}}` → 业务结果；写入必须有 Idempotency-Key |

请求体上限 64 KiB。默认幂等保留窗口 24 小时，以 project + subject + operation + key 为范围；相同规范化输入重放原结果，更换输入返回 CONFLICT。窗口之后不保证去重。仅本数据库事务内副作用受到保证。

| 错误码 | HTTP |
| --- | --- |
| UNAUTHENTICATED | 401 |
| FORBIDDEN | 403 |
| NOT_FOUND | 404 |
| VALIDATION_FAILED | 422（非法 JSON 为 400） |
| CONFLICT | 409 |
| LIMIT_EXCEEDED | 429（请求体超限为 413） |
| UNSUPPORTED_VERSION | 400 |
| INTERNAL_ERROR | 500 |

## Socket

连接 `/socket`，公开参数为 `project_id`。使用 Phoenix JS 的 `authToken` 选项，服务端启用 `auth_token: true`。用户令牌编码在 `Sec-WebSocket-Protocol`，不允许通过查询参数认证。Origin 按端点配置校验。

每个逻辑订阅使用独立 topic `subscription:<客户端随机 UUID>`。join 参数：

```json
{"protocol_version":1,"name":"inbox.recent","params":{"limit":50}}
```

join 成功直接返回初始 Snapshot；后续以 `snapshot` 事件推送同结构：

```json
{
  "protocol_version": 1,
  "subscription_id": "客户端 UUID",
  "generation": "服务端 UUID",
  "seq": 1,
  "project_id": "项目 UUID",
  "subject_id": "用户 UUID",
  "data": []
}
```

客户端用完整快照替换该订阅的数据，并发送 `ack` 事件 `{generation,seq}`。每个订阅最多一份待确认快照；等待期间只保留刷新标记，默认 15 秒未确认则关闭。超时不是数据丢失：重新订阅可获取当前完整结果。

`refresh` 事件参数 `{}`，回复 `{accepted:true}`，随后推送新快照。`phx_leave` 取消订阅。`status` 事件携带 `{"state":"closed","error":{…}}` 表示终止，随后 channel 关闭。认证失效也可能直接断开 Socket，SDK 在恢复时通过认证 HTTP 请求区分网络中断与失效凭证。

新 join 必须使用新的 generation；客户端仅接受当前 join 确认的 generation，拒绝旧实例事件。同一 generation 只应用大于当前 seq 的消息，重复消息仍可确认。seq 不是数据库版本或恢复游标。

## 收敛与资源

先订阅内部失效通知，再执行初始查询。每个 channel 串行查询，查询期间的失效消息排队并触发后续刷新。写入与 Oban 任务同事务提交；最外层事务成功后立即广播失效通知，Oban 任务保留为持久化重试路径。嵌套在调用方事务中的写入只通过提交后可见的 Oban 任务通知。任务可重复广播；默认每 30 秒重新授权并查询以修复遗漏通知。自动刷新结果未变化时不推送快照、序号保持不变；显式 refresh 仍返回新快照。此优化不改变 protocol_version 1 或 ACK 规则。

默认每连接 20 个订阅、每页 100 条、每快照 256 KiB、Socket 帧 64 KiB、channel 邮箱阈值 200 条。快照确认限制业务推送积压；网关仍应限制连接数、请求速率和传输带宽。

## SDK 恢复语义

断线后进入 recovering，保留上一份数据并明确标记未就绪。SDK 重新取得令牌、验证身份、重建连接与订阅；初始快照到达后才进入 ready。确认 UNAUTHENTICATED / FORBIDDEN 或关闭客户端时清空数据。账号变化应关闭旧 client 并创建新 client；SDK 拒绝在已有身份绑定的 client 中切换 Subject。

HTTP 401 最多调用一次 `getToken({forceRefresh:true})` 并重试，保持原幂等键。SDK 不自动重试业务冲突或不确定网络失败；调用者若重试写入应显式复用幂等键。移动端暂停时可关闭连接，恢复后创建 client 并重新查询。
