# Fyrlet Swift SDK

English | [简体中文](README.zh-CN.md)

An async/await client for typed operations and recoverable realtime subscriptions on Apple platforms (macOS 12+, iOS 15+, tvOS 15+, watchOS 8+). It follows the [protocol](../../docs/PROTOCOL.md) and has the same semantics as the [TypeScript SDK](../typescript/README.md). It uses only Foundation (`URLSession` and `URLSessionWebSocketTask`), with no third-party dependencies. The package is not published; add it with `.package(path: "sdks/swift")`. Linux is untested.

## Exchanging sessions on the backend

```swift
let sessions = try SessionService(endpoint: endpoint, serviceKey: serviceKey)
let session = try await sessions.issueSession(externalSubject: user.id, issuer: "my-product", ttlSeconds: 600)
// Return session.token only to that user; keep the service key on the backend.
try await sessions.revokeSession(session.sessionId)
```

`user` must come from your application's verified login state. Do not ship the service key in an app.

## Calls and retries

```swift
let client = try Client(Options(endpoint: endpoint, projectId: projectId) { forceRefresh in
    try await myBackend.fetchFyrletToken(forceRefresh: forceRefresh)   // returns "rts_..."
})

let item = try decode(Item.self, from: try await client.call("inbox.add", ["text": "Hello"], idempotencyKey: stableID))
```

- The first authentication reads the identity and binds the Subject; switching accounts on one client fails with `FORBIDDEN`. Close the client and create a new one instead.
- The SDK generates an idempotency key per call and refreshes an expired token at most once, reusing that key. `CONFLICT` is never retried automatically. Throw `APIError(code: "UNAUTHENTICATED", ...)` from `getToken` when the host login has ended, to stop recovery.
- Errors are `APIError` (`code`, `message`, `details`, `retryable`, `status`, `requestId`). Requests time out after `Options.timeout` (10 s).
- If a write was dispatched and the result was lost, `call` throws `OutcomeUnknownError` (`operation`, `idempotencyKey`, `cause`). Do not blindly resubmit: ask the server what happened.

```swift
let mutation = await client.mutate("inbox.add", ["text": "Hello"])  // never throws; inspect the state
mutation.state.status                                               // .completed .committed .accepted .failed .unknown
if mutation.state.status == .unknown { _ = try await mutation.recover() }  // reads the stored receipt, never executes again
let found = try await client.recover("inbox.add", ["text": "Hello"], idempotencyKey: key)
```

`recover` returns `.committed`/`.accepted` with the original result, or `.unknown` when no receipt is visible. See [operation outcomes and recovery](../../docs/MUTATIONS.md).

## Subscriptions

```swift
let recent = try client.subscribe("inbox.recent", params: ["limit": 20])
let stop = recent.onChange { state in
    render(state.status, try? state.decoded([Item].self), state.error)
}
try await recent.refresh()   // returns once the server accepted it; data arrives through onChange
stop(); recent.unsubscribe(); client.close()
```

`onChange` immediately delivers the current state, then every change, serially on a dedicated queue, so a listener may call back into the client. Statuses are `.connecting`, `.ready`, `.recovering` (previous data retained), `.error` and `.closed` (data cleared). `generation` and `seq` reject stale messages.

The SDK requests `delta-v1` by default (`Options.delta = false` for full snapshots only), acknowledges every snapshot and delta, and rebuilds the connection after a drop, a sequence gap or a retryable server status with exponential backoff from 250 ms to 30 s (`Options.retryDelay` overrides it). Unconfirmed writes are never replayed. Terminal authentication and permission errors clear data and move the subscription to `.error`. `State.data` is decoded JSON and read-only: a delta creates new containers and never modifies a delivered value.

On iOS the system may suspend sockets in the background. Observe `.recovering` and let the SDK reconnect on foreground, or call `reconnect()` from your scene-phase handler.

## Scope

Implemented: session service, operations over HTTP, identity binding, token refresh, idempotency, unknown-outcome recovery, contract export, subscriptions with snapshots/deltas/ACK/refresh/recovery. Not implemented yet (the TypeScript SDK has them): Runs, append subscriptions, presence, optimistic writes, Socket RPC for operations and generated contract types.

## Tests

```bash
cd sdks/swift && swift test            # unit tests; integration tests skip themselves
scripts/integration_sdks.sh swift      # starts the inbox example server and runs everything
```
