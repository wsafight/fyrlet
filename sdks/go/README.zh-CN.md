# Fyrlet Go SDK

[English](README.md) | 简体中文

基于 `context` 的客户端，提供类型化业务调用和可恢复的实时订阅。遵循[协议](../../docs/PROTOCOL.md)，语义与 [TypeScript SDK](../typescript/README.zh-CN.md) 一致。模块 `github.com/wsafight/fyrlet/sdks/go`（包名 `fyrlet`），需要 Go 1.22+，仅依赖 `gorilla/websocket`。尚未打标签或发布，目前请使用 `replace` 指令或 `go work`。

## 在后端交换会话

```go
sessions, _ := fyrlet.NewSessionService(os.Getenv("FYRLET_ENDPOINT"), os.Getenv("FYRLET_SERVICE_KEY"), nil)
session, err := sessions.IssueSession(ctx, fyrlet.IssueSessionInput{ExternalSubject: user.ID, Issuer: "my-product", TTLSeconds: 600})
// 只把 session.Token 返回给该用户；service key 只留在后端。
_, err = sessions.RevokeSession(ctx, session.SessionID)
```

`user` 必须来自应用已验证的登录状态。

## 调用与重试

```go
client, err := fyrlet.NewClient(fyrlet.Options{
	Endpoint: endpoint, ProjectID: projectID,
	GetToken: func(ctx context.Context, forceRefresh bool) (string, error) { /* 返回 "rts_..." */ },
})
defer client.Close()

var item Item
err = client.CallInto(ctx, "inbox.add", map[string]any{"text": "Hello"}, &item, fyrlet.WithIdempotencyKey(stableID))
raw, err := client.Call(ctx, "inbox.history", nil) // json.RawMessage
```

- 首次认证会读取身份并绑定 Subject；同一客户端切换账号会以 `FORBIDDEN` 失败，请关闭后新建客户端。
- SDK 为每次调用生成幂等键，登录过期时最多刷新一次 token 并复用该键。`CONFLICT` 不会自动重试。宿主登录已失效时，让 `GetToken` 返回 `&fyrlet.APIError{Code: "UNAUTHENTICATED"}` 以终止恢复。
- 错误为 `*fyrlet.APIError`（`Code`、`Message`、`Details`、`Retryable`、`Status`、`RequestID`），用 `errors.As` 判断。请求在 `Options.Timeout`（10 秒）或 `ctx` 结束时终止。
- 写请求已发出但结果丢失时，错误为 `*fyrlet.OutcomeUnknownError`（带 `Operation`、`IdempotencyKey`、`Cause`）。不要盲目重发，先向服务端查询。

```go
m := client.Mutate(ctx, "inbox.add", input)  // 自身不会失败，检查返回的 Mutation
m.State().Status                             // completed | committed | accepted | failed | unknown
if m.State().Status == fyrlet.MutationUnknown {
	state, err := m.Recover(ctx)             // 查询已存储的回执，绝不再次执行
}
found, err := client.Recover(ctx, "inbox.add", input, key) // 用已保存的键查询
```

`Recover` 返回带原始结果的 `committed`/`accepted`，或在看不到回执时返回 `unknown`。详见[操作结果与恢复](../../docs/MUTATIONS.md)。

## 订阅

```go
recent, _ := client.Subscribe("inbox.recent", map[string]any{"limit": 20})
stop := recent.OnChange(func(s fyrlet.State) {
	var items []Item
	_ = s.Decode(&items)
	render(s.Status, items, s.Err)
})
err = recent.Refresh(ctx) // 服务端接受后返回；数据通过 OnChange 到达
stop(); recent.Unsubscribe()
```

`OnChange` 会立即交付当前状态，随后交付每次变化，由专用 goroutine 串行回调，因此监听器可以安全地回调客户端。状态为 `connecting`、`ready`、`recovering`（保留旧数据）、`error` 和 `closed`（清空数据）。`Generation` 与 `Seq` 用于拒绝过期消息。

SDK 默认请求 `delta-v1`（`Options.DisableDelta` 则只要完整快照），确认每个快照和增量，并在断线、序号缺口或服务端返回可重试状态后，以 250 ms 到 30 s 的指数退避重建连接（可用 `Options.RetryDelay` 覆盖）。未确认的写入不会重放。终止性的认证和权限错误会清空数据并使订阅进入 `error`。`State.Data` 是解码后的 JSON，只读：增量会创建新容器，不修改已交付的值。

## 范围

已实现：会话服务、基于 HTTP 的业务调用、身份绑定、token 刷新、幂等、结果未知后的恢复、契约导出，以及带快照/增量/ACK/refresh/恢复的订阅。尚未实现（TypeScript SDK 已有）：Run、append 订阅、presence、乐观写入、业务调用的 Socket RPC 和契约类型生成。

## 测试

```bash
go test ./sdks/go/...                  # 离线单元测试；集成测试会自动跳过
scripts/integration_sdks.sh go         # 启动 inbox 示例服务并以 -race 运行全部测试
```
