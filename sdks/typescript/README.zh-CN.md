# Fyrlet TypeScript SDK

[English](README.md) | 简体中文

SDK 核心提供业务调用与实时订阅，不依赖 React、浏览器存储或 Cookie 登录。`@fyrlet/client` 属于首发正式范围，构建产物在 dist，支持 `npm pack` 后本地安装，目前尚未发布到 npm。

本 SDK 位于 `sdks/typescript/`，供 JavaScript / TypeScript 应用使用；多语言布局和新增 SDK 的要求见 [SDK 总览](../README.zh-CN.md)。[独立 React 包](../react/README.zh-CN.md)和[带 OIDC 的 Inbox 页面](../../examples/inbox-react/README.zh-CN.md)已可使用；React Native 的运行时适配也属于 TypeScript 生态。

从服务端到浏览器的完整流程见[接入教程](../../docs/zh/TUTORIAL.md)。

## 入口

- `@fyrlet/client`：createClient、ApiError 与公开类型。
- `@fyrlet/client/server`：受信后端的 createSessionService。
- `@fyrlet/client/example-contract`：从收件箱服务端契约生成的类型。

## 后端交换会话

```ts
import { createSessionService } from "@fyrlet/client/server";

const sessions = createSessionService({
  endpoint: process.env.FYRLET_ENDPOINT!,
  serviceKey: process.env.FYRLET_SERVICE_KEY!,
});

const session = await sessions.issueSession({
  external_subject: authenticatedUser.id,
  issuer: "my-product",
  ttl_seconds: 600,
});
```

authenticatedUser 必须来自客户应用已验证的登录态。把 session.token 返回给对应用户；不要把服务密钥返回客户端。`revokeSession(session_id)` 可以撤销本项目单个会话。

## 调用与重试

`createClient<Contract>({endpoint,projectId,getToken})` 使用宿主应用提供的短期用户令牌。首次认证读取 identity 并绑定 Subject，拒绝在同一个 client 中切换账号。getToken 收到 forceRefresh=true 时应重新验证宿主登录态并获取会话。

```ts
const item = await client.call("inbox.add", { text: "Hello" }, {
  idempotencyKey: stableRequestId,
  signal: controller.signal,
});
await client.call("inbox.update", {
  id: item.id,
  text: "Updated",
  expected_version: item.version,
});
```

SDK 为每次 call 自动生成幂等键，认证失效最多刷新一次并复用该键。网络重试默认关闭；手动重复调用时需要显式复用原键。CONFLICT 不自动重试。宿主登录失效时，getToken 应抛出 code 为 UNAUTHENTICATED 的 ApiError，结束自动恢复并清空订阅数据。

默认通过 HTTP 调用业务。需要复用实时连接时可选择 Socket RPC：

```ts
const client = createClient<Contract>({
  endpoint,
  projectId,
  getToken,
  operationTransport: "socket",
});
```

Socket 模式的调用共用一个 operations channel，与订阅共用连接；没有订阅也可调用。服务端事务、权限、幂等与错误码相同，身份验证仍使用 HTTP。断线会拒绝正在等待的调用；连接恢复不会自动重放写入。并发调用在服务端同一 operations channel 中串行处理。

ApiError 包含 code、message、details、retryable、status、requestId。HTTP 与调用等待默认 10 秒超时，可用 timeoutMs 调整；AbortSignal 和 close 可以取消客户端等待。开始发送后的不确定错误会抛出 `OutcomeUnknownError`，保留操作名、幂等键与原始原因。先恢复回执，再决定是否重新发起业务调用。

`client.mutate(name, input, options?)` 返回包含 `idempotencyKey`、`result`、`getState()`、`onChange()` 与 `recover()` 的句柄，区分 `pending`、读完成 `completed`、写提交 `committed`、Run / ingest 受理 `accepted`、确定失败 `failed` 与 `unknown`。`call` 仍直接返回业务结果。`mutation.recover()` 或 `client.recover(name, originalInput, { idempotencyKey })` 只查询 write/run 回执，不执行业务；回执缺失或过期时保持未知。示例、持久化与确认边界见[操作结果与恢复](../../docs/zh/MUTATIONS.md)。

