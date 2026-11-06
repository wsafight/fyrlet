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

### 传输帧

单帧仍为标准 Phoenix v2 JSON 五元素数组 `[join_ref, ref, topic, event, payload]`，两个 ref 为字符串或 null，topic / event 为字符串，payload 为非 null 对象（非数组）。服务端多帧出站消息为 `{"batch":[frame1,frame2,...]}`，batch 是唯一外层字段，最多 64 帧，按数组顺序分派。接收方接受单帧或含 1–64 帧的 batch；空批、超限或非法成员均为协议错误。

服务端只聚合同轮 transport mailbox 已有推送，自发送 flush 消息，不通过定时器等待凑批。默认聚合上限 64 帧、预算 256 KiB，可配置更低帧数；单条消息达到字节预算时独立发送，预算不是单条消息硬上限。单帧没有额外包装。batch 可以包含不同 topic 的快照、delta 或其他 Phoenix 帧，只是传输包装，不代表跨订阅事务、统一数据库版本或原子状态更新。客户端发送的 join / call / ACK 仍使用标准 Phoenix 帧，不要求服务端接受入站 batch；自写客户端需扩展 decoder，原生 Phoenix decoder 不能直接解释出站 batch。

### 订阅

每个逻辑订阅使用独立 topic `subscription:<客户端随机 UUID>`。join 参数：

```json
{"protocol_version":1,"name":"inbox.recent","params":{"limit":50}}
```

join 成功直接返回初始 Snapshot；后续以 `snapshot` 事件推送同结构：

```json
{
  "protocol_version": 1,
  "subscription_id": "客户端 UUID",
  "generation": "服务端随机标识",
  "seq": 1,
  "project_id": "项目 UUID",
  "subject_id": "用户 UUID",
  "delivery": "snapshot",
  "data": []
}
```

客户端用完整快照替换该订阅的数据，并发送 `ack` 事件 `{"g":generation,"s":seq}`。ACK 是单向通知，Phoenix frame 的 ref / join_ref 可为 null，服务端不发送 ACK 回执，SDK 不创建等待回复的 Push 或超时定时器。generation 为 16 个随机字节的无 padding Base64URL 编码，保留完整 128 位随机性；服务端仍同时核对 generation 和待确认序号。每客户端订阅最多一条待确认更新，默认 15 秒未确认则关闭；共享 Observer 不共享 ACK、generation 或 seq。慢端不会阻止 Observer 更新或其他设备接收，不缓存逐客户端补丁队列；慢端 ACK 后若已落后，重新授权并全量加载，再发送当前完整快照追平。超时不是数据丢失：重新订阅可获取当前完整结果。

`refresh` 事件参数 `{}`，回复 `{accepted:true}`，随后推送新快照。`phx_leave` 取消订阅。`status` 事件携带 `{"state":"closed","error":{…}}` 表示终止，随后 channel 关闭。认证失效也可能直接断开 Socket，SDK 在恢复时通过认证 HTTP 请求区分网络中断与失效凭证。

新 join 必须使用新的 generation；客户端仅接受当前 join 确认的 generation，拒绝旧实例事件。同一 generation 只应用大于当前 seq 的消息，重复消息仍可确认。seq 不是数据库版本或恢复游标。

### 增量协商

join 可增加 `"delivery":"delta-v1"`，服务端在初始完整快照中返回实际使用的 delivery。未请求增量的客户端继续收到完整快照。增量仅适用于每条记录都有唯一字符串 id 的数组，且客户端跟上上一视图修订；其他结果、显式 refresh、落后追平，或 patch JSON 字节数加 96 不小于完整数据字节数时，仍推送完整快照。共享 Observer 的内部 revision 不等于客户端 seq，也不作为线上的恢复游标。

后续 `delta` 事件示例：

```json
{
  "g": "服务端随机标识",
  "b": 1,
  "s": 2,
  "p": {
    "c": [["记录 UUID",{"text":"Updated","version":2}]]
  }
}
```

p 为紧凑 patch，可包含 a（完整新记录数组）、c（变更元组数组）、r（删除 ID 数组）、o（结果的完整 ID 顺序）。每个变更元组为 `[id,fields]` 或 `[id,fields,cleared]`，cleared 为需要删除的字段名数组。字段赋值 null 与删除字段不同。成员或顺序变化时携带 o。g、b、s 分别表示 generation、base_seq、seq；delta 的身份和订阅范围由当前 channel 的初始快照绑定。

