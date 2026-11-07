# Fyrlet Rust SDK

[English](README.md) | 简体中文

阻塞式、基于线程的客户端，提供类型化业务调用和可恢复的实时订阅。遵循[协议](../../docs/PROTOCOL.md)，语义与 [TypeScript SDK](../typescript/README.zh-CN.md) 一致。crate `fyrlet` 需要 Rust 1.75+，依赖 `serde_json`、`ureq`（HTTP）、`tungstenite`（WebSocket，rustls TLS）、`url`、`base64` 和 `uuid`。尚未发布，请使用 path 依赖或 workspace。

## 在后端交换会话

```rust
let sessions = SessionService::new(&endpoint, &service_key)?;
let session = sessions.issue_session(
    IssueSessionInput::new(user.id()).with_issuer("my-product").with_ttl_seconds(600),
)?;
// 只把 session.token 返回给该用户；service key 只留在后端。
sessions.revoke_session(&session.session_id)?;
```

`user.id()` 必须来自应用已验证的登录状态。

## 调用与重试

```rust
let client = Client::new(Options::new(endpoint, project_id, move |force_refresh| {
    backend.fetch_fyrlet_token(force_refresh)   // 返回 "rts_..."
}))?;

let item: Item = client.call_into_with(
    "inbox.add",
    json!({"text": "Hello"}),
    CallOptions::idempotency_key(stable_id),
)?;
let raw: Value = client.call("inbox.history", Value::Null)?;
```

- 首次认证会读取 `/api/v1/identity` 并绑定 Subject；同一客户端切换账号会以 `FORBIDDEN` 失败，请关闭后新建客户端。
- SDK 为每次调用生成幂等键，登录过期时最多刷新一次 token 并复用该键。`CONFLICT` 不会自动重试。宿主登录已失效时，让 token 回调返回错误码 `UNAUTHENTICATED` 以终止恢复。
- 失败为 [`Error`](src/errors.rs)，可用 `code()`、`api_error()`、`is_retryable()` 判断。请求在 `Options.timeout`（默认 10 秒）后超时。
- 写请求已发出但结果丢失时，mutation 的错误为 `Error::OutcomeUnknown(OutcomeUnknownError)`（带 `operation`、`idempotency_key` 和底层 `cause`）。不要盲目重发，先向服务端查询。

```rust
let mutation = client.mutate("inbox.add", input);   // 自身不会失败
mutation.state().status;                            // Completed Committed Accepted Failed Unknown
if mutation.state().status == MutationStatus::Unknown {
    mutation.recover()?;                            // 查询已存储的回执，绝不再次执行
}
let found = client.recover("inbox.add", input, &key)?;
```

`recover` 返回带原始结果的 `Committed`/`Accepted`，或在看不到回执时返回 `Unknown`。详见[操作结果与恢复](../../docs/MUTATIONS.md)。

## 订阅

```rust
let recent = client.subscribe("inbox.recent", json!({"limit": 20}))?;
let _guard = recent.on_change(|state| {
    let items: Vec<Item> = state.decode().unwrap_or_default();
    render(state.status, items, state.error);
});
recent.refresh()?;          // 服务端接受后返回；数据通过 on_change 到达
recent.unsubscribe();
```

`on_change` 会立即交付当前状态，随后交付每次变化，由专用分发线程串行回调，因此监听器可以安全地回调客户端。状态为 `Connecting`、`Ready`、`Recovering`（保留旧数据）、`Error` 和 `Closed`（清空数据）。`generation` 与 `seq` 用于拒绝过期消息。丢弃返回的 guard 即移除监听器。

SDK 默认请求 `delta-v1`（`Options.disable_delta` 则只要完整快照），确认每个快照和增量，并在断线、序号缺口或服务端返回可重试状态后，以 250 ms 到 30 s 的指数退避重建连接（可用 `Options.retry_delay` 覆盖）。未确认的写入不会重放。终止性的认证和权限错误会清空数据并使订阅进入 `Error`。监听器 panic 会被捕获并通过 `Options.on_listener_error` 报告。`SubscriptionState.data` 只读：增量会创建新容器，不修改已交付的值。

## 范围

已实现：会话服务、基于 HTTP 的业务调用、身份绑定、token 刷新、幂等、结果未知后的恢复、契约导出，以及带快照/增量/ACK/refresh/恢复的订阅。尚未实现（TypeScript SDK 已有）：Run、append 订阅、presence、乐观写入、业务调用的 Socket RPC 和契约类型生成。

## 测试

```bash
cargo test                          # 离线单元测试；集成测试会自动跳过
cargo build --examples
scripts/integration_sdks.sh rust    # 启动 inbox 示例服务并运行全部测试
```

示例读取 `FYRLET_ENDPOINT`、`FYRLET_PROJECT_ID` 和 `FYRLET_SERVICE_KEY`：

```bash
FYRLET_ENDPOINT=http://127.0.0.1:4000 FYRLET_PROJECT_ID=... FYRLET_SERVICE_KEY=rtk_... \
  cargo run --example inbox -- "First note"
```
