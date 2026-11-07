# Durable Runs

Optional capability `runs`. A Run expresses work that must survive across requests and processes: long-running work, waiting for external signals, work that needs human intervention or cancellation. Ordinary reads, writes and subscriptions do not need a Run; the state of a Run is observed through the existing subscription mechanism.

> **One-sentence goal:** an application can both make reliable transactional calls and start durable tasks that are observable, interruptible and cancellable; on recovery it continues from the facts that have already been committed.

For external side effects, Runs depend on [Effects and Outbox](EFFECTS.md); for the authentication boundaries see [ARCHITECTURE.md](ARCHITECTURE.md#authentication-boundaries), for the wire entry points see [PROTOCOL.md](PROTOCOL.md#run-capability-runs), and for business callbacks see [SERVER.md](SERVER.md).

## Operation kinds

The `kind` of `operations` has three values:

| kind | Semantics | Returns |
| --- | --- | --- |
| `read` | Bounded query | Result |
| `write` | Single-transaction business write | Result + affected Scope |
| **`run`** | Creates a long-running Run; only a record is written inside the transaction, and it returns immediately | `run_id` + initial status |

A `run` operation must carry an `Idempotency-Key`. Within the idempotency retention period, the same `(project, subject, operation, key)` with the same normalized input returns the same `run_id`; a different input returns a conflict. The default retention period is 24 hours, and after it expires, using the key again may create a new Run.

A business that needs long-term uniqueness (such as "notify only once per event") uses the optional `business_key`: `run/3` can return that key, and the core establishes a `(project_id, operation, business_key)` unique constraint on `fyrlet_runs` (effective only for non-empty keys, and not cleaned up with request idempotency records). On conflict it returns the existing `run_id` and its current status and does not create a new Run; whether re-creation after a terminal state is allowed is declared by the operation (`on_conflict: :return_existing | :reject_if_active`, default `:return_existing`).

Creating the Run, persisting the plan and creating the first Oban job complete in the same transaction; HTTP success means the run has been accepted, not that the business work has completed.

## Definition

Doing the work is separated from deciding the next step:

| Callback | Responsibility |
| --- | --- |
| `run/3` | Produces a sequential plan from the operation name, the verified initiator and the input; performs no external calls |
| `step/3` | Returns a business result or an Effect intent from the step name, the persisted input and the execution context |
| `advance/3` | Decides the next step from the persisted state, the event and the context; performs no IO (dynamic advancement) |

A static plan contains work nodes and explicit wait nodes:

```elixir
{:ok, steps: [
  %{type: :step, name: "prepare", input: %{"source_id" => source_id}},
  %{type: :wait, name: "approval", signal: "user_approval", timeout_ms: 86_400_000, on_timeout: :fail},
  %{type: :step, name: "publish", input: %{}}
]}
```

The return value of `step/3` is `{:ok, output}`, `{:error, %Fyrlet.Error{}}` or `{:effect, effect_spec}`; it may also return `{:ok, output, commit: fun}`, where `fun` runs inside the **same transaction** that commits the result, so that a business write and the step result are committed atomically (managed commit). If `fun` returns `{:error, error}` or raises, the whole commit rolls back and is then recorded as a failed attempt. An Effect intent is handed to the core to be committed and dispatched, see [EFFECTS.md](EFFECTS.md); a Step does not return a "next step" instruction. The execution context provides previously committed outputs; the resolved input of the current Step is fixed before its first execution and reused on retry.

When the plan is created, stable Step instances and `wait_id`s are assigned, and steps with the same name are distinguished by instance ID/sequence number. The input, output and signal payload of every node must have a contract and a size limit.

The two planning modes `run/3` and `advance/3` are chosen explicitly, one or the other, per operation. `advance/3` can return `{:step, name, input}`, `{:wait, wait_spec}`, `{:done, output}` or `{:error, error}`; the advancement decision and the new node are persisted in the same transaction, and a committed decision cannot be re-executed on recovery. The operation declares `planning: :dynamic` (`Fyrlet.Runs.operation/2`) and the definition implements `advance(operation, state, event)`; `state` contains `input`, the `outputs` of completed nodes, `run_id`, `project_id` and `initiator_subject_id`; `event` is `:start`, `{:step_succeeded, name, output}`, `{:wait_satisfied, name, payload}` or `{:wait_timed_out, name}`. The business key and the expiry are provided by the optional `plan_options/3`. Dynamic nodes go through the same validation as static nodes, and the total node count is bound by the same limit; if `advance/3` raises, the run is terminated with `ADVANCE_CRASHED`, and the exception content is not leaked.

## State and data

Tables:

| Table | Main fields |
| --- | --- |
| `fyrlet_runs` | id, project_id, subject_id, operation, business_key, definition_version, plan, execution_grant_id, status, wait_reason, version, input, output, error, current_step, cancel_deadline, cancellation_outcome, started_at, finished_at, expires_at |
| `fyrlet_run_steps` | id, run_id, type, name, seq, status, input, output, wait_id, wait_deadline, wait_timeout_action, current_attempt, error, started_at, finished_at |
| `fyrlet_run_attempts` | id, step_id, attempt, execution_epoch, lease_id, lease_expires_at, status, error, started_at, finished_at |
| `fyrlet_run_signals` | id, run_id, wait_id, name, payload, idempotency_key, input_hash, status, received_at, consumed_at |
| `fyrlet_run_events` | id, run_id, step_id, type, payload, seq, created_at |
| `fyrlet_execution_grants` | id, project_id, initiator reference, execution subject, operation and resource scope, expires_at, revoked_at |

Run state machine:

```text
pending → running ⇄ waiting
running → completed
pending | running | waiting → failed
pending | running | waiting → cancelling → cancelled
pending | running | waiting → expired
cancelling → expired
```

Entry conditions of each state:

| Transition | Condition |
| --- | --- |
| `→ failed` (from `pending`/`waiting`) | The execution grant is revoked or expired (see "Execution identity and code version" below), `definition_unavailable` has not recovered after `definition_unavailable_ttl` (default 1 hour), a wait node timed out with `wait_timeout_action: :fail`, or retries are exhausted |
| `waiting → running` | A signal is consumed, or a wait node times out with `wait_timeout_action: :continue` (the payload is a `timeout` marker so that later Steps can tell the cases apart) |
| `cancelling → expired` | The Run reaches `expires_at` before the cancellation deadline: it is handled as the `expired` terminal state and keeps `cancellation_outcome: fenced_timeout`, without waiting any longer for executor confirmation |
| `wait_reason` of `waiting` | `signal` (waiting for a user/integration signal), `effect` (waiting for an Effect result), `definition_unavailable` (the definition version is missing, scheduling is paused) |

A wait node must declare `wait_timeout_action` (`:fail` | `:continue`, default `:fail`); the expiry decision and signal consumption compete for the same state lock (see "Signals, cancellation and intervention" below).

Step and Attempt states:

| Object | States | Description |
| --- | --- | --- |
| Step | `pending` → `running` → `succeeded` \| `failed` \| `cancelled` | Work node; while `running` it can be suspended as `awaiting_effect` and then return to `running` or enter a terminal state |
| Step (wait) | `pending` → `waiting` → `satisfied` \| `timed_out` \| `cancelled` | Wait node; it no longer changes after `satisfied`/`timed_out` |
| Attempt | `leased` → `succeeded` \| `failed` \| `abandoned` | `abandoned` means the lease was lost or the attempt was fenced off by cancellation; an Attempt's terminal state cannot be rewritten |

After a Step returns an Effect intent it enters `awaiting_effect`: the lease of the current Attempt is **released** (`succeeded`, annotated `effect_pending`), and later advancement is driven by the Effect state; the dispatch ownership of the Effect (`lease_id`/`execution_epoch`, see [EFFECTS.md](EFFECTS.md)) is independent of the Step Attempt. When an Effect result is committed, it is still checked that the Run is not in a terminal state.

Constraints:

- The current Run/Step state is the source of truth for advancement; an Event is an audit record written in the same transaction. No execution model that rebuilds state by replaying all events is introduced.
- Row locks, conditional updates and unique constraints protect state transitions; each Run has at most one currently valid Step execution owner. On claim, a lease and an incremented `execution_epoch` are persisted, and a result commit must match the current epoch, the lease and the Run state.
- An old executor whose lease has expired may still keep running, but it cannot commit state or advance the Run. The framework does not promise that code outside the transaction is never executed twice; a Step whose completion has been persisted is not re-run, while an attempt whose completion was not confirmed may be re-run.
- The unique constraints cover at least `(run_id, seq)` on the Step table, `(step_id, attempt)` on the Attempt table, `(run_id, seq)` on the Event table and `(run_id, idempotency_key)` on the Signal table. The signal payload hash covers the wait instance, the name and the payload. The Event sequence number is assigned in the transaction that locks the Run, and a cross-transaction auto-increment ID is not used to infer commit order.
- The Step output, the next node, the associated business changes and follow-up jobs are written atomically through the managed commit interface; independent Repo writes issued by a Step on its own do not automatically get this guarantee. No external call is wrapped in a transaction.
- Retries have a maximum count, backoff, a total run deadline and a classification of retryable errors. Exceeding the limit enters `failed` and keeps the committed outputs; a retry does not regenerate the identity of an Effect that already exists.
- `expires_at` is the run deadline, not a data deletion time. On expiry the execution epoch is invalidated and the Run enters `expired`, rejecting new signals and further advancement; the real outcome of Effects that were already dispatched must still be recorded and reconciled.
- `completed`, `failed`, `cancelled` and `expired` do not advance any more; a late result may append an audit record but cannot rewrite the terminal state.

## Execution strategies

The framework only defines "who executes a step"; the execution method is pluggable:

| Strategy | Use | Description |
| --- | --- | --- |
| `:oban` | Default, all work Steps | Oban handles waking and queuing, and the Run state table decides whether to execute; duplicate or late jobs must exit safely |
| `:local` | Consecutive execution of short Steps | Also obeys the lease and epoch checks; it cannot rely on in-memory Task state alone |
| `:external` | Specific languages and heavy computation | Uses the lease of the external executor protocol below; user code is not hosted |

`:oban` is the default. `:local` is implemented with the configuration `runs: [local_chain: n]`: one wake-up executes at most n steps in a row, each step still claims its own lease and commits independently, and the handling of crashes or late results is unchanged. The business retry state is defined by the Run/Attempt records, and an Oban job redelivery cannot additionally consume or reset the business retry count. The recovery scanner checks expired leases and missing wake-up jobs, and does not depend on a process being alive or on a single notification.

## Signals, cancellation and intervention

The framework provides three user entry points (user token + `X-Project-Id`); a Webhook calls the same core API through an authenticated, restricted integration principal:

| Entry point | Semantics |
| --- | --- |
| `POST /api/v1/runs/:run_id/signals` | Persists `{wait_id, name, payload, idempotency_key}` and returns a signal receipt; acceptance and consumption are separate |
| `POST /api/v1/runs/:run_id/cancel` | Idempotently accepts a cancellation and returns the current status and the cancellation deadline |
| `GET /api/v1/runs/:run_id` | Reads the run, step summaries and recent events (bounded) |

Permissions are decided by `run_authorize/4`, with the actions `:view` / `:signal` / `:cancel` / `:start`. The owning project of the Run, the current caller, the signal payload and the target wait node all take part in the check. The signal and cancel entry points are rate-limited per "project + caller + Run" and return `LIMIT_EXCEEDED` when exceeded; rejected and rate-limited requests are also counted in `fyrlet.run.signal`.

Signal semantics:

- For a registered `wait_id` that is not closed, a signal is allowed to arrive before the Run enters `waiting`; it is written to the inbox first and consumed after the Run enters that wait node. Successful acceptance does not mean the Run has advanced.
- The inbox insert, the idempotency result and the wake-up job are committed atomically; consuming the signal, closing the wait node and advancing the state are also committed atomically. A wait instance consumes only one valid signal.
- The same idempotency key with the same payload returns the same receipt, and a different payload returns a conflict. A wrong name, an unknown wait instance, and a new signal for a terminal Run or a closed wait instance are rejected; replaying a successful receipt does not consume again.
- The wait deadline and a signal compete under the same state lock; a wait node that has already timed out cannot be revived by a late signal. A dynamic wait must register its `wait_id` first and only then dispatch the external request that may produce a receipt.

Cancellation semantics:

- Cancellation competes with result commits and Effect dispatch claims for the same state lock. Once accepted, no new Step is claimed, no signal is consumed and no later Effect is claimed; Effects not yet claimed are marked `cancelled`. An Effect whose claim transaction has already committed is treated as an in-flight request, even if the external call has not yet returned.
- When no work is executing, it can finish immediately; when work is executing, the Run enters `cancelling`, requests cooperative stop, and sets `cancel_deadline` (default 60 seconds, configurable).
- **In-flight Effects do not block the cancellation terminal state**: the Run enters `cancelled` once the executor confirms or the deadline is reached, without waiting for claimed Effects to return; the Effects keep recording their real outcome (including `unknown`) according to [EFFECTS.md](EFFECTS.md), and are shown separately in the run view. The SDK must still show the status of unsettled Effects on a `cancelled` Run.
- After executor confirmation it enters `cancelled` with `cancellation_outcome: confirmed`; if there is still no confirmation at the deadline, the lease and epoch are invalidated and the Run ends, marked `fenced_timeout`. The latter only means that further advancement is forbidden, not that the external code has stopped.
- A late result after cancellation is only recorded and does not invoke the advancement logic. Side effects that were already dispatched may still complete, and the Effect keeps recording the real outcome; revocation or compensation must be a separate, explicit business operation.
- The SDK distinguishes "cancellation accepted", "stop confirmed" and "advancement forbidden after timeout", and must not present all three as the external work having stopped.

## Run view (core subscriptions)

The framework registers built-in subscriptions, so applications do not need to implement them again:

| Name | Parameters | Output |
| --- | --- | --- |
| `fyrlet.run` | `run_id` | Run status, Step summaries, wait reason, cancellation outcome, Effect summaries, the latest N events and the paging position of the history |
| `fyrlet.runs.recent` | `limit` | The recent runs visible to the current Actor |

The run view uses a complete bounded snapshot and reuses the invalidation notification, ACK and reconnect-refetch paths. Any visible change to a Run/Step/Effect should trigger a refresh; once events and Step history exceed the limit they are read by paging, so that a long task cannot break the snapshot size limit.

`fyrlet.runs.recent` must apply visibility filtering in the query stage before paging; it must not first read all Runs of the project and filter them on the client. Incremental delivery of high-frequency logs uses append subscriptions, see [STREAMS.md](STREAMS.md).

## External executor protocol

An external executor is responsible for claiming, renewing leases, reporting results and responding to cancellation, reusing the core execution ownership rules:

- A claim returns the fixed input, the definition version, `attempt_id`, `lease_id`, `execution_epoch` and the expiry time.
- Lease renewal and result reporting must carry the current lease and epoch; an expired, cancelled or replaced lease cannot advance state. **Expiry takes effect immediately**: as soon as `lease_expires_at` has passed, the heartbeat (no longer renews), the status query (returns `lease_valid: false` and requires a stop) and the result report (returns `LEASE_LOST` and records only an `attempt.late_result` audit event) are all rejected at once, without waiting for the recovery scan or takeover to happen first. The trade-off: when an executor has finished the work but its lease has expired and the recovery scan has not yet taken over, that result is discarded and the work is redone. In-process (`:internal`) steps do not send heartbeats and are not subject to this; they are still handled by the recovery scan.
- Reporting the same result again for the same attempt is idempotent; a different result conflicts. A result from a caller without permission or with an expired lease must not be treated as a valid completion.
- The executor long-polls for the cancellation marker; after a cancellation is accepted the execution lease is not extended, and losing contact is handled according to the cancellation deadline.
- Executor credentials are limited by project, queue and capability and can be revoked individually; they may only claim authorized work and are not equivalent to a user identity.

The transport is HTTP, and the cancellation marker uses long polling. The capability `executors` (server configuration) is required. The executor credential `rtx_…` (`Fyrlet.Features.Executors.create/3`) is bound to a project and queues, can be revoked individually, and is not a user token. An operation routes steps to queues with `executor: %{"default" => "queue", "step name" => "queue"}`; in-process workers do not claim steps that have a queue.

| Endpoint | Purpose |
| --- | --- |
| `POST /api/v1/executor/claim` `{queues}` | Claims one step and returns `attempt_id`, `lease_id`, `execution_epoch`, `input`, `definition_version` and `lease_expires_at`; when there is no work, `data` is `null` |
| `POST /api/v1/executor/attempts/:id/heartbeat` `{lease_id, epoch}` | Renews the lease; after a cancellation is accepted it is no longer extended and returns `cancel: true` |
| `GET /api/v1/executor/attempts/:id?lease_id=&epoch=&wait=` | Long-polls the cancellation marker (`wait` at most 25 seconds); when the lease is no longer valid it returns `cancel: true, lease_valid: false` |
| `POST /api/v1/executor/attempts/:id/result` `{lease_id, epoch, status, output \| error}` | Reports a result once; reporting the same result again returns `duplicate`, a different result conflicts; a lost lease returns `LEASE_LOST` (409) |

An executor can claim only steps of its own queues and its own project, and can operate only on attempts it holds. The server neither hosts nor runs executor code.

## Execution identity and code version

- When a Run is created, the initiator and an execution grant reference persisted by the core are recorded, limited to the project, operation, resource scope and duration; the original user token is neither stored nor reused.
- The execution grant's duration defaults to `min(the Run's expires_at, the grant policy maximum)`; if at creation the grant duration is shorter than the total wait time of the Run's plan, creation is rejected (`VALIDATION_FAILED`), so that a long-waiting Run does not fail midway because its grant expired first.
- Natural expiry of the user session does not automatically cancel an accepted Run. The execution grant is re-checked before each claim of a new Step or Effect dispatch claim; after the grant is revoked, new work is rejected and the Run fails. Requests already executing externally must still be recorded by their real outcome.
- Viewing, delivering signals and cancelling are still re-authorized against the current caller. An executor credential only grants the ability to execute the specified attempt and does not expand the Run's business permissions on its own.
- A Run pins its `definition_version` and associates the applicable Step input/output contracts and implementation. Pinning requires **explicitly registering** the implementation through `definition_version → implementation`: merely recording a version number while still calling an overridden module of the same name is not version pinning. On upgrade, the implementations and contracts that active Runs depend on are retained. A deployment must retain the versions needed by unfinished Runs; when a version is missing, scheduling stops and an alert is raised with the `definition_unavailable` wait reason, and silently using new code is forbidden.
- Migration of a running Run is not provided; if it is provided in the future, it must explicitly record the old version, the new version, the state mapping and the operator, and must not change existing Runs implicitly by replacing a module.
