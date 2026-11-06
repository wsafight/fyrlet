# Fyrlet TypeScript SDK

SDK 核心提供业务调用与实时订阅，不依赖 React、浏览器存储或 Cookie 登录。当前包为本地 private 包，构建产物在 dist。

本 SDK 位于 `sdks/typescript/`，供 JavaScript / TypeScript 应用使用；多语言布局和新增 SDK 的要求见 [SDK 总览](../README.md)。React 适配包后续基于本 SDK 实现，React Native 的运行时适配也属于 TypeScript 生态。

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

SDK 为每次 call 自动生成幂等键，认证失效最多刷新一次并复用该键。网络中断后的业务重试由调用者决定，需要显式复用同一键。CONFLICT 不自动重试。宿主登录失效时，getToken 应抛出 code 为 UNAUTHENTICATED 的 ApiError，结束自动恢复并清空订阅数据。

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

ApiError 包含 code、message、details、retryable、status、requestId。HTTP 与调用等待默认 10 秒超时，可用 timeoutMs 调整；AbortSignal 和 close 可以取消客户端等待。取消或超时不表示服务端一定未提交，重试写入仍应复用幂等键。

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

服务端只有在订阅契约显式设置 `"shared": true` 时才共享 Observer（当前 inbox.recent 已启用），不是 SDK 或 join 选项。共享 key 是完整 Actor（含 project / subject / session / expires_at）与完整规范化订阅描述，且仅在本节点有效：同 session 多设备可共享，不同 session 即使同用户也不共享。共享不会跳过计算前的会话检查与业务授权、计算后的会话检查或每次 attach 的独立检查，不使用授权 TTL 缓存；也不共享各客户端的 generation、seq 和 ACK。慢端不阻塞其他设备，落后后经重新授权的全量加载和完整快照追平，不补放历史 delta。

运行中 Observer 退出、会话检查 worker 故障或超时产生 retryable 的内部错误 status 时，SDK 自动进入 recovering，保留旧数据，刷新令牌并重新验证身份、重建连接与订阅；收到新 generation 的完整快照后才 ready。默认重试从 250 ms 指数增长至最多 30 秒，可用 retryDelayMs 覆盖。这是订阅恢复，不自动重放未确认的业务写入；认证或业务权限终止错误仍清空数据。attach 调用退出时服务端会内部重试一次，但当前 SDK 的 join error 分支仅对 UNAUTHENTICATED 自动恢复，其他 join 失败需显式 reconnect，不保证所有 retryable join 错误均自动重试。

ACK 为单向、无 ref 的通知，不等待服务端回执，也不创建回复定时器。服务端与 SDK 统一使用紧凑增量格式，详见 docs/PROTOCOL.md；没有旧协议兼容分支。纯字段修改复用不可变视图的 ID 索引，只复制结果数组与被修改记录；增删或重排仍验证完整成员关系，索引通过 WeakMap 随视图回收。

unsubscribe 结束一个订阅；默认 HTTP 模式下最后一个订阅结束时释放连接。Socket 调用模式保留连接供后续调用，使用 close 释放。close 释放所有订阅、定时器和请求，并禁止再次使用这个 client。账号切换时先 close，再创建新的 client。

## Socket decoder 与批处理

SDK 为 Phoenix 安装自定义 decoder，接受标准单帧 `[join_ref, ref, topic, event, payload]` 或唯一外层字段为 batch 的 `{"batch":[...]}`。两个 ref 为字符串或 null，topic / event 为字符串，payload 为非 null 对象且不是数组；batch 必须有 1–64 帧。先校验整个批次再按顺序分派，空批、超限、非法成员或非法 JSON 产生不可重试的 PROTOCOL_ERROR，清空订阅数据，不部分应用非法批次。

服务端只聚合同轮 transport mailbox 已有推送，不定时等待凑批；单帧保持标准数组。多帧可以来自不同 topic，最多 64 帧，默认聚合预算 256 KiB，单条超预算消息独立发送。该包装不表示跨订阅事务，也不合并 onChange 通知。使用此 SDK 无需业务代码解包；自行使用原生 Phoenix 客户端时必须提供兼容 decoder。SDK 的 join、call、ACK 仍按标准单帧发送。

## 运行时适配

ClientOptions 支持注入 fetch、WebSocket、createId、retryDelayMs 与 onListenerError。默认 createId 使用 crypto.randomUUID；缺少该 API 的运行时必须提供安全随机 UUID 生成函数。

Node 已通过真实集成测试。浏览器与 React Native 不需要导入 server 入口；React Native 还需宿主处理前后台切换、网络恢复和安全令牌存储，真机行为尚未验收。没有移动端推送或离线写入。

## 契约与验证

```sh
mix fyrlet.contract priv/contract.json
npm --prefix sdks/typescript run generate
npm --prefix sdks/typescript run build
npm --prefix sdks/typescript test
npm --prefix sdks/typescript run typecheck
bash scripts/integration.sh
```

命令从仓库根目录执行。生成器支持当前受限契约，拒绝不支持的 schema；输入默认字段生成可选属性，输出按 required 字段生成。生成类型提供编译期约束，服务端仍对所有输入输出进行运行时校验。
