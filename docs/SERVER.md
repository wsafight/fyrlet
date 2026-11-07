# Server-side application development

The current application is a runnable reference implementation. The core is in lib/fyrlet, the transport is in lib/fyrlet_web, and the reference application (the inbox) is a separate example application, examples/inbox. For installation and public interfaces see [INSTALL.md](INSTALL.md). Trusted business modules are registered through configuration; dynamic loading of tenant code is not provided.

## Registering definitions

A business module implements Fyrlet.Definition:

| Callback | Responsibility |
| --- | --- |
| contract/0 | Declares operations / subscriptions, input and output schemas, the read / write kind of operations, and the optional shared flag of subscriptions |
| authorize/3 | Operation-level authorization based on the server-side Actor and the normalized input |
| execute/3 | Queries or executes the business logic, returning `{:ok, data, affected_scopes}` or `{:error, %Fyrlet.Error{}}` |
| scope/3 | Returns the internal notification topics the subscription depends on |
| change/4 (optional) | Produces immediate change information from this operation, the Actor, the normalized input and the validated output |
| load_subscription/3 (optional) | From the subscription name, Actor and normalized parameters, returns `{:ok, data, context}` or `{:error, %Fyrlet.Error{}}` |
| update_subscription/5 (optional) | From the subscription name, Actor, normalized parameters, the previous `%Fyrlet.Subscriptions.View{}` and the change, returns a partial replacement, reset, context update, unchanged, or reload |

Register modules in the definitions list in config/config.exs. Callbacks, names, operation kinds and schemas are validated at startup. A complete example is examples/inbox/lib/inbox_example/inbox.ex.

The schema supports closed objects, strings and string enums, boolean, JavaScript safe integers, array, null, anyOf, and the uuid / date-time string formats. It is not full JSON Schema; floating-point numbers, objects with arbitrary properties, references and recursive types are not supported. High-precision business values should use an explicit string encoding.

## Queries and authorization

The Actor's project_id / subject_id / session_id come from the verified session, not from business input. Taking the inbox as an example:

```elixir
from item in InboxExample.Item,
  where: item.project_id == ^actor.project_id and item.subject_id == ^actor.subject_id
```

The database filter above is responsible for row-level data scope. An :ok from authorize only means this business operation may run; it cannot replace the query filter. Holding a record UUID or matching a Scope does not grant permission. Roles and team relationships can be added to the application's own tables and authorize logic; the reference application implements only personal ownership.

Result scope must be bounded. The reference subscription contains only the most recent page, and history is read through the keyset cursor of inbox.history. A snapshot over the limit closes the subscription and returns LIMIT_EXCEEDED; it is not truncated into data that looks complete.

## Observers and sharing boundaries

By default an Observer hibernates its GenServer after 1000 ms idle, compacting the process heap; it resumes when a message arrives, and refresh, authentication and ACK logic run as usual. It can be adjusted with `observer_hibernate_after` or `FYRLET_OBSERVER_HIBERNATE_AFTER_MS`; the environment variable value `infinity` disables hibernation. This is a trade-off between memory and wake-up CPU; a continuously busy Observer does not hibernate.

An Observer's `init/1` only registers notifications and bounded state; the initial business load runs inside this Observer's first attach and is subject to the 15-second call timeout. One slow load does not block the DynamicSupervisor from starting Observers for other sessions. Each node allows at most 10,000 Observers by default, adjustable through `:max_observers`; a new view at the limit is rejected with `LIMIT_EXCEEDED`, while existing shared views can still be attached. This resource protection value is not a verified connection capacity.

Each subscription maintains a normalized View serially through its Observer, and the channel is responsible for each client's generation, seq, ACK and expiry timer. Sharing is enabled only when the subscription's server-side contract explicitly sets `"shared": true`; if absent or any other value, it is not shared; this is not a client join option. `inbox.recent` currently has it enabled.

Sharing uses a node-local Registry / DynamicSupervisor, keyed by `{actor, subscription}`, not by Scope or only project / subject. The full Actor includes project_id, subject_id, session_id and expires_at; the full prepared subscription includes module, name, normalized parameters, specification and scope. Multiple devices of the same session can reuse an Observer when these values are identical; different sessions do not share even with the same project / subject; different nodes do not share. The client topic UUID and delivery are not part of the sharing key, so full and delta clients can reuse the same Observer.

Every full or partial computation re-validates the session and calls `authorize/3` before it starts, and validates the session again after the computation. Every attach also independently performs a session check, business authorization, a second session check and a size check, and does not skip them even when an Observer already exists and a cached snapshot is reused; there is no authorization TTL cache. Attach does not force a fresh query of business data; data freshness is still guaranteed by invalidation notifications, explicit refresh and periodic re-check.

## Transactions and invalidation notifications