## 可选的有限重试

将生成的 `operationMetadata` 传入 `createClient`，再按调用或 mutation 启用 `retry`：

```ts
import { operationMetadata } from "@fyrlet/client/example-contract";

const client = createClient<AppContract>({ endpoint, projectId, getToken, operationMetadata });
const mutation = client.mutate("inbox.add", { text: "Hello" }, {
  retry: { maxAttempts: 3, maxElapsedMs: 15_000, baseDelayMs: 250, maxDelayMs: 5_000 },
});
await mutation.result;
```

仅显式声明 read/write/run 元数据的调用可启用；signal、cancel、ingest 不自动重试。默认值如上；尝试次数限 1–10，总时长限 1–60,000 毫秒。指数退避采用全抖动，数字或 HTTP 日期形式的 `Retry-After` 和 `details.retry_after_ms` 作为最小等待时间；服务端 CORS 暴露 `Retry-After`。认证刷新复用冻结输入和原键；次数统计外层尝试，每次内部最多刷新一次认证。

短暂读失败与确定拒绝后的调用可以重新尝试。写入或 Run 发送后结果未知时，后续仅查询原回执；缺失、过期或已清理仍为未知，不重放业务。因此，服务端未收到的写入也可能保持未知，由应用决定如何对账。权限、校验、冲突和协议错误不触发后续尝试；取消、总时限、认证失效和 client 关闭会停止等待与后续尝试。恢复失败保留原未知结果。`mutation.getState()` 的 `pending.retry` 暴露次数、阶段（`call` / `recover`）及可选的下次尝试时间。成功后的视图确认单独执行，不提供持久重试队列。

## 订阅状态

```ts
const recent = client.subscribe("inbox.recent", { limit: 20 });
const stop = recent.onChange(({ status, data, error }) => {
  renderInbox({ status, data, error });
});
await recent.refresh();
stop();
recent.unsubscribe();
client.close();
```

onChange 立即发出当前状态，之后在状态更新时通知。connecting 是初次建立；ready 表示收到当前订阅快照；recovering 保留旧数据并标记正在恢复；error 和 closed 清空数据。generation 与 seq 用于排除旧订阅或旧消息。

refresh 返回 Promise<void>，只表示服务端接受刷新请求；观察之后的状态更新取得数据。SDK 自动确认快照、重建断线订阅，并在重连初始快照后进入 ready。业务和权限错误终止对应订阅；reconnect 可以显式重新尝试所有仍保留的订阅。

SDK 默认请求 delta-v1；服务端确认后，SDK 在本地应用字段增量，onChange 继续提供完整业务视图。初始、显式刷新与重新加入均接收完整快照；序号缺口触发重新连接以恢复。订阅数据递归冻结，之前交给消费者的视图不会被后续增量修改；需要本地编辑时先创建副本。设置 `delta: false` 可使用完整快照模式。

服务端 Observer 共享由服务端契约决定。`"shared": true`（例如 inbox.recent）以完整 Actor 和规范化订阅描述为 key，仅在本节点、同 session 的设备间共享；不同 session 仍隔离。跨用户的公共结果需服务端声明 `"sharing": "identical"` 并实现成员检查和公共查询投影，例如 Chat 的房间状态。共享不跳过会话、业务授权或成员检查，不缓存授权结论；各客户端的 generation、seq 和 ACK 独立。慢端不阻塞其他设备，落后后经重新授权的完整快照追平，不补放历史 delta。

运行中 Observer 退出、会话检查 worker 故障或超时产生 retryable 的内部错误 status 时，SDK 自动进入 recovering，保留旧数据，刷新令牌并重新验证身份、重建连接与订阅；收到新 generation 的完整快照后才 ready。默认重试从 250 ms 指数增长至最多 30 秒，可用 retryDelayMs 覆盖。这是订阅恢复，不自动重放未确认的业务写入；认证或业务权限终止错误仍清空数据。attach 调用退出时服务端会内部重试一次。首次加入返回 retryable 错误（例如 Observer 短暂不可用）时，该订阅进入 recovering，由 Phoenix 按 `retryDelayMs`（未设置时用 Phoenix 默认退避）自动重新加入，不影响连接上的其他订阅；连续失败超过 10 次才报告为 error。UNAUTHENTICATED 仍按认证失败重建整个连接，不可重试的 join 错误立即失败。

