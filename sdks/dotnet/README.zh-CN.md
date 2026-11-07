# Fyrlet .NET SDK

[English](README.md) | 简体中文

基于 Task 的客户端，提供类型化业务调用和可恢复的实时订阅。遵循[协议](../../docs/PROTOCOL.md)，语义与 [TypeScript SDK](../typescript/README.zh-CN.md) 一致。目标框架 .NET 8+，只使用基础类库（`HttpClient`、`ClientWebSocket`、`System.Text.Json`），没有第三方依赖。包尚未发布，请在项目中引用 `src/Fyrlet/Fyrlet.csproj`。可用于 C#、F# 和 VB。

## 在后端交换会话

```csharp
var sessions = new SessionService(endpoint, serviceKey);
var session = await sessions.IssueSessionAsync(user.Id, issuer: "my-product", ttlSeconds: 600);
// 只把 session.Token 返回给该用户；service key 只留在后端。
await sessions.RevokeSessionAsync(session.SessionId);
```

`user` 必须来自应用已验证的登录状态。

## 调用与重试

```csharp
using var client = new FyrletClient(new FyrletOptions
{
    Endpoint = endpoint, ProjectId = projectId,
    GetToken = (forceRefresh, ct) => backend.FetchFyrletTokenAsync(forceRefresh, ct),   // 返回 "rts_..."
});

var item = await client.CallAsync<Item>("inbox.add", new { text = "Hello" }, new CallOptions { IdempotencyKey = stableId });
JsonElement raw = await client.CallAsync("inbox.history", new { });
```

- 首次认证会读取身份并绑定 Subject；同一客户端切换账号会以 `FORBIDDEN` 失败，请释放后新建客户端。
- SDK 为每次调用生成幂等键，登录过期时最多刷新一次 token 并复用该键。`CONFLICT` 不会自动重试。宿主登录已失效时，让 `GetToken` 抛出 `ApiException("UNAUTHENTICATED", ...)` 以终止恢复。
- 错误为 `ApiException`（`Code`、`Message`、`Details`、`Retryable`、`Status`、`RequestId`）。请求在 `FyrletOptions.Timeout`（10 秒）或 `CancellationToken` 触发时终止。
- 写请求已发出但结果丢失时，`CallAsync` 抛出 `OutcomeUnknownException`（`Operation`、`IdempotencyKey`、`InnerException`）。不要盲目重发，先向服务端查询。

```csharp
var mutation = await client.MutateAsync("inbox.add", new { text = "Hello" });   // 不会抛出；检查状态
mutation.State.Status;                                                          // Completed Committed Accepted Failed Unknown
if (mutation.State.Status == MutationStatus.Unknown) await mutation.RecoverAsync();   // 读取已存储的回执，绝不再次执行
var found = await client.RecoverAsync("inbox.add", new { text = "Hello" }, key);
```

`RecoverAsync` 返回带原始结果的 `Committed`/`Accepted`，或在看不到回执时返回 `Unknown`。详见[操作结果与恢复](../../docs/MUTATIONS.md)。

## 订阅

```csharp
var recent = client.Subscribe("inbox.recent", new { limit = 20 });
using var stop = recent.OnChange(state => Render(state.Status, state.Decode<Item[]>(), state.Error));
await recent.RefreshAsync();   // 服务端接受后返回；数据通过 OnChange 到达
recent.Unsubscribe();
client.Dispose();
```

`OnChange` 会立即交付当前状态，随后交付每次变化，由专用 Task 串行回调，因此监听器可以安全地回调客户端。状态为 `Connecting`、`Ready`、`Recovering`（保留旧数据）、`Error` 和 `Closed`（清空数据）。`Generation` 与 `Seq` 用于拒绝过期消息。`State.Decode<T>()` 按不区分大小写读取 JSON（`Id` 可匹配 `"id"`）。

SDK 默认请求 `delta-v1`（`Delta = false` 则只要完整快照），确认每个快照和增量，并在断线、序号缺口或服务端返回可重试状态后，以 250 ms 到 30 s 的指数退避重建连接（可用 `RetryDelay` 覆盖）。未确认的写入不会重放。终止性的认证和权限错误会清空数据并使订阅进入 `Error`。`State.Data` 是不可变的 `JsonElement`：增量会创建新值，不修改已交付的值。

## 范围

已实现：会话服务、基于 HTTP 的业务调用、身份绑定、token 刷新、幂等、结果未知后的恢复、契约导出，以及带快照/增量/ACK/refresh/恢复的订阅。尚未实现（TypeScript SDK 已有）：Run、append 订阅、presence、乐观写入、业务调用的 Socket RPC 和契约类型生成。

## 测试

```bash
dotnet test sdks/dotnet                # 单元测试；集成测试会自动跳过
scripts/integration_sdks.sh dotnet     # 启动 inbox 示例服务并运行全部测试
```