Each tenant table keeps project and user filter indexes, and the foreign keys to subject / service key get indexes that begin with the referencing column. Cascading deletes triggered by project deletion, and foreign key checks, can use these indexes; a project-first composite index cannot replace the index needed for queries by subject_id alone.

The execute of a write operation runs inside a framework transaction. The application can use Repo or Ecto.Multi for its own domain data, and returns the list of changed Scopes on success. After output validation passes, the framework writes the idempotency result and the Oban job, and commits everything together. Once the outermost transaction commits, an invalidation notification is broadcast immediately, so subscription refresh need not wait for Oban scheduling; the durable job still runs, covering the cases where the process exits after commit or the immediate broadcast fails. A hit on the idempotency cache does not broadcast again. If the caller has already opened a Repo transaction, the framework cannot know when the outer transaction commits, so it uses only the durable job notification, to avoid broadcasting a write that is not yet committed or is eventually rolled back.

Do not broadcast content early in a callback or produce external side effects that cannot be rolled back. Asynchronous external work should be executed by a separate durable job, which defines its own retry and compensation.

The inbox Scope has the form `projects:<project>:subjects:<subject>:inbox`. The durable job stores only the Scope and the project, and broadcasts `{:invalidated, job_id}`. The immediate notification may broadcast `{:invalidated, job_id, change}`; change is passed only in memory and is not written into the Oban arguments. The Observer keeps the 64 most recent notification IDs and skips durable retries already handled; out-of-order notifications are not dropped by ID magnitude, and once an old ID has been evicted, a replay only triggers a safe refresh. The Observer subscribes to notifications before reading the initial data; multiple pending refreshes in the same round are merged, the partial change hints are discarded, and it falls back to a full load. The durable fallback has no change content and also goes through a full load.

Each Observer has only one reconciliation timer. By default it re-authorizes and does a full load every 30 seconds to repair missed notifications, and this timer is not created per client. Regardless of whether delivery is delta-v1, the same normalized View is maintained; when a full snapshot is needed, the data JSON of the current revision is encoded and cached. When an automatic refresh leaves the visible data unchanged, nothing is pushed and neither the view revision nor the client sequence number increases; a change in the private context does not count as a change in visible data. An explicit refresh reloads, and sends a full snapshot when the requesting client can receive it, even if the data is unchanged.

ACK is maintained independently per client, with at most one unacknowledged update per client; waiting for an ACK does not stop the Observer from computing or pushing to other ready clients, and no per-client patch queue accumulates. After a lagging client sends its ACK, a re-authorized full load is triggered and it catches up with a full snapshot; a delta can be received only if the client has kept up with the previous view revision, has requested delta-v1 and is not forced to refresh. The channel's seq and the Observer's internal revision are not the same counter.

### Normalized View and callbacks

For an array of records with unique string ids, `%Fyrlet.Subscriptions.View{}` maintains records (ID to record), order (ID order), sizes (JSON bytes per record) and bytes (JSON bytes of the complete visible data), and also stores the private context, patch and unchanged. Other data is stored in value and goes through the full load path. `View.data/1` restores the externally visible data; the context does not enter snapshots, deltas or the externally reported byte counts, but the application must limit its size itself and must not treat it as an unbounded cache.

`load_subscription/3` returns `{:ok, data, context}`, and the framework validates the complete output and builds the View; if it is not implemented, it falls back to `execute/3` with an empty context. `update_subscription/5` is called only when a normalized record array exists and there is an immediate change; the fourth argument is the View, not an array-position index or the old metadata map. The return forms are:

| Return value | Meaning |
| --- | --- |
| `{:replace, id, record}` | Replaces the record with an existing string ID; the record's id must match; the element is validated and the byte count and patch are updated |
| `{:reset, data, context}` | Validates the complete output, rebuilds the View and compares changes in visible data |
| `{:context, context}` | Updates only the private context; visible data is unchanged |
| `:unchanged` | Neither data nor context changes |
| `:reload` | Calls the load callback again and validates the complete output |

The optional change callback runs inside the write transaction, only returns information and does not broadcast by itself. A partial update must still be confirmed by the application for project, user, record version, visibility, filter conditions and ordering; an index or change hint is not an authorization credential, and when this cannot be determined it must return `:reload`. The framework attaches internal CommittedChange metadata to the immediate change, but what is passed to the update callback is the change body. Output validation and the JSON byte count are reused only when the replacement record is exactly the same as the validated operation output and the subscription element schema is exactly the same as the operation output schema; otherwise the replacement record is still validated. The metadata does not enter the durable job.

