# 业务与订阅协议

协议版本 `protocol_version` 目前只有 `1`：加入通道时必须带上它，其他值返回 `UNSUPPORTED_VERSION`。可选能力通过[能力协商](#能力协商)启用。业务契约版本 `0.1.0`。HTTP 使用 JSON，Socket 使用 Phoenix Channels 的 v2 传输序列化。UUID 与 UTC 时间是字符串，整数限 JavaScript 安全整数。契约方言标识为 `realtime-subset-v1`，不是完整 JSON Schema。

各语言 SDK 使用同一协议，不因语言或包名变化而另建服务端接口；SDK 目录和实现要求见 [SDK 总览](../sdks/README.md)。

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

| 错误码 | HTTP | 含义 |
| --- | --- | --- |
| UNAUTHENTICATED | 401 | 身份缺失、无效、过期或已撤销 |
| FORBIDDEN | 403 | 已认证但无权执行；不应暴露存在性的记录，按应用策略统一返回 `NOT_FOUND` |
| NOT_FOUND | 404 | 操作或对当前用户可见的记录不存在 |
| VALIDATION_FAILED | 422（非法 JSON 为 400） | 输入不符合契约 |
| CONFLICT | 409 | 幂等键输入冲突或记录版本冲突 |
| LIMIT_EXCEEDED | 429（请求体超限为 413） | 超过订阅、数据量、速率或执行资源限制；`retryable` 指明是否值得稍后重试 |
| UNSUPPORTED_VERSION | 400 | 客户端协议版本不受支持 |
| UNSUPPORTED_CAPABILITY | 400 | 调用依赖的能力未启用或未协商 |
| EFFECT_UNKNOWN | 409 | 依赖的外部副作用结果未知，不得自动重发外部业务 |
| EFFECT_CONFLICT | 409 | 同一副作用键对应了不同请求 |
| LEASE_LOST | 409 | 执行器的租约已失效，应停止这次尝试 |
| INTERNAL_ERROR | 500 | 未预期的服务端失败；不暴露堆栈或数据库细节 |

HTTP 状态码与错误码的对应关系在本文固定，业务不自行选择。

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
  "capabilities": {},
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

客户端只在 b 等于当前 seq、s 等于 b + 1 时应用增量，然后确认新的 seq。旧 generation 忽略，重复 seq 可再次确认；发现序号缺口时重新加入订阅，以完整快照恢复。ACK、超时和最终视图大小限制同样适用于增量。

### 业务调用

同一连接可加入 topic `operations`，参数为 `{"protocol_version":1}`。通过 Phoenix push/reply 调用 call：

```json
{"name":"inbox.update","input":{"id":"记录 UUID","text":"Updated","expected_version":1},"idempotency_key":"请求 UUID"}
```

成功回复 `{"data":…}`，失败回复 `{"error":{…},"status":409}`，由 Phoenix reply 的 ok / error 状态区分。写入必须携带 idempotency_key，其范围、保留时间和事务规则与 HTTP 相同。每次调用重新验证会话与业务权限；会话到期关闭 channel。业务执行与订阅共用连接，operations channel 内串行处理调用。身份验证、契约和服务端会话管理仍使用 HTTP。

## 收敛与资源

Observer 先订阅内部失效通知，再执行初始加载；串行维护规范化 View，查询期间的失效消息排队并触发后续刷新。仅服务端契约显式 `"shared": true` 才共享；key 是完整 Actor（project_id / subject_id / session_id / expires_at）加完整准备后的订阅描述（含规范化参数），节点本地。同 session 多设备可共享，不同 session 即使同用户也不共享；shared 不是 join 参数，也不会合并不同逻辑订阅的 ACK。每次计算前验证会话并执行业务授权，计算后再次验证会话；每次 attach 独立检查，即使复用已编码快照也无授权 TTL 缓存。

写入与 Oban 任务同事务提交；最外层事务成功后立即广播失效通知，Oban 任务保留为持久化重试路径。嵌套在调用方事务中的写入只通过提交后可见的 Oban 任务通知。Observer 去重最近 64 个通知 ID，不按 ID 大小过滤乱序；多个待处理刷新合并后回退全量加载。每个 Observer 只有一个协调定时器，默认每 30 秒重新授权并全量查询以修复遗漏通知。自动刷新可见数据未变化时不推送、序号保持不变；显式 refresh 在请求端可接收时仍返回完整快照。

规范化 View 及其 context 是服务端内部结构，不增加协议字段。收件箱的私有候选区最多 8 条，不发送给客户端；版本缺口或候选不足等不确定情况会重新加载，详情见服务端文档。服务端的记录版本检查与客户端的 delta seq 检查是不同层次的保护。

默认每连接 20 个订阅、每页 100 条、每快照 data 256 KiB、入站 Socket 帧 64 KiB、Observer 邮箱阈值 200 条。出站批处理预算默认 256 KiB，不含单条消息的硬上限保证。ACK 限制各客户端业务推送积压；网关仍应限制连接数、请求速率和传输带宽。

## SDK 恢复语义

断线后进入 recovering，保留上一份数据并明确标记未就绪。SDK 重新取得令牌、验证身份、重建连接与订阅；初始快照到达后才进入 ready。确认 UNAUTHENTICATED / FORBIDDEN 或关闭客户端时清空数据。账号变化应关闭旧 client 并创建新 client；SDK 拒绝在已有身份绑定的 client 中切换 Subject。

TypeScript SDK 安装自定义 decoder，在分派前验证整个单帧或 batch 的结构、帧数和成员，再按顺序交给 Phoenix。非法传输帧产生不可重试的 PROTOCOL_ERROR，不把非法批次前半部分当作有效更新；一次 batch 不合并多个 onChange，也不提供跨订阅原子回调。

运行中的 Observer 退出会向 channel 报告 retryable INTERNAL_ERROR；会话检查 worker 故障或超时同样以 retryable 内部错误失败，不放行未验证会话。SDK 收到 retryable status 时保留旧数据、进入 recovering，重建连接和订阅，以新 generation 的完整快照恢复。默认重试延迟从 250 ms 指数增长，最大 30 秒，可由 retryDelayMs 覆盖。attach 调用退出时服务端内部重试一次。SDK 对首次加入返回的 retryable 错误同样恢复：该订阅进入 recovering 并由通道自行重新加入（连续失败超过 10 次才报告 error）；UNAUTHENTICATED 重建连接，不可重试的 join 错误立即失败。

HTTP 401 或 Socket 调用返回认证失效时，最多调用一次 `getToken({forceRefresh:true})` 并重试，保持原幂等键。SDK 不自动重试业务冲突或不确定网络失败；调用者若重试写入应显式复用幂等键。移动端暂停时可关闭连接，恢复后创建 client 并重新查询。

## 能力协商

可选能力默认关闭。客户端不声明就得不到：**没有协商的能力，其事件永远不会发给这个连接**，依赖它的调用返回 `UNSUPPORTED_CAPABILITY`。

- **契约**：`GET /api/v1/contract`（或 `mix fyrlet.contract`）导出这台服务端能提供的全部条目，并在 `capabilities` 里列出已启用的能力。依赖能力的条目（`run` / `ingest` 操作、`append` 订阅、`presence` 房间）只在对应能力已启用时出现；客户端要使用它们，仍须协商。TypeScript 类型生成器只接受 `protocol_version: 1` 的契约。
- **Socket**：加入订阅和 `operations` 通道时发送 `protocol_version: 1`，可带 `capabilities`（`{名称: 版本}` 或名称数组）。启用的能力是与服务端的交集，版本取较小者；回复与快照里的 `capabilities` 就是协商结果（没有声明则为空对象）。
- **HTTP**：用请求头 `X-Fyrlet-Capabilities: runs, ingest=1`。需要能力而未协商的调用得到 `UNSUPPORTED_CAPABILITY`（HTTP 400）。
- **契约演进**：增加可忽略的元数据与扩充 `kind` 枚举是不同变更。字段变化按所需读取方能力分类。
- **服务端定义**：只实现基础回调的定义可以注册；其余回调按操作种类与已启用的能力校验，不要求所有定义实现 `run/3`、`step/3` 或共享查询。

## Run（能力 `runs`）

- 契约操作的 `kind` 可以是 `run`：创建一次持久运行，必须带 `Idempotency-Key`，立即返回 `{run_id, status, existing}`；成功只表示已受理。业务键相同返回已有运行（`existing: true`）。
- `GET /api/v1/runs/:id` 读取运行视图；`POST /api/v1/runs/:id/signals` `{wait_id, name, payload, idempotency_key}` 投递信号，回执 `accepted`（已存，尚未消费）或 `consumed`；`POST /api/v1/runs/:id/cancel` 受理取消，返回 `status`、`cancel_deadline`、`cancellation_outcome`（`confirmed` / `fenced_timeout`）。以上均需 `X-Fyrlet-Capabilities: runs`。
- 订阅 `fyrlet.run`（参数 `run_id`）与 `fyrlet.runs.recent`（参数 `limit`，只含调用者自己的运行）为完整有界快照，需协商 `runs`。事件窗口最近 50 条，超出以 `events_truncated` 标记。
- 状态：`pending`、`running`、`waiting`、`completed`、`failed`、`cancelling`、`cancelled`、`expired`。步骤状态含 `awaiting_effect`；等待节点状态为 `waiting`、`satisfied`、`timed_out`、`cancelled`。

## 追加订阅（能力 `append`）

契约订阅声明 `mode: "append"`、`max_items`（1–500）和 `capability: "append"`。用独立通道 `append:<订阅 UUID>` 加入（`subscription:<id>` 加入追加订阅返回 `VALIDATION_FAILED`），必须在 `capabilities` 中协商 `append`，否则返回 `UNSUPPORTED_CAPABILITY`。加入参数 `{protocol_version: 1, capabilities, name, params}`，不使用 `delivery`。

- 加入回复与 `snapshot`：`{protocol_version: 1, subscription_id, generation, seq, cursor, mode: "append", max_items, project_id, subject_id, capabilities, data}`。`data` 是最新至多 `max_items` 条。加入之后收到的 `snapshot`，若 `generation` 相同且 `seq` 更高，则整体替换视图与游标（游标失效、窗口超限或客户端 `refresh` 时发送）。
- `append`：`{g, s, base_cursor, cursor, items}`。**仅当 `base_cursor` 等于客户端持有的游标且 `s` 恰为当前 seq + 1 时应用**，随后游标为 `cursor`，并丢弃超出 `max_items` 的最旧项；`s` 不大于当前 seq 的重复包不重复应用；不连续则停止合并并发送 `refresh`。游标是不透明字符串，客户端只比较是否相等。
- 客户端 `ack`：`{g, s, c}`，累计确认（`s` 及之前都已应用，`c` 是 `s` 对应的游标）；三者须与服务端记录一致，否则被忽略。快照未确认前不发送 `append`。
- 未确认窗口至多 200 个批次或 256 KiB（`config :fyrlet, :streams`），超出发新快照而不是积压；超过 `snapshot_ack_timeout` 无有效确认则以 `LIMIT_EXCEEDED` 关闭订阅。
- 客户端 `refresh` 请求新快照（已有快照待确认时不重复发送）。
- 所有成员看到相同的条目；服务端在每次发送前复核会话与 `authorize`。数据只是窗口，不是完整历史。

## 在线状态（能力 `presence`）

“谁在这个房间里”以及“正在输入”这类短暂状态，不写入 PostgreSQL。契约新增可选的 `presence` 段，与 `operations`、`subscriptions` 并列，在 `presence` 能力启用时才出现：

```json
"presence": {
  "room.presence": {
    "input": { "type": "object", "properties": { "room": { "type": "string" } }, "required": ["room"], "additionalProperties": false },
    "meta":  { "type": "object", "properties": { "typing": { "type": "boolean", "default": false } }, "additionalProperties": false }
  }
}
```

`input` 是房间参数的 schema；`meta` 是成员可以设置的状态的 schema，省略时成员不能带任何状态。**谁能进入、哪个房间由定义的 `authorize/3` 和 `scope/3` 决定**，同一个 scope 就是同一个房间；服务端再把项目 ID 并入房间，所以不同项目永远不会共享房间。

用通道 `presence:<UUID>` 加入，必须协商 `presence`，否则返回 `UNSUPPORTED_CAPABILITY`。加入参数 `{protocol_version: 1, capabilities, name, params, meta?}`；匿名主体返回 `FORBIDDEN`。

- 加入回复：`{protocol_version: 1, name, capabilities, self, state}`。`self` 是自己的 `subject_id`；`state` 是 `{subject_id: [{ref, data, joined_at}]}`。成员**按 `subject_id` 聚合**，同一个人在两台设备上是一个键、两条 meta。身份由服务端决定，客户端提交的 `subject_id` 之类字段会被 schema 拒绝。
- `diff`：`{joins, leaves}`，两者形状与 `state` 相同。按 `ref` 应用：`leaves` 删除对应 ref 的条目（键下没有条目时删除键），`joins` 增加该 ref 不存在的条目。因此重复收到同一个 `diff`（包括自己加入时的回声）是无害的。
- 客户端 `update`：`{meta}`，替换自己这条 meta，成功回复 `ok`，其他成员收到一个 `leaves`（旧 ref）加 `joins`（新 ref）。每个通道每秒至多 `presence_updates_per_second`（默认 10）次，超出返回可重试的 `LIMIT_EXCEEDED`；校验失败返回 `VALIDATION_FAILED`。
- 限制：单条 meta 的 JSON 至多 `presence_max_meta_bytes`（默认 1024）字节；每个房间至多 `presence_max_members`（默认 500）个键，已在房间里的成员重复加入不受此限（检查与加入之间不是原子的，并发加入可能略微超出）。在线通道占用订阅配额（连接上限和项目上限）。
- **复核**：和订阅一样，每个 `reconciliation_interval` 重新校验会话并调用 `authorize/3`，失败或会话到期则推送 `status {state: "closed", error}` 并关闭。
- 离线：通道进程结束（断开、关闭、崩溃）后成员自动消失，没有超时宽限期。跨节点通过 `Phoenix.Presence`（CRDT）同步，需要 `FYRLET_CLUSTER_NODES` 把节点连起来。
- 隐私：房间里的所有成员能看到彼此的 `subject_id` 和 `meta`。应用通过自己的订阅把 ID 映射成名字；如果 `subject_id` 本身不应暴露，请不要使用 presence。

## 副作用回执

`POST /api/v1/effects/:id/receipts` `{receipt_id, outcome: "succeeded" | "failed", result}`，用**项目服务密钥**（`rtk_`）认证，且副作用必须属于该项目。同一 `receipt_id` 重复提交返回 `duplicate`；与已记录结果矛盾的回执被记录但不应用，返回 `CONFLICT`。

## 外部执行器（服务端能力 `executors`）

`POST /api/v1/executor/claim`、`POST …/attempts/:id/heartbeat`、`GET …/attempts/:id?wait=`、`POST …/attempts/:id/result`，用执行器凭据（`rtx_`）。详见 [RUNS.md](RUNS.md#外部执行器协议)。

## Webhook（插件 `FyrletWebhooks`，能力 `webhooks`）

`POST /api/v1/plugins/webhooks/:source`（插件 `FyrletWebhooks`），头 `x-fyrlet-signature: t=<unix 秒>,v1=<hex>`，其中 `v1 = HMAC-SHA256(密钥, "<t>.<原始请求体>")`。时间容差默认 300 秒；同一 `event_id` 只被接受一次。来源须在 `config :fyrlet_webhooks, sources:` 中显式配置，密钥至少 16 字节；未配置、密钥为空、签名或时间不符一律拒绝（不退回无认证路径）。

## 批量摄取（能力 `ingest`）

契约操作 `kind: "ingest"`，经 `POST /api/v1/operations/:name`，输入 `{items: [{key, data}], atomic?}`，单批至多 100 条。受理是持久的，处理异步；逐项结果为 `accepted`、`invalid`、`conflict`、`duplicate:<状态>`。`atomic: true` 时有任何无效项则整批拒绝。待处理量超限返回可重试的 `LIMIT_EXCEEDED`，该请求不存任何东西。`GET /api/v1/ingest/batches/:id` 读取批次状态。

## 匿名只读入口（能力 `anonymous_read`）

项目须在配置中显式开启。`POST /api/v1/anonymous/sessions` `{project_id}` 无需凭证，返回短期会话。匿名调用者只能使用契约标记 `"public": true` 的读取操作与订阅，且必须协商 `anonymous_read` 才能加入；写入、运行、信号、取消和契约端点一律 `FORBIDDEN`。有独立的会话签发速率与活动数上限，订阅数上限默认 3。

## 插件入口

`/api/v1/plugins/<name>/…` 由插件处理；未加载、已关闭或失败的插件返回 404。

## 运维状态（插件 `FyrletOps`，能力 `ops`）

`GET /api/v1/plugins/ops/status`，用**项目服务密钥**（`rtk_`）认证，返回该项目自己的 `{status, alerts}`：Run 与 Effect 按状态计数、停滞数、最老排队年龄、超期等待、未解决副作用、并发/排队用量。用户令牌被拒绝（401）；能力未启用返回 404。告警只含名称、严重度、数值与阈值，不含 Run 或 Effect ID。
