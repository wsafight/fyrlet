# Fyrlet Java SDK

[English](README.md) | 简体中文

阻塞式、线程安全的客户端，提供类型化业务调用和可恢复的实时订阅。遵循[协议](../../docs/PROTOCOL.md)，语义与 [TypeScript SDK](../typescript/README.zh-CN.md) 一致。坐标 `com.fyrlet:fyrlet:0.1.0`，需要 JDK 17+，仅使用内置 `HttpClient`、`WebSocket` 和 Gson 处理 JSON。尚未发布，请用 Maven 本地构建或安装。

## 在后端交换会话

```java
var sessions = new SessionService(endpoint, serviceKey);
UserSession session = sessions.issueSession(user.id(), "my-product", 600);
// 只把 session.token() 返回给该用户；service key 只留在后端。
sessions.revokeSession(session.sessionId());
```

`user.id()` 必须来自应用已验证的登录状态。不要把 service key 放进客户端应用。

## 调用与重试

```java
FyrletOptions options = new FyrletOptions(endpoint, projectId,
        forceRefresh -> backend.fetchFyrletToken(forceRefresh));   // 返回 "rts_..."
try (FyrletClient client = new FyrletClient(options)) {
    Item item = client.callInto("inbox.add", Map.of("text", "Hello"), Item.class, stableId);
    JsonElement raw = client.call("inbox.history", null);
}
```

- 首次认证会读取 `/api/v1/identity` 并绑定 Subject；同一客户端切换账号会以 `FORBIDDEN` 失败，请关闭后新建客户端。
- SDK 为每次调用生成幂等键，登录过期时最多刷新一次 token 并复用该键。`CONFLICT` 不会自动重试。宿主登录已失效时，让 `TokenProvider` 抛出 `ApiException("UNAUTHENTICATED", ...)` 以终止恢复。
- 错误为 `ApiException`（`code()`、`getMessage()`、`details()`、`retryable()`、`status()`、`requestId()`）。请求在 `FyrletOptions.timeout`（默认 10 秒）后超时。
- 写请求已发出但结果丢失时，失败为 `OutcomeUnknownException`（带 `operation()`、`idempotencyKey()` 和原始 cause）。不要盲目重发，先向服务端查询。

```java
Mutation mutation = client.mutate("inbox.add", input);   // 失败时不会抛出，检查状态
mutation.state().status();                               // COMPLETED COMMITTED ACCEPTED FAILED UNKNOWN
if (mutation.state().status() == MutationStatus.UNKNOWN) {
    mutation.recover();                                  // 查询已存储的回执，绝不再次执行
}
RecoveryResult found = client.recover("inbox.add", input, key);
```

`recover` 返回带原始结果的 `COMMITTED`/`ACCEPTED`，或在看不到回执时返回 `UNKNOWN`。详见[操作结果与恢复](../../docs/MUTATIONS.md)。

## 订阅

```java
Subscription recent = client.subscribe("inbox.recent", Map.of("limit", 20));
ListenerHandle stop = recent.onChange(state ->
        render(state.status(), state.decode(Item[].class), state.error()));
recent.refresh();          // 服务端接受后返回；数据通过 onChange 到达
stop.close();
recent.unsubscribe();
```

`onChange` 会立即交付当前状态，随后交付每次变化，由专用监听线程串行回调，因此监听器可以安全地回调客户端。状态为 `CONNECTING`、`READY`、`RECOVERING`（保留旧数据）、`ERROR` 和 `CLOSED`（清空数据）。`generation()` 与 `seq()` 用于拒绝过期消息。

SDK 默认请求 `delta-v1`（`FyrletOptions.delta = false` 则只要完整快照），确认每个快照和增量，并在断线、序号缺口或服务端返回可重试状态后，以 250 ms 到 30 s 的指数退避重建连接（可用 `FyrletOptions.retryDelay` 覆盖）。未确认的写入不会重放。终止性的认证和权限错误会清空数据并使订阅进入 `ERROR`。`SubscriptionState.data()` 是 JSON 视图，只读：增量会创建新容器，不修改已交付的值。

## 范围

已实现：会话服务、基于 HTTP 的业务调用、身份绑定、token 刷新、幂等、结果未知后的恢复、契约导出，以及带快照/增量/ACK/refresh/恢复的订阅。尚未实现（TypeScript SDK 已有）：Run、append 订阅、presence、乐观写入、业务调用的 Socket RPC 和契约类型生成。

## 测试

```bash
mvn test                            # 离线单元测试；集成测试会自动跳过
scripts/integration_sdks.sh java    # 启动 inbox 示例服务并运行全部测试
```

示例读取 `FYRLET_ENDPOINT`、`FYRLET_PROJECT_ID` 和 `FYRLET_SERVICE_KEY`：

```bash
mvn -q compile dependency:build-classpath -Dmdep.outputFile=target/classpath.txt
java -cp "target/classes:$(cat target/classpath.txt)" examples/Inbox.java "First note"
```
