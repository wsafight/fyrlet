# Fyrlet Python SDK

English | [简体中文](README.zh-CN.md)

A synchronous, thread-based client for typed operations and recoverable realtime subscriptions. It follows the [protocol](../../docs/PROTOCOL.md) and has the same semantics as the [TypeScript SDK](../typescript/README.md). The package is not published; install it locally with `pip install -e sdks/python`. It needs Python 3.10+ and depends only on `websockets` (HTTP uses the standard library).

## Exchanging sessions on the backend

```python
from fyrlet import SessionService

sessions = SessionService(os.environ["FYRLET_ENDPOINT"], os.environ["FYRLET_SERVICE_KEY"])
session = sessions.issue_session(authenticated_user.id, issuer="my-product", ttl_seconds=600)
# Return session.token only to that user; keep the service key on the backend.
sessions.revoke_session(session.session_id)
```

`authenticated_user` must come from your application's verified login state.

## Calls and retries

```python
from fyrlet import Client, ApiError, OutcomeUnknownError

client = Client(endpoint, project_id, get_token)   # get_token(force_refresh: bool) -> "rts_..."

item = client.call("inbox.add", {"text": "Hello"}, idempotency_key=stable_request_id)
client.call("inbox.update", {"id": item["id"], "text": "Updated", "expected_version": item["version"]})
```

- The first authentication reads the identity and binds the Subject; switching accounts on one client is rejected with `FORBIDDEN`. Close the client and create a new one instead.
- The SDK generates an idempotency key per call and refreshes an expired token at most once, reusing that key. `CONFLICT` is never retried automatically. Raise `ApiError("UNAUTHENTICATED", ...)` from `get_token(True)` to stop recovery when the host login has ended.
- `ApiError` exposes `code`, `message`, `details`, `retryable`, `status` and `request_id`. Requests time out after 10 seconds (`timeout=`).
- If a write was dispatched and the result was lost, `call` raises `OutcomeUnknownError` (with `operation` and `idempotency_key`). Do not blindly resubmit: ask the server what happened.

```python
mutation = client.mutate("inbox.add", {"text": "Hello"})   # never raises for a failed operation
mutation.state.status        # completed | committed | accepted | failed | unknown
if mutation.state.status == "unknown":
    mutation.recover()       # queries the stored receipt, never executes the operation again
client.recover("inbox.add", {"text": "Hello"}, idempotency_key=key)   # same, from a stored key
```

`recover` returns `committed`/`accepted` with the original result, or `unknown` when no receipt is visible. See [operation outcomes and recovery](../../docs/MUTATIONS.md).

## Subscriptions

```python
recent = client.subscribe("inbox.recent", {"limit": 20})
stop = recent.on_change(lambda state: render(state.status, state.data, state.error))
recent.refresh()        # returns once the server accepted it; data arrives through on_change
stop(); recent.unsubscribe(); client.close()   # or: with Client(...) as client:
```

`on_change` immediately delivers the current state, then every change, on a dedicated dispatcher thread, so a listener may call back into the client. Statuses are `connecting`, `ready`, `recovering` (previous data retained), `error` and `closed` (data cleared). `generation` and `seq` reject stale messages.

The SDK requests `delta-v1` by default (`delta=False` for full snapshots only), acknowledges every snapshot and delta, and rebuilds the connection after a drop, a sequence gap or a retryable server status with exponential backoff from 250 ms to 30 s (`retry_delay=` overrides it). Unconfirmed writes are never replayed. Terminal authentication and permission errors clear data and move the subscription to `error`. Views are treated as immutable: a delta creates new containers and never modifies a delivered value, so do not mutate `state.data`; copy it first.

## Scope

Implemented: session service, operations over HTTP, identity binding, token refresh, idempotency, unknown-outcome recovery, contract export, subscriptions with snapshots/deltas/ACK/refresh/recovery. Not implemented yet (the TypeScript SDK has them): Runs, append subscriptions, presence, optimistic writes, Socket RPC for operations and generated contract types.

## Tests

```bash
pip install -e 'sdks/python[test]'
pytest sdks/python/tests/test_units.py        # offline
scripts/integration_sdks.sh python            # starts the inbox example server and runs everything
```
