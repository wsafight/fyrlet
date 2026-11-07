# Fyrlet .NET SDK

English | [简体中文](README.zh-CN.md)

A task-based client for typed operations and recoverable realtime subscriptions. It follows the [protocol](../../docs/PROTOCOL.md) and has the same semantics as the [TypeScript SDK](../typescript/README.md). It targets .NET 8+ and uses only the base class library (`HttpClient`, `ClientWebSocket`, `System.Text.Json`), with no third-party dependencies. The package is not published; reference `src/Fyrlet/Fyrlet.csproj` from your project. Works from C#, F# and VB.

## Exchanging sessions on the backend

```csharp
var sessions = new SessionService(endpoint, serviceKey);
var session = await sessions.IssueSessionAsync(user.Id, issuer: "my-product", ttlSeconds: 600);
// Return session.Token only to that user; keep the service key on the backend.
await sessions.RevokeSessionAsync(session.SessionId);
```

`user` must come from your application's verified login state.

## Calls and retries

```csharp
using var client = new FyrletClient(new FyrletOptions
{
    Endpoint = endpoint, ProjectId = projectId,
    GetToken = (forceRefresh, ct) => backend.FetchFyrletTokenAsync(forceRefresh, ct),   // returns "rts_..."
});

var item = await client.CallAsync<Item>("inbox.add", new { text = "Hello" }, new CallOptions { IdempotencyKey = stableId });
JsonElement raw = await client.CallAsync("inbox.history", new { });
```

- The first authentication reads the identity and binds the Subject; switching accounts on one client fails with `FORBIDDEN`. Dispose the client and create a new one instead.
- The SDK generates an idempotency key per call and refreshes an expired token at most once, reusing that key. `CONFLICT` is never retried automatically. Throw `ApiException("UNAUTHENTICATED", ...)` from `GetToken` when the host login has ended, to stop recovery.
- Errors are `ApiException` (`Code`, `Message`, `Details`, `Retryable`, `Status`, `RequestId`). Requests time out after `FyrletOptions.Timeout` (10 s) or when the `CancellationToken` fires.
- If a write was dispatched and the result was lost, `CallAsync` throws `OutcomeUnknownException` (`Operation`, `IdempotencyKey`, `InnerException`). Do not blindly resubmit: ask the server what happened.

```csharp
var mutation = await client.MutateAsync("inbox.add", new { text = "Hello" });   // never throws; inspect the state
mutation.State.Status;                                                          // Completed Committed Accepted Failed Unknown
if (mutation.State.Status == MutationStatus.Unknown) await mutation.RecoverAsync();   // reads the stored receipt, never executes again
var found = await client.RecoverAsync("inbox.add", new { text = "Hello" }, key);
```

`RecoverAsync` returns `Committed`/`Accepted` with the original result, or `Unknown` when no receipt is visible. See [operation outcomes and recovery](../../docs/MUTATIONS.md).

## Subscriptions

```csharp
var recent = client.Subscribe("inbox.recent", new { limit = 20 });
using var stop = recent.OnChange(state => Render(state.Status, state.Decode<Item[]>(), state.Error));
await recent.RefreshAsync();   // returns once the server accepted it; data arrives through OnChange
recent.Unsubscribe();
client.Dispose();
```

`OnChange` immediately delivers the current state, then every change, serially on a dedicated task, so a listener may call back into the client. Statuses are `Connecting`, `Ready`, `Recovering` (previous data retained), `Error` and `Closed` (data cleared). `Generation` and `Seq` reject stale messages. `State.Decode<T>()` reads JSON case-insensitively (`Id` matches `"id"`).

The SDK requests `delta-v1` by default (`Delta = false` for full snapshots only), acknowledges every snapshot and delta, and rebuilds the connection after a drop, a sequence gap or a retryable server status with exponential backoff from 250 ms to 30 s (`RetryDelay` overrides it). Unconfirmed writes are never replayed. Terminal authentication and permission errors clear data and move the subscription to `Error`. `State.Data` is an immutable `JsonElement`: a delta creates a new value and never modifies a delivered one.

## Scope

Implemented: session service, operations over HTTP, identity binding, token refresh, idempotency, unknown-outcome recovery, contract export, subscriptions with snapshots/deltas/ACK/refresh/recovery. Not implemented yet (the TypeScript SDK has them): Runs, append subscriptions, presence, optimistic writes, Socket RPC for operations and generated contract types.

## Tests

```bash
dotnet test sdks/dotnet                # unit tests; integration tests skip themselves
scripts/integration_sdks.sh dotnet     # starts the inbox example server and runs everything
```