The inbox initial load queries at most `limit + 8` rows and sends only the first limit rows to the client; the remaining at most 8 are kept as a private candidate area in context.reserve, and context.complete indicates whether the known candidates cover the remaining results. For a visible record, inbox.update replaces it locally when previous_version, inserted_at and archived all match; a record in the candidate area is checked the same way and only the context is updated; a body update known to fall after the window and the candidate area can leave things unchanged. Membership changes such as insertion, deletion and archiving read the current record within the Actor-ownership SQL scope, check the change against the version, and then reorder the visible data and the candidate area. On a version gap, a current record inconsistent with the notification, missing trusted context, or a result not fully covered with the candidates exhausted, it reloads; this cannot be taken to mean that all membership changes avoid queries. Merged multiple changes, the durable fallback and the periodic re-check also do a full load.

### Coalescing concurrent session checks

batch_session_checks is on by default. 8 in-node shards receive check requests by session_id, at most 128 requests per batch, and merge database reads for duplicate sessions. It does not cache query results and does not set a timer to wait for a batch to fill: it merges only requests already received before the current round of queries starts, and requests arriving while a query is in progress use a later query. On return it still checks the project, user, revocation mark and current expiry time. Both session checks, before and after snapshot handling, are retained.

The FOR SHARE session lock on writes, and checks inside the caller's transaction, use the current database connection directly, preserving transaction visibility and revocation serialization. batch_session_checks can be set to false in the application configuration to restore per-request queries. A shard exception or wait timeout returns a retryable internal error and does not let an unconfirmed session through.

## Development notes for optional capabilities

For the semantics of each capability see [RUNS.md](RUNS.md), [EFFECTS.md](EFFECTS.md), [STREAMS.md](STREAMS.md), [SHARING.md](SHARING.md) and [PLUGINS.md](PLUGINS.md); for the wire protocol see [PROTOCOL.md](PROTOCOL.md). The following are notes for application development.

### Optional Definition callbacks

| Callback | Purpose |
| --- | --- |
| `run/3`, `step/3` | Statically planned Run: `run/3` returns `{:ok, steps: […], business_key: …, ttl_seconds: …}`, and `step/3` executes one step |
| `advance/3`, `plan_options/3` | Dynamic planning (the operation declares `planning: :dynamic`); an alternative to `run/3` |
| `run_authorize/4` | Authorizes `:start`, `:view`, `:signal`, `:cancel`; by default only the initiator may |
| `definition_version/1`, `implementation/2` | Pin the definition version a run uses; when the version is missing the run is paused as `definition_unavailable` |
| `data_scope/3` | Row-level policy for managed data access |
| `shared_query/3`, `membership/3`, `policy_version/1` | Shared subscriptions with `sharing: "identical"` |
| `ingest/3` | Handling of a single item in batch ingestion, executed in the same transaction that completes the item |
| `stream/3` | Append subscription (`mode: "append"`): returns the stream name of `Fyrlet.Features.Stream`, called after `authorize/3` |

Operation kinds: `read`, `write`, `run` (`Fyrlet.Runs.operation/2`), `ingest` (`Fyrlet.Features.Ingest.operation/2`).

### Step return values

`{:ok, output}`, `{:ok, output, commit: fn -> … end}` (managed commit, in the same transaction as the step result), `{:error, %Fyrlet.Error{}}` (retried with backoff when `retryable: true` and `max_attempts` has not been exceeded), `{:effect, %{adapter:, key:, payload:}}` (handed to Effect dispatch). Step output must be an object, with a default limit of 64 KiB.

### Effect retry rules

Based on the capabilities the adapter declares: with an idempotency key, the same `operation_id` is resent within the deduplication window; if it can only be queried, it only reconciles and does not resend even if nothing is found; with neither, an uncertain outcome pauses to wait for a human, unless the step explicitly sets `retry_allow_duplicates: true`. **A side effect with an unknown outcome is never automatically judged to have failed.** Manual resolution uses `Fyrlet.Effects.resolve/5`, which requires an operator and evidence and only appends records; resending requires `acknowledge_duplicates: true` (except when the receiver can still deduplicate).

### Append subscriptions and `Fyrlet.Features.Stream`

A subscription declares `"mode" => "append"`, `"max_items" => n`, `"capability" => "append"`, outputs an array, and implements `stream/3`; the server must enable `capabilities: %{"append" => 1}`. A write operation appends inside `execute/3` (already in a transaction):

```elixir
{:ok, _cursor} = Fyrlet.Features.Stream.append(actor.project_id, "room.#{room}", [%{"text" => text}])
{:ok, result, [scope]}   # Return the affected Scope as usual; subscribers read the new items from it
```

Key points: `append/3` must be called inside a transaction (otherwise it raises `ArgumentError`); the transaction holds the position lock of that stream until commit, so appends to the same stream are numbered in commit order and leave no gaps; an item must be a JSON object (at most 16 KiB, at most 100 per call). **To correct or delete an already published item, call `Fyrlet.Features.Stream.reset/2`** (a new epoch) and do not modify the table directly, otherwise clients will treat the old items as immutable facts. Retention is trimmed by the cleanup job according to `config :fyrlet, :streams, retention_items:` (default 10 000). All members see the same items; for data that must be filtered per member, use a private snapshot subscription.