ACK 为单向、无 ref 的通知，不等待服务端回执，也不创建回复定时器。服务端与 SDK 统一使用紧凑增量格式，详见[协议](../../docs/zh/PROTOCOL.md)；没有旧协议兼容分支。纯字段修改复用不可变视图的 ID 索引，只复制结果数组与被修改记录；增删或重排仍验证完整成员关系，索引通过 WeakMap 随视图回收。

unsubscribe 结束一个订阅；默认 HTTP 模式下最后一个订阅结束时释放连接。Socket 调用模式保留连接供后续调用，使用 close 释放。close 释放所有订阅、定时器和请求，并禁止再次使用这个 client。账号切换时先 close，再创建新的 client。

## Run 与追加订阅（可选能力）

只有声明了能力，下面的 API 才可用；**不声明就调用**会得到 `UNSUPPORTED_CAPABILITY`（Promise 拒绝；订阅类同步抛出）。

```ts
const flowClient = createClient({
  endpoint: flowEndpoint, projectId: flowProjectId, getToken: getFlowToken, capabilities: ["runs"],
});

const { run_id } = await flowClient.startRun("flow.start", {
  flow_id: "demo",
  nodes: [{ type: "wait", name: "approval", signal: "approve", timeout_seconds: 600 }],
});
const view = flowClient.subscribeRun(run_id);
view.onChange((state) => render(state.data));

await flowClient.signalRun(run_id, { wait_id, name: "napprove", payload: {} });
const cancel = await flowClient.cancelRun(run_id);
await flowClient.getRun(run_id);

const chatClient = createClient({
  endpoint: chatEndpoint, projectId: chatProjectId, getToken: getChatToken, capabilities: ["append"],
});
const feed = chatClient.subscribeAppend("chat.messages", { room_id });
feed.getState().cursor;
```

Run 示例连接 Flow 宿主，append 示例连接 Chat 宿主，各自使用对应的 endpoint、项目与令牌提供器。`wait_id` 从等待中的 Run 读取，`room_id` 使用已经加入的会话；Flow 会把信号 `approve` 规范化为 `napprove`。

要点：

- Run 被受理不代表已完成，通过 `fyrlet.run` 的完整有界快照观察状态、步骤、副作用和截断事件；`startRun` 自动带幂等键，信号被受理也不等于已消费。
- `cancelRun` 的 `fenced_timeout` 只表示该运行之后不能再推进，**不代表外部工作已停止**；在途副作用的真实状态仍在 `effects` 中。
- 追加订阅的数据是最新 `max_items` 条的窗口，并非完整历史；只在批次的 `base_cursor` 恰好接上本地游标、序号连续时才合并，否则 `refresh` 取得快照。重复批次不会被应用两次，断线重连后从服务端快照重新开始。游标是不透明位置，只可比较是否相等。
- Run 与追加订阅的类型（`RunView`、`StartedRun` …）从包入口导出；内置订阅 `fyrlet.run` 不在生成的契约里。

## 乐观写入（`CallOptions.optimistic`）

调用写操作时给订阅叠加一个本地预测，界面立刻变化，不必等服务端确认：

```ts
const items = client.subscribe("inbox.recent", {});
await client.call("inbox.add", { text }, {
  optimistic: [{
    subscription: items,
    // 按 id 覆盖，而不是盲目追加：服务端自己的那份变更可能已经在 current 里了
    update: (current) => [...current.filter((item) => item.id !== draft.id), draft],
  }],
});
items.getState().data;     // 预测叠加在服务端数据上的结果
items.getState().pending;  // 当前叠加着多少个未被服务端数据取代的预测
```

