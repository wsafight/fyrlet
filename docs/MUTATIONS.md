# Operation outcomes and recovery

English | [简体中文](zh/MUTATIONS.md)

Milestone 1A is implemented. `call` still returns the business result. `mutate` starts the same operation immediately and exposes a lifecycle, its idempotency key and a recovery method. HTTP and Socket RPC have the same semantics.

| State | Meaning |
| --- | --- |
| `pending` | Authorizing, sending or waiting for a response |
| `completed` | A `read` operation returned its result |
| `committed` | A `write` operation committed its database transaction |
| `accepted` | A `run` or `ingest` request was durably accepted; processing may still be pending |
| `failed` | Dispatch did not start, or the server returned a structured 4xx rejection |
| `unknown` | Dispatch started, but the client cannot establish the result |

`committed` does not confirm that subscriptions have caught up. `accepted` does not confirm Run completion, Effect delivery or successful processing of every ingest item. Read the Run or batch view for those outcomes.

## Tracking a call

```ts
import { OutcomeUnknownError } from "@fyrlet/client";

const mutation = client.mutate("inbox.add", { text: "Hello" });
const stop = mutation.onChange((state) => renderSaveState(state));
try {
  const item = await mutation.result;
  renderSavedItem(item);
} catch (error) {
  if (error instanceof OutcomeUnknownError) {
    renderSaveState(await mutation.recover());
  } else {
    reportSaveError(error);
  }
} finally {
  stop();
}
```

`onChange` immediately receives the current state; `getState()` keeps the same reference until a transition. Listener errors go to `onListenerError` and cannot change the operation result. Remove listeners when the UI no longer needs them.

Input is serialized once at invocation. Changing the caller's input later cannot change the request, an authentication retry or recovery. Local serialization or invalid optimistic-target errors can throw synchronously from `mutate`; `call` returns a rejected promise for those errors.

## Unknown results

After dispatch, a lost connection, timeout, cancelled wait, invalid response or 5xx response produces an `OutcomeUnknownError`. It exposes `operation`, `idempotencyKey`, `outcome: "unknown"` and the original `cause`. Its `code` describes the underlying failure; `retryable` is false because uncertainty alone does not authorize replay. Failures before dispatch preserve their original error or abort reason. An explicit authentication rejection may refresh credentials once using the same serialized input and key.

`AbortSignal` and `close()` stop waiting; they do not undo a submitted transaction. Interrupted business calls are not automatically replayed. Run signal/cancel and session-service requests do not use this mutation lifecycle.

Optional [bounded retries](../sdks/typescript/README.md#opt-in-bounded-retries) require explicit runtime operation metadata and `CallOptions.retry`. While active, `pending.retry` exposes the attempt, call/recover phase and next retry time. An uncertain write or Run switches exclusively to receipt queries; it never resumes business replay after missing or expired receipts. Cancellation and deadlines preserve any earlier unknown outcome. The final successful operation can then confirm views independently.

## Recovering a result

`mutation.recover({ signal? })` only queries a stored receipt. Concurrent recovery calls on one handle share the current query and its first caller's signal. Recovery has a fresh deadline and does not reuse the original call's abort signal. A terminal handle returns its existing state without querying. A recovery error rejects its promise while preserving the unknown state.

After reload or client replacement, use the original operation, input and key:

```ts
const result = await client.recover("inbox.add", originalInput, {
  idempotencyKey: savedKey,
});
```

Recovery requires the same project and subject, a valid session, current business authorization and the operation's required capability. An unexpired matching receipt returns `{status: "committed" | "accepted", data}`; no visible receipt returns `{status: "unknown"}`. Different normalized input conflicts. Only `write` and `run` have operation-level receipts. Ingest uses item keys and batch views instead.

A missing receipt may mean an in-flight transaction, rollback, expiry or cleanup; it does not prove failure. Recovery never executes business logic, deletes expired receipts, creates another Run or inserts another invalidation job. Default retention is 24 hours. Calling the operation again after retention can execute it again, even with the same key.

Persist the operation, input, identity and key before starting if recovery must survive a page or process exit; supply that key through `idempotencyKey`. The SDK has no persistent queue. Recovery updates the handle's state, while its original `result` promise remains rejected.

## Predictions and confirmation

Definite failure removes the call's optimistic predictions immediately. After success, the SDK requests a correlated fresh snapshot for each predicted snapshot or append subscription. Only its matching snapshot retires those predictions; unrelated snapshots and deltas keep them. `optimisticTtlMs` (default 5000 ms) remains a display fallback, not proof of confirmation. Unknown outcomes retain predictions until TTL and do not issue confirmation requests. Presence keeps its roster-based prediction behavior.

`CallOptions.confirm` selects additional subscriptions even without predictions. `mutation.result` preserves the business result and does not wait for views. `mutation.views` resolves to one `{subscription, status: "confirmed" | "unconfirmed", error?}` result per selected handle; predicted snapshot and append handles are included automatically. Timeout, cancellation, permission loss, unsupported capability, unsubscribe and reconnect produce an explicit unconfirmed result without changing the committed operation or replaying it. No targets produce an empty list.

```ts
const mutation = client.mutate("inbox.add", { text: "Hello" }, { confirm: [recent] });
await mutation.result;
const views = await mutation.views;
```

`subscription.confirm({signal?})` independently waits for a newly requested authoritative snapshot. `subscription.refresh()` still resolves on the accepted reply. Confirmation uses `timeoutMs`, binds to the current generation and is capped at 32 pending requests per entry. After recovering an unknown receipt, explicitly call `confirm()` on the views that need refreshing. Empty, filtered, deleted or unchanged results can be confirmed; confirmation concerns the query result, not the presence of a particular record or completion of accepted background work.

## Runnable example

The Inbox CLI uses this lifecycle and queries one receipt after an unknown result:

```sh
npm --prefix sdks/typescript run build
node sdks/typescript/examples/inbox.mjs 'Hello'
FYRLET_RECOVER_KEY=original-key node sdks/typescript/examples/inbox.mjs 'Hello'
```

Start Inbox and provide `.local/project.json` as described in the [SDK README](../sdks/typescript/README.md). The command with `FYRLET_RECOVER_KEY` only queries a receipt. Tests include lost HTTP and Socket responses after real commits, cancellation, stalled bodies, expiry, input conflicts, authorization and identity isolation. Commands and counts are in [ACCEPTANCE.md](ACCEPTANCE.md).