### Email side effects (`packages/fyrlet_effect_email`)

`config :fyrlet, effect_adapters: %{"email" => FyrletEffectEmail}` and `config :fyrlet_effect_email, provider: MyApp.Mailer, allowed_senders: [...]`. `MyApp.Mailer` implements `FyrletEffectEmail.Provider` (`capabilities/0`, `deliver/2`, optional `status/2`). The adapter is responsible for validating addresses and body, rejecting header injection (custom headers are not accepted), and restricting senders and recipient domains; the provider is only responsible for talking to the service and must honestly declare its idempotency window and whether it can be queried. A provider “accepting” the message is `accepted`, not delivered; delivery and bounces enter through the receipt interface (a bounce is `failed`) or through `status/2` reconciliation. The HTTP adapter works the same way: `{:fyrlet_effect_http, …}`, `config :fyrlet_effect_http, allowed_hosts: [...]`.

### Webhooks (plugin `FyrletWebhooks`)

`config :fyrlet, plugins: [FyrletWebhooks]`, `config :fyrlet_webhooks, sources: %{"billing" => %{project_id:, secret:, handler:}}`; `POST /api/v1/plugins/webhooks/<source>`. Event IDs are recorded in the plugin's own table `webhooks_events` and cleaned by the plugin's own scheduled job according to `retention_seconds`.

### Ops (plugin `FyrletOps`)

`config :fyrlet, plugins: [FyrletOps]`. `FyrletOps.Status.status/1` and `alerts/1` provide bounded status and alerts; `config :fyrlet_ops, thresholds: %{...}, alert_handlers: [Mod], interval_ms: 30_000`; a handler implements `FyrletOps.AlertHandler.handle_alert(:firing | :resolved, alert)`, which is called only on state transitions, and a crash is logged and skipped. `mix fyrlet.ops [--fail-on-alert]` can serve as a scheduled check; project-level status is at `GET /api/v1/plugins/ops/status`.

### Testing your own plugin

`Fyrlet.Testing` provides helpers such as `project/0`, `user/2` and `drive/1`, independent of any test framework; use `Fyrlet.Conformance.Plugin.failures/1` to check a plugin. See `packages/fyrlet_ops/test` for reference.

### Plugins

For the interface and rules see [PLUGINS.md](PLUGINS.md#plugin-api). `config :fyrlet, plugins: […]`; failure of a required plugin prevents startup, while failure of an optional plugin is isolated; use `Fyrlet.Conformance.Plugin.failures/1` to check a plugin in your own tests.

## Code organization

The directories under `lib/` correspond one to one with module names, and the test directory mirrors `lib/`; optional capabilities live in `packages/`, each an independent Mix project.

| Location / namespace | Contents |
| --- | --- |
| `lib/fyrlet/` (root) | Contract and runtime: `Runtime`, `Registry`, `Schema`, `Definition`, `Capabilities`, `Scope`, `Auth`, `Error`; test helper `Testing` |
| `lib/fyrlet/subscriptions/` | Subscription pipeline: `Observer`, `View`, `Delta`, `RecordIndex`, `SessionChecks`, `Tracker` |
| `lib/fyrlet/runs/` | Durable Run: state machine, engine, recovery, executor protocol, limits |
| `lib/fyrlet/effects/` | Outbox: `Effects` (creation, dispatch, reconciliation), `Receipt`, `Resolution`, `Recovery`, `Store`, `Worker`, adapter behaviour `Adapter` |
| `lib/fyrlet/features/` | Optional core features (switched by capability): `Anonymous`, `Ingest`, `Stream` (append subscriptions), `Executors`. They change the principal type, operation kinds, channels or protocol, and can only be defined by the core; they are **not plugins** |
| `lib/fyrlet/plugin*.ex`, `conformance/` | Plugin interface, loading and conformance suite |
| `lib/fyrlet_web/` | HTTP, Socket and channels |
| `packages/fyrlet_webhooks`, `packages/fyrlet_ops` | **Plugins** (`Fyrlet.Plugin`): bring their own migrations, processes, and routes `/api/v1/plugins/<name>/…` |
| `packages/fyrlet_effect_http`, `packages/fyrlet_effect_email` | **Side effect adapter packages** (`Fyrlet.Effects.Adapter`), registered through `effect_adapters` |

To adopt a package: add a path dependency in the host `mix.exs` (for example `{:fyrlet_ops, path: "packages/fyrlet_ops"}`), then add the plugin to `config :fyrlet, plugins: [FyrletOps]`, then run `mix fyrlet.migrate` (plugin migrations run with it). Each package has its own tests: `cd packages/fyrlet_ops && mix test`; `scripts/test_all.sh` runs all suites in one go.