客户端只在 b 等于当前 seq、s 等于 b + 1 时应用增量，然后确认新的 seq。旧 generation 忽略，重复 seq 可再次确认；发现序号缺口时重新加入订阅，以完整快照恢复。ACK、超时和最终视图大小限制同样适用于增量。项目尚未上线，服务端与 SDK 统一使用此格式，不保留旧字段格式或 ACK push/reply 的兼容分支。

### 业务调用

同一连接可加入 topic `operations`，参数为 `{"protocol_version":1}`。通过 Phoenix push/reply 调用 call：

```json
{"name":"inbox.update","input":{"id":"记录 UUID","text":"Updated","expected_version":1},"idempotency_key":"请求 UUID"}
```

成功回复 `{"data":…}`，失败回复 `{"error":{…},"status":409}`，由 Phoenix reply 的 ok / error 状态区分。写入必须携带 idempotency_key，其范围、保留时间和事务规则与 HTTP 相同。每次调用重新验证会话与业务权限；会话到期关闭 channel。业务执行与订阅共用连接，operations channel 内串行处理调用。身份验证、契约和服务端会话管理仍使用 HTTP。

## 收敛与资源

Observer 先订阅内部失效通知，再执行初始加载；串行维护规范化 View，查询期间的失效消息排队并触发后续刷新。仅服务端契约显式 `"shared": true` 才共享；key 是完整 Actor（project_id / subject_id / session_id / expires_at）加完整准备后的订阅描述（含规范化参数），节点本地。同 session 多设备可共享，不同 session 即使同用户也不共享；shared 不是 join 参数，也不会合并不同逻辑订阅的 ACK。每次计算前验证会话并执行业务授权，计算后再次验证会话；每次 attach 独立检查，即使复用已编码快照也无授权 TTL 缓存。

写入与 Oban 任务同事务提交；最外层事务成功后立即广播失效通知，Oban 任务保留为持久化重试路径。嵌套在调用方事务中的写入只通过提交后可见的 Oban 任务通知。Observer 去重最近 64 个通知 ID，不按 ID 大小过滤乱序；多个待处理刷新合并后回退全量加载。每个 Observer 只有一个协调定时器，默认每 30 秒重新授权并全量查询以修复遗漏通知。自动刷新可见数据未变化时不推送、序号保持不变；显式 refresh 在请求端可接收时仍返回完整快照。此实现不改变 protocol_version 1 或 ACK 规则。

规范化 View 及其 context 是服务端内部结构，不增加协议字段。收件箱的私有候选区最多 8 条，不发送给客户端；版本缺口或候选不足等不确定情况会重新加载，详情见服务端文档。服务端的记录版本检查与客户端的 delta seq 检查是不同层次的保护。

默认每连接 20 个订阅、每页 100 条、每快照 data 256 KiB、入站 Socket 帧 64 KiB、Observer 邮箱阈值 200 条。出站批处理预算默认 256 KiB，不含单条消息的硬上限保证。ACK 限制各客户端业务推送积压；网关仍应限制连接数、请求速率和传输带宽。

## SDK 恢复语义

断线后进入 recovering，保留上一份数据并明确标记未就绪。SDK 重新取得令牌、验证身份、重建连接与订阅；初始快照到达后才进入 ready。确认 UNAUTHENTICATED / FORBIDDEN 或关闭客户端时清空数据。账号变化应关闭旧 client 并创建新 client；SDK 拒绝在已有身份绑定的 client 中切换 Subject。

TypeScript SDK 安装自定义 decoder，在分派前验证整个单帧或 batch 的结构、帧数和成员，再按顺序交给 Phoenix。非法传输帧产生不可重试的 PROTOCOL_ERROR，不把非法批次前半部分当作有效更新；一次 batch 不合并多个 onChange，也不提供跨订阅原子回调。

运行中的 Observer 退出会向 channel 报告 retryable INTERNAL_ERROR；会话检查 worker 故障或超时同样以 retryable 内部错误失败，不放行未验证会话。SDK 收到 retryable status 时保留旧数据、进入 recovering，重建连接和订阅，以新 generation 的完整快照恢复。默认重试延迟从 250 ms 指数增长，最大 30 秒，可由 retryDelayMs 覆盖。attach 调用退出时服务端内部重试一次；当前 SDK 对 join error 仅在 UNAUTHENTICATED 时自动恢复，其他 join 错误需显式 reconnect，不能将运行中 status 的恢复保证泛化到所有 join 失败。

HTTP 401 或 Socket 调用返回认证失效时，最多调用一次 `getToken({forceRefresh:true})` 并重试，保持原幂等键。SDK 不自动重试业务冲突或不确定网络失败；调用者若重试写入应显式复用幂等键。移动端暂停时可关闭连接，恢复后创建 client 并重新查询。
