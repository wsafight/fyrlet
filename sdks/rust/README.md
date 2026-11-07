# Fyrlet Rust SDK

English | [简体中文](README.zh-CN.md)

A blocking, thread-based client for typed operations and recoverable realtime subscriptions. It follows the [protocol](../../docs/PROTOCOL.md) and has the same semantics as the [TypeScript SDK](../typescript/README.md). Crate `fyrlet` needs Rust 1.75+ and depends on `serde_json`, `ureq` for HTTP, `tungstenite` for WebSocket (rustls TLS), `url`, `base64` and `uuid`. It is not published; use a path dependency or a workspace.

## Exchanging sessions on the backend

```rust
let sessions = SessionService::new(&endpoint, &service_key)?;
let session = sessions.issue_session(
    IssueSessionInput::new(user.id()).with_issuer("my-product").with_ttl_seconds(600),
)?;
// Return session.token only to that user; keep the service key on the backend.
sessions.revoke_session(&session.session_id)?;
```

`user.id()` must come from the application's verified login state.

## Calls and retries

```rust
let client = Client::new(Options::new(endpoint, project_id, move |force_refresh| {
    backend.fetch_fyrlet_token(force_refresh)   // returns "rts_..."
}))?;

let item: Item = client.call_into_with(
    "inbox.add",
    json!({"text": "Hello"}),
    CallOptions::idempotency_key(stable_id),
)?;
let raw: Value = client.call("inbox.history", Value::Null)?;
```

- The first authentication reads `/api/v1/identity` and binds the Subject; switching accounts on one client fails with `FORBIDDEN`. Close the client and create a new one instead.
- The SDK generates an idempotency key per call and refreshes an expired token at most once, reusing that key. `CONFLICT` is never retried automatically. Return an error with code `UNAUTHENTICATED` from the token callback when the host login has ended, to stop recovery.
- Failures are [`Error`](src/errors.rs) values; use `code()`, `api_error()` and `is_retryable()`. Requests time out after `Options.timeout` (10 seconds by default).
- If a write was dispatched and the result was lost, the mutation error is `Error::OutcomeUnknown(OutcomeUnknownError)` with `operation`, `idempotency_key` and the underlying `cause`. Do not blindly resubmit: ask the server what happened.

```rust
let mutation = client.mutate("inbox.add", input);   // never fails itself
mutation.state().status;                            // Completed Committed Accepted Failed Unknown
if mutation.state().status == MutationStatus::Unknown {
    mutation.recover()?;                            // reads the stored receipt, never executes again
}
let found = client.recover("inbox.add", input, &key)?;
```

`recover` returns `Committed` or `Accepted` with the original result, or `Unknown` when no receipt is visible. See [operation outcomes and recovery](../../docs/MUTATIONS.md).

## Subscriptions

```rust
let recent = client.subscribe("inbox.recent", json!({"limit": 20}))?;
let _guard = recent.on_change(|state| {
    let items: Vec<Item> = state.decode().unwrap_or_default();
    render(state.status, items, state.error);
});
recent.refresh()?;          // returns once the server accepted it; data arrives through on_change
recent.unsubscribe();
```

`on_change` immediately delivers the current state, then every change, serially on a dedicated dispatcher thread, so a listener may call back into the client. Statuses are `Connecting`, `Ready`, `Recovering` (previous data retained), `Error` and `Closed` (data cleared). `generation` and `seq` reject stale messages. Dropping the returned guard removes the listener.

The SDK requests `delta-v1` by default (`Options.disable_delta` for full snapshots only), acknowledges every snapshot and delta, and rebuilds the connection after a drop, a sequence gap or a retryable server status with exponential backoff from 250 ms to 30 s (`Options.retry_delay` overrides it). Unconfirmed writes are never replayed. Terminal authentication and permission errors clear data and move the subscription to `Error`. Listener panics are caught and reported through `Options.on_listener_error`. `SubscriptionState.data` is read-only: a delta creates new containers and never modifies a delivered value.

## Scope

Implemented: session service, operations over HTTP, identity binding, token refresh, idempotency, unknown-outcome recovery, contract export, subscriptions with snapshots/deltas/ACK/refresh/recovery. Not implemented yet (the TypeScript SDK has them): Runs, append subscriptions, presence, optimistic writes, Socket RPC for operations and generated contract types.

## Tests

```bash
cargo test                          # unit tests; integration tests skip themselves
cargo build --examples
scripts/integration_sdks.sh rust    # starts the inbox example server and runs everything
```

The example reads `FYRLET_ENDPOINT`, `FYRLET_PROJECT_ID` and `FYRLET_SERVICE_KEY`:

```bash
FYRLET_ENDPOINT=http://127.0.0.1:4000 FYRLET_PROJECT_ID=... FYRLET_SERVICE_KEY=rtk_... \
  cargo run --example inbox -- "First note"
```
