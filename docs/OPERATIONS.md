# Operations and capacity

For deployment, configuration options and environment variables see [INSTALL.md](INSTALL.md). This document covers operations entry points, capacity and retention, quotas, observability, failure recovery and multi-node deployment.

## Operations commands

`GET /health` checks process liveness. `GET /ready` checks PostgreSQL with `SELECT 1`, with 1000 ms limits for pool checkout and query execution. It returns 200 when ready, or a sanitized retryable `UNAVAILABLE` / 503 when a connection cannot be used. Both routes are public and uncached. Use `/ready` for load balancers and deployment readiness, and `/health` for liveness; readiness does not inspect migrations, plugins or background job progress.

Automatic retention jobs share `config :fyrlet, pruning: [max_rows: 5_000, max_duration_ms: 1_000]`. Startup validates 1–5000 rows and 1–30000 ms. Jobs stop starting new cleanup work when either budget is exhausted and schedule a continuation after one second. Continuations rotate the starting category to make progress across backlogs. Time is checked between statements, not by interrupting a running transaction. Row counts exclude foreign-key cascades; terminal Run deletion uses batches of at most 100 parents. Stream trimming advances its floor only across deleted entries. The new session expiry index is installed by `mix fyrlet.migrate` on existing databases.

`[:fyrlet, :prune]` reports deleted records, elapsed milliseconds and whether the budget was exhausted. When metrics are enabled, scrape `fyrlet_prune_deleted_total`, `fyrlet_prune_duration_seconds` and `fyrlet_prune_limited_total`. Repeated limited passes indicate cleanup pressure; combine them with database pool waits and storage growth before increasing the budget.

```sh
mix fyrlet.project --output .local/project.json "My App"
mix fyrlet.contract priv/contract.json
mix fyrlet.revoke_key KEY_ID
mix fyrlet.prune
```

The project output file has permissions 0600, and an existing file is refused rather than overwritten. prune can be run on a schedule by the deployment environment. Key management commands belong to the trusted control plane; no HTTP interface for managing projects or keys is currently exposed.

