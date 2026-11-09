# Database

PostgreSQL is the single source of truth for business data, idempotency results, durable jobs and change notifications (for the reasons, see [PRODUCT.md](PRODUCT.md#consistency-and-reliability-commitments)). The authoritative table definitions are in the migration [`priv/repo/migrations/20261106000000_create_fyrlet.exs`](../priv/repo/migrations/20261106000000_create_fyrlet.exs); the Ecto schemas are in `lib/fyrlet/schemas.ex`, `lib/fyrlet/runs/schemas.ex`, `lib/fyrlet/effects/schemas.ex` and elsewhere. This document explains the **design**: why the tables are built this way, which constraints provide which guarantees, and who cleans up. It does not restate every column.

## Conventions

- **Primary keys are UUIDs** (`binary_id`), all times are `utc_datetime_usec`, and JSON uses `map` (`jsonb`).
- **Every tenant table carries `project_id`** and cascades deletes from `projects` (`on_delete: :delete_all`). The first line of project isolation is the `project_id` condition in queries, not database roles.
- **Same-project composite foreign keys**: `(subject_id, project_id)` of `sessions`, `idempotency_results` and `fyrlet_runs` references `subjects(id, project_id)`, and `(service_key_id, project_id)` of `sessions` references `service_keys(id, project_id)`. This is why `subjects` and `service_keys` have a unique index on `(id, project_id)`. It guarantees that the subject and key of a row belong to the same project, so even if application code is wrong it cannot write a cross-project reference.
- **Credentials are stored only as hashes**: `token_hash` in `service_keys`, `sessions` and `fyrlet_executors` is a SHA-256 hash and is unique. The database contains no directly usable token.
- **Hot paths use partial indexes**: only rows in active states are indexed (running Runs, Effects awaiting dispatch, attempts holding a lease, anonymous sessions, and so on), so no amount of terminal-state data slows them down.
- **Event tables are append-only**: `fyrlet_run_events` and `fyrlet_effect_events` assign `seq` under the lock of their parent row and are not rewritten after being written.
- **Places where foreign keys are deliberately omitted**: `fyrlet_execution_grants.initiator_subject_id`, `fyrlet_ingest_*.subject_id`, `fyrlet_run_attempts.project_id` and `fyrlet_stream_entries.project_id` store only the identifier and have no foreign key. This saves foreign-key checks on the write path; isolation is guaranteed by application queries (`fyrlet_run_attempts` is still deleted by cascade with its Run).

## Table overview

| Group | Tables | Purpose |
| --- | --- | --- |
| Identity | `projects`, `service_keys`, `subjects`, `sessions` | Projects, service keys, external identity mapping, short-lived sessions (including anonymous) |
| Idempotency | `idempotency_results` | Idempotency results of writes |
| Run | `fyrlet_execution_grants`, `fyrlet_runs`, `fyrlet_run_steps`, `fyrlet_run_attempts`, `fyrlet_run_signals`, `fyrlet_run_events` | State, steps, leases, signals and audit events of durable runs; see [RUNS.md](RUNS.md) |
| Effect | `fyrlet_effects`, `fyrlet_effect_events` | Intent and attempt records of external side effects; see [EFFECTS.md](EFFECTS.md) |
| Executor | `fyrlet_executors` | External executor credentials and queues |
| Ingest | `fyrlet_ingest_batches`, `fyrlet_ingest_items` | Acceptance records of batch ingestion |
| Append stream | `fyrlet_streams`, `fyrlet_stream_entries` | Stream positions and entries of append subscriptions; see [STREAMS.md](STREAMS.md) |
| Job queue | `oban_jobs`, `oban_peers` | Oban tables, created by `Oban.Migration` |

Reference relationships (indentation means "references the level above"):

```text
projects
├─ service_keys
├─ subjects
│   ├─ sessions                 (also references service_keys; anonymous sessions have no service key)
│   ├─ idempotency_results
│   └─ fyrlet_runs              (also references fyrlet_execution_grants)
├─ fyrlet_execution_grants
├─ fyrlet_runs
│   ├─ fyrlet_run_steps
│   │   ├─ fyrlet_run_attempts
│   │   └─ fyrlet_effects ─ fyrlet_effect_events
│   ├─ fyrlet_run_signals
│   └─ fyrlet_run_events
├─ fyrlet_executors
├─ fyrlet_ingest_batches ─ fyrlet_ingest_items
└─ fyrlet_streams           (fyrlet_stream_entries is linked by project_id + stream, without a foreign key)
```

## Identity and sessions

- **`subjects`**: maps an external identity to an internal subject; `(project_id, issuer, external_id)` is unique. A client cannot choose its own subject.
- **`sessions`**: `kind` is `user` or `anonymous`. An anonymous session has no service key, so `service_key_id` may be null. `expires_at` marks expiry and `revoked_at` marks revocation; `sessions_anonymous_index` (anonymous sessions only, on `inserted_at`) supports the issue-rate count and `sessions_anonymous_active_index` (anonymous and unrevoked, on `expires_at`) supports the active-count of the anonymous entry point. A write transaction takes a `FOR SHARE` lock on the session and revocation takes an update lock, so after a revocation returns, the old session can no longer commit writes (see [AUTH.md](AUTH.md#authorization-and-isolation)).
- **`service_keys`**: `revoked_at` only stops new sessions from being issued; it does not affect existing sessions.

## Idempotency

`idempotency_results` is unique on `(project_id, subject_id, operation, key)` and stores the hash `input_hash` of the normalized input and the full return value `result`. The same key with the same input replays the original result, and a different input returns a conflict; concurrent submissions rely on this unique constraint to guarantee at most one write. `expires_at` is indexed for cleanup. It is committed in the same transaction as the business data and the Oban job.

## Run

- **`fyrlet_runs`**: `status` drives the state machine; `execution_epoch` is incremented each time a step is claimed, and results from an old executor are isolated by it; `event_seq` and `current_step_seq` are the counters that assign sequence numbers to events and steps. The **partial unique index on `(project_id, operation, business_key)` covers only non-terminal** Runs, so "only one active Run per business key at a time" holds, and a finished Run does not block creating a new one.
- **`fyrlet_run_steps`**: `(run_id, seq)` is unique; a non-null `queue` means the step is handed to an external executor, and the corresponding partial index contains only steps awaiting claim; wait nodes use a partial index on `wait_deadline` to find timeouts.
- **`fyrlet_run_attempts`**: one lease per attempt (`lease_id`, `lease_expires_at`, `execution_epoch`). `project_id` is **deliberately redundant**: "how many leases does this project hold now" is asked before every claim, and with it the system-wide leases do not have to be joined with Runs; the partial index on `(project_id, lease_expires_at)` contains only rows that hold a lease.
- **`fyrlet_run_signals`**: `(run_id, idempotency_key)` is unique, and replaying the same key returns the same receipt.
- **`fyrlet_execution_grants`**: the execution grant recorded when the Run is created; it does not store the user token.

When a Run is deleted, its steps, attempts, signals, events and Effects are deleted by cascade.

## Effect

`fyrlet_effects` is unique on `(step_id, effect_key)`, so the same side effect of the same step is not created twice; `operation_id` is the stable idempotency key sent to the receiver. `fyrlet_effects_open_index` contains only rows in `pending / claimed / accepted / unknown`, and dispatch and reconciliation use it to find work. `fyrlet_effect_events` records every attempt and manual decision, and the partial unique index on `(effect_id, receipt_id)` ensures the same receipt is recorded only once.

## Executors, ingest and append streams

- **`fyrlet_executors`**: the credential hash is unique, and `queues` limits the queues it can claim from.
- **`fyrlet_ingest_items`**: `(project_id, subject_id, operation, item_key)` is unique; "one key, one record" makes resending a batch harmless. `fyrlet_ingest_pending_index` contains only pending items, and `fyrlet_ingest_finished_index` contains only processed items, ordered by processing time, for retention-period cleanup.
- **`fyrlet_streams`**: composite primary key `(project_id, name)`, one row per stream. `head` is the last assigned position; an appender holds the lock on this row until commit, so positions become visible in commit order and no gaps appear; `epoch` changes when the stream is rewritten, which invalidates all earlier cursors; `trimmed_before` is the boundary of positions that have been trimmed.
- **`fyrlet_stream_entries`**: composite primary key `(project_id, stream, pos)`; `bytes` records the entry size for the window budget.

## Cleanup and retention

`Fyrlet.PruneWorker` (an Oban scheduled job, every 10 minutes) uses bounded batches and a shared row/time budget. A limited pass schedules continuation with a rotated starting category. Duration is checked between statements; it does not interrupt running SQL, and row accounting excludes foreign-key cascades. Configuration and metrics are in [OPERATIONS.md](OPERATIONS.md).

The single pre-release core baseline includes the expiry, session-issue-rate and hot-path indexes, including `sessions.expires_at`. Databases that ran the earlier split migrations must be recreated; no in-place compatibility migration is provided.

| Table | Cleanup condition | Notes |
| --- | --- | --- |
| `idempotency_results` | `expires_at` has passed | Default retention period is 24 hours (`idempotency_ttl`), which is the window in which a client can safely retry the same key |
| `sessions` | `expires_at` passed more than 24 hours ago | |
| `subjects` (anonymous only) | Issuer is `anonymous` and there is no unexpired session (within 24 hours) | Its sessions are deleted by cascade with the subject |
| `fyrlet_runs` and their child tables | Terminal state and `finished_at` older than `terminal_retention` (default 30 days) | **A Run that still has an unresolved Effect is not deleted** |
| `fyrlet_run_signals` | Signals of terminal Runs, older than `signal_retention` (default 7 days) | |
| `fyrlet_execution_grants` | No longer referenced by any Run | |
| Run input and output payloads | `payload_retention` (not enabled by default) | Removes only the content; keeps identifiers, status, timestamps, hashes and audit events |
| `fyrlet_stream_entries` | Keep the latest `retention_items` entries per stream (default 10 000) | |
| `oban_jobs` | Oban's pruner (completed jobs kept for 1 hour) | |
| `fyrlet_ingest_items`, `fyrlet_ingest_batches` | Item is processed (`done` / `dead`) and older than `ingest_seconds` (default 7 days, overridable per project, `nil` keeps forever); a batch is deleted together once its items are gone | **A pending (`pending`) item is never deleted, however old.** This retention period is also the window in which a resent batch is still recognized as a duplicate; after it, the same keys are treated as new data |
| `fyrlet_stream_entries` (when a project is deleted) | **Does not cascade** | It has no foreign key to `projects`; deleting a project requires cleaning this table as well |
| `fyrlet_executors`, `service_keys`, `subjects` of real users | Not cleaned up | Revocation only sets `revoked_at` |

### Per-project retention

Retention has a global default and can also be set for individual projects (`Fyrlet.Retention`):

```elixir
config :fyrlet,
  retention: [
    default: [ingest_seconds: 604_800],                       # Default: 7 days for all projects
    projects: %{
      "7c1f…" => [ingest_seconds: 86_400],                    # Keep this project's data for 1 day
      "9a2e…" => [ingest_seconds: nil]                        # Keep this project's data forever
    }
  ]
```

A project entry overrides only the keys it writes; unwritten keys use the default. `nil` means keep forever (as a default value it means cleanup is turned off); the number of seconds must be at least 60, and a wrong value makes the application fail to start. The default can also be set with the environment variable `FYRLET_INGEST_RETENTION_SECONDS` (a number of seconds or `forever`). Per-project overrides can only be written in application configuration.

**Currently only the ingest retention period can be set per project.** The other periods in the table above (idempotency results, sessions, terminal Runs, signals, append stream entry count) are still global configuration.

For capacity estimates and related configuration, see [OPERATIONS.md](OPERATIONS.md#data-retention-and-capacity).

## Host application tables

The host application shares the same `Fyrlet.Repo` with Fyrlet, so that business writes, idempotency results and invalidation notifications can commit in one transaction (see [INSTALL.md](INSTALL.md#shared-repository-constraints)). The host's business tables should:

- carry `project_id` and `subject_id`, and preferably add the same composite foreign key `(subject_id, project_id) → subjects(id, project_id)`;
- constrain both `project_id` and `subject_id` in SQL in every private query;
- keep migrations in the host's own directory, list it in `migration_paths`, and use version numbers that sort after the core migration.

A plugin may only create new tables prefixed with the plugin name and must not modify or rebuild Fyrlet's tables (see [PLUGINS.md](PLUGINS.md#plugin-api)).

## Migrations

There is only one core migration (including the Oban tables); both `up` and `down` run completely, and `down` empties the Fyrlet and Oban tables. How to run it:

```sh
mix fyrlet.migrate --create          # Run core, host and plugin migrations together
bin/app eval "Fyrlet.Release.migrate()"   # In a release
```

The project has not been released yet, and migrations may still change before release; if a development database has run an earlier migration, recreate the database.
