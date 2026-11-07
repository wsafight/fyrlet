# Effect and Outbox

External side effects (sending email, calling third-party HTTP, and so on) cannot be put inside a database transaction. An Effect commits the **intent** together with the local transaction, a unified dispatcher executes it outside the transaction, and uncertain outcomes are recorded as they are. The Outbox guarantees that the intent is committed together with the local transaction, and **does not automatically guarantee that the external system executes only once**.

An Effect always belongs to a Step of a [Run](RUNS.md). The adapter protocol, retry rules and manual resolution are described below; usage from the developer's point of view is in [SERVER.md](SERVER.md).

## Problem

Write idempotency covers only writes within the same database transaction (see FR-04 in [PRODUCT.md](PRODUCT.md)). External side effects need a unified record of the intent of external work, dispatch attempts and uncertain outcomes, and the retry boundary follows the capabilities declared by the adapter. The Outbox guarantees that the intent is committed together with the local transaction; it does not automatically guarantee that the external system executes only once.

## Model

Table `fyrlet_effects`:

| Field | Description |
| --- | --- |
| `operation_id` | Durable, stable business request ID; used as the outward idempotency key and reused on retries |
| `project_id` / `run_id` / `step_id` / `effect_key` | Ownership and logical unique key; the same Effect of the same Step is not created twice |
| `adapter` / `adapter_version` / `delivery_policy` | Adapter, capability version and explicit retry policy |
| `payload` / `payload_hash` | Fixed, normalized request without credentials; the same logical key with a different request conflicts |
| `status` | `pending` (awaiting dispatch) / `claimed` (claimed, external call in progress or result not yet written back) / `accepted` (accepted by the receiver, awaiting a receipt or lookup) / `succeeded` / `failed` / `unknown` / `cancelled` |
| `lease_id` / `execution_epoch` / `lease_expires_at` | Dispatch ownership and isolation of old results; independent of the Step Attempt lease (see [RUNS.md](RUNS.md#state-and-data)) |
| `attempts` / `claimed_at` / `next_attempt_at` | Attempt records and scheduling; `claimed_at` does not mean the external system has executed |
| `secret_ref` | Reference name of the credential the adapter needs; the adapter resolves the credential itself from the project secret store at dispatch time, and it does not enter `payload`, logs or events |
| `external_ref` / `result` / `last_error` / `resolution_required` | External reference, known result and manual-resolution flag |

Rules:

1. After a Step returns an Effect intent, the core, in the same transaction, creates the Effect, sets the Step to `awaiting_effect` (releasing the current Attempt lease, and the Run's `wait_reason` is `effect`), and creates the dispatch job; if the transaction rolls back, none of the three exists.
2. Only the unified Effect dispatcher may dispatch. Oban wakes the dispatcher; the Step executor must not call the adapter directly again. A dispatch claim first records the lease and `claimed` in a short transaction, and the external call completes outside the transaction.
3. When the dispatching process is lost or the response is uncertain (`claimed` with an expired lease, or the adapter returns `:unknown`), the Effect enters `unknown`; it must not be concluded that the external side did not execute merely because there is no local success record.
4. Effect completion is committed in the same transaction as the Step output and subsequent advancement; when the Run is already cancelled or expired, only the real result of the Effect is saved and the Run is not advanced.
5. The idempotency guarantee depends on the receiver's constraint on the stable business key and on its retention window. **Reconciliation by lookup is not deduplication; the framework does not uniformly promise exactly-once or at-most-once external side effects.**

Adapters must declare capabilities and policy:

| External capability | Allowed default behavior | Guarantee boundary |
| --- | --- | --- |
| Idempotency key or unique business key | Retry by reusing `operation_id` within the valid idempotency window | Deduplication depends on the receiver's contract; beyond the window, safe retry can no longer be claimed |
| Result lookup only | Reconcile first; pause dispatch when the result is unclear | Not found may still mean in progress, so it cannot be used to prove that resending is safe |
| No idempotency, no lookup | An uncertain result pauses and requires manual resolution | A resend that may duplicate is allowed only after the business explicitly chooses `retry_allow_duplicates` |

A temporary failure that is known not to have executed may be retried with backoff; an uncertain failure must not be disguised as "known not to have executed". The automatic retry period must not exceed the provider's deduplication window, and when the relevant capability is unknown it is treated as unsupported.

## Adapter protocol

```elixir
defmodule Fyrlet.Effects.Adapter do
  @callback capabilities() :: map()
  @callback dispatch(effect :: map()) ::
              {:succeeded, term()} | {:accepted, term()} | {:failed, term()} |
              {:retryable, term()} | :unknown
  @callback query(effect :: map()) ::
              {:succeeded, term()} | {:failed, term()} | :pending | :not_found | :unknown
  @callback cancel(effect :: map()) :: :ok | {:error, term()}
  @optional_callbacks query: 1, cancel: 1
end
```

`capabilities` declares at least the idempotency method and its validity period, whether the effect is queryable, whether it is cancellable, and whether a success result means "accepted by the provider" or "final business completion". For example, acceptance by an email service cannot automatically be interpreted as the user having received the email.

`accepted` puts the Effect into the `accepted` status to await a verifiable receipt or lookup result (receipts are submitted by calling the core API through a restricted integration principal, see [PROTOCOL.md](PROTOCOL.md#effect-receipts)); `retryable` is used only for failures where the adapter can confirm that no business effect has yet occurred. A `not_found` from a lookup is not by itself a basis for safe resending.

Handling of `unknown`: when lookup is supported, reconcile with backoff; if it is still `unknown` after `effect_reconcile_ttl` (default 24 hours), set `resolution_required: true` and raise an alert, without automatically converting it to `failed`. It enters `failed` only when a trusted result proves the failure. Manual confirmation, giving up waiting or allowing a resend must record the evidence, the operator and the decision, and must not overwrite the original attempt records.

Clients can read the Effect status; an operation that depends on that result may return `EFFECT_UNKNOWN` (HTTP 409, `retryable: false`), and the SDK is forbidden to resend the external business automatically because of this error.

## Relationship to the write path

- `write` still keeps "success on transaction commit"; success only means the local business write is complete and does not mean any external work is complete. A managed write callback must not call external systems directly.
- An Effect must belong to a Run/Step; a business that only needs asynchronous delivery can also use a single-Step Run. No API is provided for a standalone write to produce an Effect directly, to avoid two sets of scheduling and completion semantics.
- The request idempotency window, the Effect reconciliation window, the provider deduplication window and the Run history retention period are configured separately. The logical unique key and attempt records of an unresolved Effect must not be cleaned up together with request idempotency records.
