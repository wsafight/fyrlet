# Fyrlet Swift SDK

[English](README.md) | 简体中文

面向 Apple 平台（macOS 12+、iOS 15+、tvOS 15+、watchOS 8+）的 async/await 客户端，提供类型化业务调用和可恢复的实时订阅。遵循[协议](../../docs/PROTOCOL.md)，语义与 [TypeScript SDK](../typescript/README.zh-CN.md) 一致。仅使用 Foundation（`URLSession` 与 `URLSessionWebSocketTask`），没有第三方依赖。包尚未发布，用 `.package(path: "sdks/swift")` 引入。Linux 未测试。

## 在后端交换会话

```swift
let sessions = try SessionService(endpoint: endpoint, serviceKey: serviceKey)
let session = try await sessions.issueSession(externalSubject: user.id, issuer: "my-product", ttlSeconds: 600)
// 只把 session.token 返回给该用户；service key 只留在后端。
try await sessions.revokeSession(session.sessionId)
```

`user` 必须来自应用已验证的登录状态。不要把 service key 打进 App。

## 调用与重试

```swift
let client = try Client(Options(endpoint: endpoint, projectId: projectId) { forceRefresh in
    try await myBackend.fetchFyrletToken(forceRefresh: forceRefresh)   // 返回 "rts_..."
})

let item = try decode(Item.self, from: try await client.call("inbox.add", ["text": "Hello"], idempotencyKey: stableID))
```

- 首次认证会读取身份并绑定 Subject；同一客户端切换账号会以 `FORBIDDEN` 失败，请关闭后新建客户端。
- SDK 为每次调用生成幂等键，登录过期时最多刷新一次 token 并复用该键。`CONFLICT` 不会自动重试。宿主登录已失效时，让 `getToken` 抛出 `APIError(code: "UNAUTHENTICATED", ...)` 以终止恢复。
- 错误为 `APIError`（`code`、`message`、`details`、`retryable`、`status`、`requestId`）。请求默认 `Options.timeout`（10 秒）超时。
- 写请求已发出但结果丢失时，`call` 抛出 `OutcomeUnknownError`（`operation`、`idempotencyKey`、`cause`）。不要盲目重发，先向服务端查询。

```swift
let mutation = await client.mutate("inbox.add", ["text": "Hello"])  // 不会抛出；检查状态
mutation.state.status                                               // .completed .committed .accepted .failed .unknown
if mutation.state.status == .unknown { _ = try await mutation.recover() }  // 读取已存储的回执，绝不再次执行
let found = try await client.recover("inbox.add", ["text": "Hello"], idempotencyKey: key)
```

`recover` 返回带原始结果的 `.committed`/`.accepted`，或在看不到回执时返回 `.unknown`。详见[操作结果与恢复](../../docs/MUTATIONS.md)。

## 订阅

```swift
let recent = try client.subscribe("inbox.recent", params: ["limit": 20])
let stop = recent.onChange { state in
    render(state.status, try? state.decoded([Item].self), state.error)
}
try await recent.refresh()   // 服务端接受后返回；数据通过 onChange 到达
stop(); recent.unsubscribe(); client.close()
```

`onChange` 会立即交付当前状态，随后交付每次变化，由专用队列串行回调，因此监听器可以安全地回调客户端。状态为 `.connecting`、`.ready`、`.recovering`（保留旧数据）、`.error` 和 `.closed`（清空数据）。`generation` 与 `seq` 用于拒绝过期消息。

SDK 默认请求 `delta-v1`（`Options.delta = false` 则只要完整快照），确认每个快照和增量，并在断线、序号缺口或服务端返回可重试状态后，以 250 ms 到 30 s 的指数退避重建连接（可用 `Options.retryDelay` 覆盖）。未确认的写入不会重放。终止性的认证和权限错误会清空数据并使订阅进入 `.error`。`State.data` 是解码后的 JSON，只读：增量会创建新容器，不修改已交付的值。

iOS 在后台可能挂起 socket。观察 `.recovering` 状态并让 SDK 在回到前台时重连，或在场景状态变化时调用 `reconnect()`。

## 范围

已实现：会话服务、基于 HTTP 的业务调用、身份绑定、token 刷新、幂等、结果未知后的恢复、契约导出，以及带快照/增量/ACK/refresh/恢复的订阅。尚未实现（TypeScript SDK 已有）：Run、append 订阅、presence、乐观写入、业务调用的 Socket RPC 和契约类型生成。

## 测试

```bash
cd sdks/swift && swift test            # 单元测试；集成测试会自动跳过
scripts/integration_sdks.sh swift      # 启动 inbox 示例服务并运行全部测试
```
