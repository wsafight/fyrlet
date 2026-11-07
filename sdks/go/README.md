# Fyrlet Go SDK

English | [简体中文](README.zh-CN.md)

A context-aware client for typed operations and recoverable realtime subscriptions. It follows the [protocol](../../docs/PROTOCOL.md) and has the same semantics as the [TypeScript SDK](../typescript/README.md). Module `github.com/wsafight/fyrlet/sdks/go` (package `fyrlet`) needs Go 1.22+ and depends only on `gorilla/websocket`. It has not been tagged or published; use a `replace` directive or `go work` for now.

## Exchanging sessions on the backend

```go
sessions, _ := fyrlet.NewSessionService(os.Getenv("FYRLET_ENDPOINT"), os.Getenv("FYRLET_SERVICE_KEY"), nil)
session, err := sessions.IssueSession(ctx, fyrlet.IssueSessionInput{ExternalSubject: user.ID, Issuer: "my-product", TTLSeconds: 600})
// Return session.Token only to that user; keep the service key on the backend.
_, err = sessions.RevokeSession(ctx, session.SessionID)
```

`user` must come from your application's verified login state.

## Calls and retries

```go
client, err := fyrlet.NewClient(fyrlet.Options{
	Endpoint: endpoint, ProjectID: projectID,
	GetToken: func(ctx context.Context, forceRefresh bool) (string, error) { /* return "rts_..." */ },
})
defer client.Close()

var item Item
err = client.CallInto(ctx, "inbox.add", map[string]any{"text": "Hello"}, &item, fyrlet.WithIdempotencyKey(stableID))
raw, err := client.Call(ctx, "inbox.history", nil) // json.RawMessage
```

- The first authentication reads the identity and binds the Subject; switching accounts on one client fails with `FORBIDDEN`. Close the client and create a new one instead.
- The SDK generates an idempotency key per call and refreshes an expired token at most once, reusing that key. `CONFLICT` is never retried automatically. Return `&fyrlet.APIError{Code: "UNAUTHENTICATED"}` from `GetToken` when the host login has ended to stop recovery.
- Errors are `*fyrlet.APIError` (`Code`, `Message`, `Details`, `Retryable`, `Status`, `RequestID`); use `errors.As`. Requests time out after `Options.Timeout` (10 s) or when `ctx` ends.
- If a write was dispatched and the result was lost, the error is `*fyrlet.OutcomeUnknownError` (with `Operation`, `IdempotencyKey`, `Cause`). Do not blindly resubmit: ask the server what happened.

```go
m := client.Mutate(ctx, "inbox.add", input)  // never fails itself; inspect the Mutation
m.State().Status                             // completed | committed | accepted | failed | unknown
if m.State().Status == fyrlet.MutationUnknown {
	state, err := m.Recover(ctx)             // queries the stored receipt, never executes again
}
found, err := client.Recover(ctx, "inbox.add", input, key) // same, from a stored key
```

`Recover` returns `committed`/`accepted` with the original result, or `unknown` when no receipt is visible. See [operation outcomes and recovery](../../docs/MUTATIONS.md).

## Subscriptions

```go
recent, _ := client.Subscribe("inbox.recent", map[string]any{"limit": 20})
stop := recent.OnChange(func(s fyrlet.State) {
	var items []Item
	_ = s.Decode(&items)
	render(s.Status, items, s.Err)
})
err = recent.Refresh(ctx) // returns once the server accepted it; data arrives through OnChange
stop(); recent.Unsubscribe()
```

`OnChange` immediately delivers the current state, then every change, serially on a dedicated goroutine, so a listener may call back into the client. Statuses are `connecting`, `ready`, `recovering` (previous data retained), `error` and `closed` (data cleared). `Generation` and `Seq` reject stale messages.

The SDK requests `delta-v1` by default (`Options.DisableDelta` for full snapshots only), acknowledges every snapshot and delta, and rebuilds the connection after a drop, a sequence gap or a retryable server status with exponential backoff from 250 ms to 30 s (`Options.RetryDelay` overrides it). Unconfirmed writes are never replayed. Terminal authentication and permission errors clear data and move the subscription to `error`. `State.Data` is decoded JSON and read-only: a delta creates new containers and never modifies a delivered value.

## Scope

Implemented: session service, operations over HTTP, identity binding, token refresh, idempotency, unknown-outcome recovery, contract export, subscriptions with snapshots/deltas/ACK/refresh/recovery. Not implemented yet (the TypeScript SDK has them): Runs, append subscriptions, presence, optimistic writes, Socket RPC for operations and generated contract types.

## Tests

```bash
go test ./sdks/go/...                  # offline unit tests; integration tests skip themselves
scripts/integration_sdks.sh go         # starts the inbox example server and runs everything with -race
```