- **确定失败立即回滚**：预测马上撤销，错误原样抛出。
- **成功后保留 snapshot / append 预测**，直到关联的重新查询快照确认视图，或超过 `optimisticTtlMs`（默认 5000 毫秒）。无关快照和增量不会提前移除预测；未知结果保留预测到 TTL 到期，到期不会解决操作结果或确认视图。
- 服务端数据在写入进行中到达时，预测会重新叠加在新数据上；因此 `update` **必须幂等**，且必须返回新值（收到的数据是冻结的，原地修改会抛错）。抛错的预测会被丢弃并交给 `onListenerError`，调用本身不受影响。
- 只对已经有数据的、由同一个客户端创建的、尚未取消的订阅生效；传入别的订阅会在发出请求前抛 `TypeError`，不会有任何副作用。没有数据的订阅被跳过。
- 内部状态始终是服务端的真值（增量补丁基于它应用），预测只在 `getState()` 和监听回调里派生出来。

**保证的边界，请按需评估：**

- 预测不会跨页面刷新保留，没有离线队列；断线调用根据是否已经开始发送，区分确定失败与结果未知。
- 追加订阅可以传入（数据是窗口，请自行确认 `update` 的语义）；Presence 预测只改变本地 roster，不发布 meta，仍按 roster 更新或 TTL 移除。

## 视图确认

`call` 和 `mutation.result` 返回业务结果；通过 `mutation.views` 单独等待订阅追平：

```ts
const mutation = client.mutate("inbox.add", { text }, { confirm: [items] });
const saved = await mutation.result;
const views = await mutation.views;
if (views.some((view) => view.status === "unconfirmed")) {
  await items.confirm();
}
```

乐观更新涉及的 snapshot / append 订阅在成功后自动确认，`CallOptions.confirm` 可指定额外订阅。每项结果包含 `subscription`、`status`（`confirmed` 或 `unconfirmed`）及可选 `error`。`subscription.confirm({ signal })` 可直接请求权威快照。确认必须匹配关联标识、当前身份与 generation，且 seq 更新；刷新受理回执、无关数据和 delta 均不能完成确认。结果未变或为空时，也会收到新的完整快照。

SDK 在 snapshot / append Channel 自动协商 `view_confirmation=1`，每份活跃订阅最多 32 个待确认请求。超时、取消、重连、退订、权限失败或能力不支持均使视图保持未确认，不改变已提交结果，也不重放业务。未知结果不会自动发起确认，回执恢复后可显式调用。TTL 仅作为显示兜底；过滤与窗口规则仍然生效，多订阅分别确认。一致性边界见 [MUTATIONS.md](../../docs/zh/MUTATIONS.md)。

## 客户端查询复用

创建 client 时设置 `shareSubscriptions: true`，复用相同的 snapshot / append 查询。`maxSharedSubscriptions` 限制活跃共享条目数，默认 100。共享键在当前 client 身份上下文内包含项目、名称、模式和规范化 JSON 参数；对象键顺序不影响相等，数组顺序保留。参数会复制冻结，编码大小最多 64 KiB；拒绝 undefined、非有限数、循环引用和自定义对象。

每次 subscribe 返回独立句柄与监听注册；释放一个句柄不影响其他句柄，最后一个释放后立即离开 Channel 并删除条目，不保留无引用缓存。Presence 单独管理。认证失败和身份变化会清空私有状态。此选项复用同一 client 的查询，服务端 Observer 共享仍遵守应用契约。[独立 React 包](../react/README.zh-CN.md)提供 Hook 和确定的空 SSR 状态。`selectSubscription(source, selector, isEqual?)` 提供纯投影并复用相等的选中值，`queryKey(params)` 暴露相同的规范化 JSON 参数键。

## 在线状态（能力 `presence`）

“谁在这个房间里”和“正在输入”这类短暂状态，不写数据库。声明 `capabilities: ["presence"]` 后：

```ts
const room = client.subscribePresence("room.presence", { room: "r1" }, { typing: false });
room.onChange((state) => {
  // state.data: { [subjectId]: [{ ref, data, joined_at }] } —— 同一个人两台设备就是两条
  console.log(Object.keys(state.data ?? {}));
});
await room.update({ typing: true });   // 替换自己这条 meta
room.self();                           // 自己的 subject_id（加入后可用）
room.unsubscribe();                    // 离开房间，别人会看到你消失
```

