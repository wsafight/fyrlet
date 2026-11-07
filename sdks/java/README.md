# Fyrlet Java SDK

English | [简体中文](README.zh-CN.md)

A blocking, thread-safe client for typed operations and recoverable realtime subscriptions. It follows the [protocol](../../docs/PROTOCOL.md) and has the same semantics as the [TypeScript SDK](../typescript/README.md). Coordinates are `com.fyrlet:fyrlet:0.1.0`; it requires JDK 17+ and uses the built-in `HttpClient` and `WebSocket` plus Gson for JSON. The artifact is not published; build or install it locally with Maven.

## Exchanging sessions on the backend

```java
var sessions = new SessionService(endpoint, serviceKey);
UserSession session = sessions.issueSession(user.id(), "my-product", 600);
// Return session.token() only to that user; keep the service key on the backend.
sessions.revokeSession(session.sessionId());
```

`user.id()` must come from the application's verified login state. Never ship the service key in an app.

## Calls and retries

```java
FyrletOptions options = new FyrletOptions(endpoint, projectId,
        forceRefresh -> backend.fetchFyrletToken(forceRefresh));   // returns "rts_..."
try (FyrletClient client = new FyrletClient(options)) {
    Item item = client.callInto("inbox.add", Map.of("text", "Hello"), Item.class, stableId);
    JsonElement raw = client.call("inbox.history", null);
}
```

- The first authentication reads `/api/v1/identity` and binds the Subject; switching accounts on one client fails with `FORBIDDEN`. Close the client and create a new one instead.
- The SDK generates an idempotency key per call and refreshes an expired token at most once, reusing that key. `CONFLICT` is never retried automatically. Throw `ApiException("UNAUTHENTICATED", ...)` from `TokenProvider` when the host login has ended, to stop recovery.
- Errors are `ApiException` (`code()`, `getMessage()`, `details()`, `retryable()`, `status()`, `requestId()`). Requests time out after `FyrletOptions.timeout` (10 seconds by default).
- If a write was dispatched and the result was lost, the failure is `OutcomeUnknownException` (with `operation()`, `idempotencyKey()`, and the original cause). Do not blindly resubmit: ask the server what happened.

```java
Mutation mutation = client.mutate("inbox.add", input);   // never throws for a failed operation
mutation.state().status();                               // COMPLETED COMMITTED ACCEPTED FAILED UNKNOWN
if (mutation.state().status() == MutationStatus.UNKNOWN) {
    mutation.recover();                                  // reads the stored receipt, never executes again
}
RecoveryResult found = client.recover("inbox.add", input, key);
```

`recover` returns `COMMITTED` or `ACCEPTED` with the original result, or `UNKNOWN` when no receipt is visible. See [operation outcomes and recovery](../../docs/MUTATIONS.md).

## Subscriptions

```java
Subscription recent = client.subscribe("inbox.recent", Map.of("limit", 20));
ListenerHandle stop = recent.onChange(state ->
        render(state.status(), state.decode(Item[].class), state.error()));
recent.refresh();          // returns once the server accepted it; data arrives through onChange
stop.close();
recent.unsubscribe();
```

`onChange` immediately delivers the current state, then every change, serially on a dedicated listener thread, so a listener may call back into the client. Statuses are `CONNECTING`, `READY`, `RECOVERING` (previous data retained), `ERROR` and `CLOSED` (data cleared). `generation()` and `seq()` reject stale messages.

The SDK requests `delta-v1` by default (`FyrletOptions.delta = false` for full snapshots only), acknowledges every snapshot and delta, and rebuilds the connection after a drop, a sequence gap or a retryable server status with exponential backoff from 250 ms to 30 s (`FyrletOptions.retryDelay` overrides it). Unconfirmed writes are never replayed. Terminal authentication and permission errors clear data and move the subscription to `ERROR`. `SubscriptionState.data()` is a JSON view and must be treated as read-only: a delta creates new containers and never modifies a delivered value.

## Scope

Implemented: session service, operations over HTTP, identity binding, token refresh, idempotency, unknown-outcome recovery, contract export, subscriptions with snapshots/deltas/ACK/refresh/recovery. Not implemented yet (the TypeScript SDK has them): Runs, append subscriptions, presence, optimistic writes, Socket RPC for operations and generated contract types.

## Tests

```bash
mvn test                            # unit tests; integration tests skip themselves
scripts/integration_sdks.sh java    # starts the inbox example server and runs everything
```

The example reads `FYRLET_ENDPOINT`, `FYRLET_PROJECT_ID` and `FYRLET_SERVICE_KEY`:

```bash
mvn -q compile dependency:build-classpath -Dmdep.outputFile=target/classpath.txt
java -cp "target/classes:$(cat target/classpath.txt)" examples/Inbox.java "First note"
```