The key limits include max_subscriptions, max_subscriptions_per_node, max_observers, max_snapshot_bytes, max_channel_queue (checked against the view owner's mailbox), snapshot_ack_timeout, reconciliation_interval, socket_batch_max_messages, socket_batch_max_bytes and idempotency_ttl. PostgreSQL statement_timeout controls a single database statement; arbitrary Elixir CPU work has no general enforced isolation timeout, so callbacks should stay short.

`max_subscriptions` defaults to 20 per connection. `max_subscriptions_per_node` defaults to 10,000 active subscription, append and Presence channels combined, configurable with `FYRLET_MAX_SUBSCRIPTIONS_PER_NODE` (1–1,000,000). Tracker enforces node, connection and project limits and releases slots when channels exit. `max_observers` separately limits shared Observer processes to 10,000 by default. Private subscriptions run in their Channel and consume no Observer process. These ceilings protect resources and do not establish node capacity.

A subscription contract may declare `"max_snapshot_bytes" => 32_768`, up to the configured global ceiling (256 KiB by default). Startup validation rejects invalid budgets; initial attach, recomputation and explicit refresh check actual snapshots. Oversized data returns `LIMIT_EXCEEDED` without truncation. This covers private, shared and append snapshots; append batches retain their separate stream flow-control limits.

- `mix fyrlet.runs`: stalled runs; `mix fyrlet.effects`: side effects that are unknown, awaiting manual action, or overdue for dispatch; `mix fyrlet.plugins`: plugin, capability and migration status.
- The recovery scanner (`Fyrlet.Runs.Recovery`) repairs expired leases, missed wake-ups, wait timeouts, cancellation deadlines, run expiry, authorization revocation and missing definitions; it reads only the database and does not depend on a process being alive or on a single notification. It starts automatically with the application when the `runs` capability is enabled.
- The cleanup job (every 10 minutes) deletes expired idempotency records, expired sessions, expired anonymous principals, terminal runs past their retention period, and webhook deduplication records; it **does not** delete active runs, runs that still have pending side effects, or their necessary facts.

## Data retention and capacity

For which job cleans each table and how long rows are kept, see [DATABASE.md](DATABASE.md#cleanup-and-retention); the retention period of ingested data can be set per project, see [Per-project retention](DATABASE.md#per-project-retention).

Every write produces one idempotency result row (including the complete return value) and one Oban fallback job. At a rough 500 writes/s (measured on a small table at about 1 KB per row including indexes; actual numbers will differ): with idempotency results kept for 24 hours the steady state is about 43 million rows and about 40 GB; with Oban jobs kept for 1 hour it is about 1.8 million rows. Choose the retention period according to the retry window of your application:

- `idempotency_ttl` (seconds, default 86400) or the environment variable `FYRLET_IDEMPOTENCY_TTL_SECONDS`: how long idempotency results are kept, which equals the window in which a client can safely retry the same Idempotency-Key. Shortening it shrinks the table, but a retry beyond the window is treated as a new request and executed again.
- `durable_invalidation` (`false` by default) or the environment variable `FYRLET_DURABLE_INVALIDATION=true`: whether every Operation write persists a fallback invalidation job in its transaction. Off, the invalidation is broadcast right after commit and the write issues about five fewer statements (insert, insert notice, fetch, completion). The trade-off: if the node dies after the commit but before the broadcast, no job re-broadcasts it, and subscribers catch up at their next periodic reconciliation (`reconciliation_interval`, 30 s by default) instead. Turn it on when that window matters more than write throughput. Invalidations raised through `Fyrlet.AfterCommit` (for example by Runs) are always durable, and so are writes nested in a plain `Repo.transaction` (use `Fyrlet.Transaction.run/1` to get the cheaper path).
- Expired idempotency results and sessions expired for more than 24 hours are cleaned in batches (5000 rows per batch) by `Fyrlet.PruneWorker` every 10 minutes; `mix fyrlet.prune` can still be run manually.
- Completed Oban jobs are cleaned by the `pruner`: kept for 1 hour, at most 50000 deleted every 10 seconds. Oban's default is at most 10000 deleted every 30 seconds, so cleanup cannot keep up once sustained writes exceed about 333 per second; this is why the value was raised here.
- `POOL_SIZE` sets the database connection pool size (default 10, range 1–10000). A write transaction holds a connection for the entire transaction. Measured (800 writes/s, application at 1 vCPU, 6 runs each), 10 and 30 showed no measurable difference in completed writes, CPU or P95; see the “Connection pool size” section of [OPTIMIZATIONS.md](OPTIMIZATIONS.md). Whether this changes at higher write rates or with a slower database was not tested; increase it when connection queuing appears.

## Project quotas (`Fyrlet.Quota`)

Limits the operation call rate and the number of simultaneously open subscriptions per project. **Unlimited by default**; when not configured, behavior is exactly as before.

```elixir
config :fyrlet,
  quotas: [
    default: [reads_per_second: 200, writes_per_second: 50, max_subscriptions: 5_000],
    projects: %{"<project uuid>" => [writes_per_second: 500]}
  ]
```

- The keys are `reads_per_second`, `writes_per_second` and `max_subscriptions`; values are `nil` (unlimited) or a positive integer; a project entry overrides the default key by key. A misspelled key or a non-positive number makes the application fail to start.
- Defaults can also be given through environment variables: `FYRLET_PROJECT_READS_PER_SECOND`, `FYRLET_PROJECT_WRITES_PER_SECOND`, `FYRLET_PROJECT_MAX_SUBSCRIPTIONS` (range 1–1000000). Per-project overrides can only be written in the application configuration.
- **Reads and writes are counted separately**: operations with `kind: "read"` count as reads; writes, Runs and ingestion count as writes. The check happens before dispatch, so a call over the limit does not validate input, does not occupy a database connection and does not produce an idempotency record.
- Exceeding a limit returns HTTP 429, `LIMIT_EXCEEDED`, `retryable: true`, with `details` carrying `scope`, `class`, `limit` and `retry_after_ms`; the HTTP response also carries `Retry-After` (seconds, rounded up). Rejected calls are counted too, so a client that ignores the hint keeps being rejected. Each rejection emits a `[:fyrlet, :quota, :rejected]` telemetry event (metadata includes `project_id` and `class`).
- The subscription limit is counted by the `Tracker` and stacks with the per-connection limit (`max_subscriptions`); reaching the project limit returns a non-retryable `LIMIT_EXCEEDED`, and the slot is released immediately when a subscription is closed.

**Limitations, evaluate as needed:**

- Rates are counted in a **fixed one-second window**. If a client sends its full allowance at the end of one second and again at the start of the next, up to twice the allowance passes across that boundary; within any complete second the limit is not exceeded.
- All counts are **within a single node**. In a multi-node deployment a project has its own allowance on each node, so the total allowance is about the number of nodes times the limit.
- There is no limit on the byte size of read subscription snapshots, nor on storage outside Runs.

## Observability

### Telemetry events

Telemetry events include fyrlet.operation.stop, fyrlet.subscription.query, fyrlet.subscription.snapshot, fyrlet.subscription.delta and fyrlet.subscription.count, plus the events of Ecto / Oban themselves. duration is in monotonic native units, bytes for a snapshot is the JSON byte size of the complete data, bytes for a delta is the JSON byte size of the patch (excluding the event envelope), and active is the number of subscriptions currently on this node. Logging of Phoenix connection parameters and channel parameters is off by default, business exceptions are logged by exception type only, and the client receives a uniform error.

The fyrlet.auth.batch event contains duration, requests (number of requests in the batch) and sessions (number of sessions after deduplication); metadata.result indicates whether the query succeeded or failed. fyrlet.transport.batch contains messages and bytes (the sum of the bytes of the aggregated Phoenix frames, excluding the batch envelope). With the default Phoenix JSON serializer and Jason, snapshots and deltas can reuse the JSON already encoded by the Observer; other serializers or JSON libraries keep the ordinary data push path.

Events for Runs, Effects and plugins:

| Event | Key fields |
| --- | --- |
| `fyrlet.run.stop` | operation, status, duration, steps |
| `fyrlet.run.step` | name, status, attempt, duration |
| `fyrlet.run.recovery` | reason, expired_leases, rescheduled, stale_results |
| `fyrlet.run.signal` | accepted / consumed / duplicate / rejected, wait_age |
| `fyrlet.run.cancel` | confirmed / fenced_timeout, duration |
| `fyrlet.effect.stop` | adapter, status, attempt, unknown |
| `fyrlet.effect.reconcile` | adapter, age, outcome, resolution_required |
| `fyrlet.run.queue` | queue age (oldest Step awaiting claim), queued count, concurrency in use aggregated per project |
| `fyrlet.run.wait` | number of wait nodes whose signal is overdue, `definition_unavailable` count |
| `fyrlet.delta.snapshot_fallback` | name, reason (gap / overflow / refresh) |
| `fyrlet.scope.shared` | members, metadata name, mode |
| `fyrlet.subscription.serialize` | duration and bytes of the actual snapshot data encoding, metadata name, mode; excludes the per-connection protocol envelope encoding |

There are also `fyrlet.subscription.append` (bytes and item count of an append batch), `fyrlet.ops.status` (`alerts`, `stuck_runs`, `queue_age_seconds`, `unresolved_effects`) and `fyrlet.ops.alert` (`firing` 1/0, metadata `name`, `severity`). `fyrlet_ops` alerts notify only on state transitions (`FyrletOps.AlertHandler`), and the alert content does not include Run/Effect IDs. `fyrlet.run.queue` is emitted during the recovery scan according to the global and per-project maximum lease counts, and carries no high-cardinality labels such as Run IDs.

It must be possible to locate: which Step a Run is stopped at, what state a side effect is in, and whether an append subscription has ever fallen back to a snapshot.

### Prometheus metrics (`Fyrlet.Metrics`)

`GET /metrics` outputs the Prometheus text format. **Off by default**: the route is started, recorded and exposed only when a token is configured (`config :fyrlet, metrics: [token: "…"]` or the environment variable `FYRLET_METRICS_TOKEN`, at least 16 bytes, otherwise startup fails). Scrape with `Authorization: Bearer <token>`; the token is compared in constant time; when not enabled, or the token is missing or wrong, the same 404 is returned, so the existence of the endpoint is not disclosed. The route shares the business port, so in production also restrict the source with a gateway.

Recording is a single atomic ETS update in the process that emits the event, with no messages and no locks. All counts are **within a single node** and are summed across nodes by Prometheus. **Labels are bounded**: an operation name is used only if it is registered in the contract, otherwise it is recorded as `_unknown` (the name in `operation.stop` comes from the client request, and without this limit random names would exhaust memory); there are no project or user labels.

| Metric | Type | Description |
| --- | --- | --- |
| `fyrlet_operations_total{name,result}` | counter | Operation calls |
| `fyrlet_operation_duration_seconds{name}` | histogram | Operation duration |
| `fyrlet_subscription_queries_total{name,result}`, `…_query_duration_seconds{name}` | counter / histogram | Subscription data fetches |
| `fyrlet_snapshots_total`, `fyrlet_snapshot_bytes_total`, `fyrlet_deltas_total`, `fyrlet_delta_bytes_total` (`{name}`) | counter | Snapshots and deltas delivered |
| `fyrlet_append_batches_total`, `fyrlet_append_items_total` (`{name}`) | counter | Append batches |
| `fyrlet_snapshot_serializations_total{name,mode}` | counter | Number of complete snapshot encodings by the Observer |
| `fyrlet_snapshot_fallbacks_total{name}` | counter | Fallbacks to a complete snapshot |
| `fyrlet_subscriptions_active` | gauge | Subscriptions open on this node |
| `fyrlet_observers` | gauge | Observers running on this node |
| `fyrlet_session_check_batch_size`, `…_duration_seconds` | histogram | Batch size and duration of batched session checks |
| `fyrlet_transport_batches_total`, `fyrlet_transport_batched_messages_total` | counter | Socket multi-frame batching |
| `fyrlet_quota_rejected_total{class}` | counter | Project quota rejections |
| `fyrlet_db_queue_seconds`, `fyrlet_db_query_seconds` | histogram | Database connection pool queue time and query time |
| `fyrlet_vm_processes`, `fyrlet_vm_memory_bytes`, `fyrlet_vm_run_queue` | gauge | BEAM state |

Signals worth watching (thresholds must be set for your own load; there are no verified defaults here):

- A rising high percentile of `fyrlet_db_queue_seconds`: the connection pool is insufficient; this, not guesswork, is the basis for increasing `POOL_SIZE`.
- `fyrlet_session_check_batch_size` staying at 1: batching is not taking effect, and session checks are going to the database one by one.
- `fyrlet_snapshot_fallbacks_total` growing: delta negotiation failed or the window overflowed, and downstream traffic will grow.
- `fyrlet_quota_rejected_total` growing: a project is hitting its quota; adjust the quota or investigate the client.
- `fyrlet_vm_run_queue` staying above 0: the schedulers are saturated.

## Run limits and data protection

All can be overridden with `config :fyrlet, runs: […]`: 50 nodes per run, 64 KiB for node input/output and signal payloads, 3 attempts per step, 60 seconds lease, 30 seconds recovery scan, 7 days default run validity (30 days at most), 30 days retention of terminal runs, 7 days retention of signal deduplication, signal inbox of 50, 1000 queued / 100 concurrent per project, 60 signals per run per minute, Effect dispatch of 50 per second per project, 10000 pending ingestions.

Requirements for runs:

- Concurrent Runs/Steps, queue size and Effect dispatch rate are limited per project; for a single Run, the node count, input/output size, signal inbox, event rate and total storage budget are limited. On reaching a limit, reject, pause or mark as truncated; growth must not be unbounded.
- Run events support batched persistence and bounded reads; high-frequency logs must not trigger a complete Run snapshot per token. Log throttling must not drop state transitions, signal receipts or Effect attempt facts.
- A Run's `input`/`output`, a signal's `payload`, and an Effect's `payload`/`result` may contain personal or business-sensitive data: a definition can declare field-level redaction (logs and events do not contain the original text) and optional encryption at rest, and supports purging by retention period or by subject request; purging must not break idempotency keys, `payload_hash` or the non-sensitive facts needed for auditing.
- Structured logs are correlated through request/run/step/attempt/effect identifiers; credentials and sensitive payloads do not enter logs, and high-cardinality fields such as Run IDs are not used directly as persistent metric labels.
- Run deadline, terminal history retention period, signal deduplication period, Effect reconciliation deadline and event archiving are configured independently. `mix fyrlet.prune` must not delete active Runs, unresolved Effects, logical keys that still need deduplication, or their necessary associated records.
- Recovery, reconciliation and archiving jobs all need alerts on queue age, failures and capacity; the optional `fyrlet_ops` provides status snapshots and alerts, while basic back-pressure and limits are the responsibility of the corresponding run module.

## Transport batching and failure recovery

SocketTransport keeps a single frame as the standard Phoenix five-element array; a multi-frame outbound message is wrapped as `{"batch":[...]}`, preserving frame order. It aggregates only pushes already in the transport mailbox in the same round, and commits them through a self-sent flush message, with no timer waiting to fill a batch. socket_batch_max_messages defaults to 64 and has a hard limit of 64; socket_batch_max_bytes defaults to 256 KiB and is an aggregation budget: a single message over budget is sent alone, not truncated. The 64 KiB limit on inbound Socket frames is separate from the outbound batching budget. A batch may mix different topics; no cross-subscription transaction or atomic visibility is provided; a hand-written client must support this wrapping and must not assume that a native Phoenix decoder can handle it.

A shared Channel monitors its Observer, and when that Observer exits it sends a retryable INTERNAL_ERROR. A private Channel owns its view state; if it exits, the SDK rejoins that topic and receives a fresh snapshot. A failure or timeout of the session-check worker also returns a retryable internal error and does not bypass authentication. After receiving a retryable status the SDK rebuilds the connection and subscriptions and recovers with a complete snapshot of a new generation; it does not replay unacknowledged business writes. When attach hits an Observer call exit it retries once internally and returns a retryable error if it still fails; the SDK also recovers automatically from a retryable error returned on the first join: that subscription enters recovering and is rejoined by the Phoenix channel with backoff (an error is reported only after more than 10 consecutive failures), and other subscriptions on the connection are unaffected; UNAUTHENTICATED still rebuilds the whole connection, and a non-retryable join error fails immediately.

## Runtime tuning

In an early low-load realtime push test on a local M3 Pro, the optional configuration below reduced cumulative CPU consumption. That historical comparison report has been removed, and it was **not re-tested in an environment with the same limits**, so treat it as an option still to be verified:

```sh
ERL_FLAGS='+S 4:4 +sbwt none +sbwtdcpu none +sbwtdio none' \
MIX_ENV=prod mix phx.server
```

This configuration requires an existing production database, keys and the other environment variables. It has not been written into the global defaults; the scheduler count should be re-tested against the deployment CPU budget and actual load. The current results cannot show an improvement in maximum throughput, and low-load latency did not fall in proportion to CPU consumption. The latest same-resource test used container cgroup limits, under which the BEAM automatically enabled only 1 scheduler, and did not use the manual configuration above.

## Optional two-node deployment

A single node remains the default. `FYRLET_CLUSTER_NODES` is a comma-separated list of static Erlang node names, for example `fyrlet_b@node-b.internal`; at most 32, each no longer than 255 bytes, allowing only letters, digits, dots, underscores, hyphens and one `@`. When configured, `Fyrlet.Cluster` is started and tries every second to connect to peers that are not yet connected; an unnamed node is explicitly refused at startup. The node name and cookie are managed by Erlang/the release, not set by HTTP requests.

To verify locally with Mix, first have the two applications use the same database, definitions, plugins and migrations, then run the following separately (replace `<local short hostname>` with the same actual hostname; provide the cookie through the environment):

```sh
FYRLET_CLUSTER_NODES="fyrlet_b@<local short hostname>" PHX_SERVER=true PORT=4200 \
  elixir --sname fyrlet_a --cookie "$FYRLET_CLUSTER_COOKIE" -S mix phx.server
FYRLET_CLUSTER_NODES="fyrlet_a@<local short hostname>" PHX_SERVER=true PORT=4201 \
  elixir --sname fyrlet_b --cookie "$FYRLET_CLUSTER_COOKIE" -S mix phx.server
```

A release uses `RELEASE_DISTRIBUTION=name`, `RELEASE_NODE=fyrlet_a@node-a.internal` and the same `RELEASE_COOKIE`, and writes the actual peer node names in `FYRLET_CLUSTER_NODES`. Nodes must resolve each other's hostnames and allow Erlang distribution traffic, restricted to a trusted internal network. The load balancer must support WebSocket and health checks; after a node terminates, existing connections are reconnected by the SDK and subscriptions are restored, without relying on sticky sessions.

Shared data and execution facts are still persisted in the same PostgreSQL; shared Observers and the append read cache are shared only locally within each node, invalidation propagates across nodes through PubSub, and there is no global in-memory cache. `Fyrlet.Diagnostics.cluster/0` returns this node, the configured peers and the actually connected nodes, for use by trusted operations code. When `FYRLET_CLUSTER_NODES` is not set, no discovery process is started; if the host already has a node discovery mechanism, the host can also keep connecting the nodes.

`bash scripts/cluster.sh` has verified, on two nodes on the same machine: idempotency, shared/append, membership revocation under ordinary invalidation, failover after SIGKILL, node rejoin, durable approval, session renewal and resource cleanup. For detailed results see [ACCEPTANCE.md](ACCEPTANCE.md); multi-host network partitions, production capacity and 24-hour stability have not been verified.
- New configuration: `FYRLET_IDEMPOTENCY_TTL_SECONDS`, `POOL_SIZE`, `FYRLET_CHANNEL_HIBERNATE_MS` (build time).