- 房间名、参数和 `meta` 从契约必需的 `presence` 段生成（见 [PROTOCOL.md](../../docs/zh/PROTOCOL.md)），没有房间时使用空对象。`subscribePresence`、`update` 和名册 meta 均推导对应类型，错误名称和输入会在类型检查时失败。每个操作必须声明 `kind`，并据此限制 `startRun` 名称；缺少任一声明的契约无法通过类型检查。运行时重试策略显式读取独立导出的 `operationMetadata` 常量。
- 名册按 `ref` 增量更新，重复收到同一个 diff 无害。重连后会以**最新一次 `update` 的 meta** 重新加入，并整体替换名册，不会留下过期成员。
- `update` 受服务端频率限制，过于频繁会以可重试的 `LIMIT_EXCEEDED` 拒绝；meta 不符合 schema 返回 `VALIDATION_FAILED`；房间未就绪时返回 `NOT_READY`。
- 匿名会话不能进入房间；房间里的所有成员能看到彼此的 `subject_id` 和 `meta`。

## Socket decoder 与批处理

SDK 为 Phoenix 安装自定义 decoder，接受标准单帧 `[join_ref, ref, topic, event, payload]` 或唯一外层字段为 batch 的 `{"batch":[...]}`。两个 ref 为字符串或 null，topic / event 为字符串，payload 为非 null 对象且不是数组；batch 必须有 1–64 帧。先校验整个批次再按顺序分派，空批、超限、非法成员或非法 JSON 产生不可重试的 PROTOCOL_ERROR，清空订阅数据，不部分应用非法批次。

服务端只聚合同轮 transport mailbox 已有推送，不定时等待凑批；单帧保持标准数组。多帧可以来自不同 topic，最多 64 帧，默认聚合预算 256 KiB，单条超预算消息独立发送。该包装不表示跨订阅事务，也不合并 onChange 通知。使用此 SDK 无需业务代码解包；自行使用原生 Phoenix 客户端时必须提供兼容 decoder。SDK 的 join、call、ACK 仍按标准单帧发送。

## 运行时适配

ClientOptions 支持注入 fetch、WebSocket、createId、retryDelayMs 与 onListenerError。默认 createId 使用 crypto.randomUUID；缺少该 API 的运行时必须提供安全随机 UUID 生成函数。

Node 已通过真实集成测试。浏览器与 React Native 不需要导入 server 入口；React Native 还需宿主处理前后台切换、网络恢复和安全令牌存储，真机行为尚未验收。没有移动端推送或离线写入。

## 契约与验证

```sh
(cd examples/inbox && mix fyrlet.contract ../../priv/contract.json)
npm --prefix sdks/typescript run generate
npm --prefix sdks/typescript run build
npm --prefix sdks/typescript test
npm --prefix sdks/typescript run test:coverage
npm --prefix sdks/typescript run typecheck
bash scripts/integration.sh
DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh
```

命令从仓库根目录执行。生成器支持当前受限契约，拒绝不支持的 schema；输入默认字段生成可选属性，输出按 required 字段生成。生成类型提供编译期约束，服务端仍对所有输入输出进行运行时校验。

单元测试覆盖操作结果、回执恢复、取消、认证竞争、通道隔离、畸形增量、关联式视图确认、共享查询生命周期、监听器异常、乐观更新顺序与后端会话服务。`test:coverage` 使用 Node 内置覆盖率工具。真实服务端测试覆盖 HTTP / Socket 结果、确认、查询复用、Run 幂等、隔离、重启、append 窗口与撤销；四个领域应用另有端到端场景。当前数量、命令与边界见[验收记录](../../docs/zh/ACCEPTANCE.md)。

执行 `bash scripts/package.sh` 生成 `.local/releases/fyrlet-client-0.1.0.tgz`，其他项目可用 `npm install /绝对路径/fyrlet-client-0.1.0.tgz` 安装。`bash scripts/install_smoke.sh` 会在仓库外创建 consumer，实际安装并导入主入口与 `@fyrlet/client/server`；分发和版本边界见 [INSTALL.md](../../docs/zh/INSTALL.md)。
