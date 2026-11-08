# Stability sampling and threshold gate

English | [简体中文](zh/STABILITY.md)

`scripts/stability.mjs` runs the existing same-host Chat/Agent cluster workload, independently samples `chat_cluster` and `agent_cluster`, collects Chat node telemetry, and can enforce an explicit, versioned threshold profile. It does not establish multi-host fault tolerance, production capacity, or a production SLO.

## Safe defaults and run labels

The current CLI remains valid:

```sh
# Short correctness drill; does not run a threshold gate.
node scripts/stability.mjs --seconds 30 --clients 4 --sample-ms 5000

# Full-duration correctness run; 86400 seconds is also the default.
node scripts/stability.mjs --seconds 86400 --clients 20
```

Without `--profile`, `thresholdGate.status` is `not-run`; a completed run can pass correctness without implying that any resource threshold passed. Defaults remain 86,400 seconds, 20 clients, a 30,000 ms database sample interval, and base port 4250. Bounds remain 5–86,400 seconds, 2–50 clients, 1,000–60,000 ms sampling, and ports 1024–65530. The 24-hour workload is never started by the offline helper tests.

Every run shorter than 86,400 seconds is labeled `short-smoke-correctness-only`, including a short run used to debug a profile. It never marks `stability24h` or `productionSLO` as verified. A passing 24-hour profile records only a same-host threshold-gate result; it is not production SLO certification.

The wrapper rejects `CLUSTER_DATABASE_URL` overrides and constructs only the fixed loopback `chat_cluster` and `agent_cluster` URLs on PostgreSQL port 55432. **Those databases are migrated and written by the workload; they are not disposable databases created uniquely for each run.** Do not run the wrapper against valuable existing local data. Existing report files and per-run logs are never overwritten, and the source fingerprint must remain unchanged.

## Schema preparation, baseline and watchdog

Before launching `scripts/cluster.sh` or any fixture writer, the wrapper:

1. Runs `mix fyrlet.migrate --create --quiet` separately for the fixed Chat and Agent example applications/databases, with migration output in the private per-run log.
2. Opens one read-only sampling pool per database and successfully queries all required tables in **both** databases. Missing tables or a failed baseline query abort the run before the workload launches.
3. Stores the first successful sample from each database as that database's growth baseline and writes the running report with `baselinePersisted: true`. The workload starts only after that write completes.

Thus no fixture write can race the baseline. The cluster script may repeat idempotent migrations later, but its fixtures and workload start only after the persisted baseline.

The outer watchdog is:

```text
(requested seconds + max(60, ceil(requested seconds / 20)) + 600) * 1000 ms
```

The middle term is the inner Chat soak test's own grace period, including post-soak full-history verification. The additional 600 seconds is the setup/finalization budget. A 24-hour run therefore has a 91,320-second outer budget, rather than being stopped after only ten minutes of post-soak grace.

The watchdog and signal handlers remain installed through final fingerprinting, cleanup, and final report persistence. A late SIGINT, SIGTERM, or watchdog expiration makes the report failed and the process nonzero even if workload correctness had already completed. The timeout is cleared only after final persistence. Errors after the initial report exists are sanitized and followed by a best-effort failed/finished report write. A filesystem failure during that final write itself can still prevent persistence and is reported on stderr with a nonzero exit.

## Version 1 JSON profile

Pass `--profile FILE`. The file is limited to 64 KiB and must contain exactly one version 1 object with `workload` and `limits`. All three workload fields are required. Unknown fields, missing required fields, wrong types, non-finite/negative values, invalid ranges, an empty `limits` object, and an empty `tableRowGrowth` object are rejected before migration or workload execution.

```json
{
  "version": 1,
  "workload": {
    "seconds": 86400,
    "clients": 20,
    "sampleMs": 30000
  },
  "limits": {
    "memoryGrowthBytes": 536870912,
    "databaseGrowthBytes": 1073741824,
    "tableRowGrowth": {
      "sessions": 1000,
      "idempotency_results": 250000,
      "jobs": 1000
    },
    "pendingRuns": 10,
    "pendingAgeSeconds": 60,
    "unresolvedEffects": 0,
    "databaseLockWaiters": 0,
    "poolQueuePerQueryMs": 5,
    "sampleGapMs": 45000
  }
}
```

The numbers above illustrate the schema only; they are **not defaults, recommended production limits, or an SLO**. Select limits from the intended workload, baseline measurements, retention behavior, and operating environment. At least one limit is required. Each supported limit is otherwise optional, and a table-growth object may select any nonempty subset of its three tables. Comparisons are inclusive: `observed <= limit` passes. Zero is a valid explicit limit.

`sampleGapMs` is mandatory whenever any database-backed growth, table, pending, Effect, or lock threshold is selected. It also applies independently to both databases. Memory/pool-only profiles do not require it.

`--seconds`, `--clients`, and `--sample-ms` override the corresponding profile workload values. `--base-port` and `--out` remain CLI-only. The report records the effective numeric workload and validated limits, not the profile pathname or arbitrary input fields.

```sh
node scripts/stability.mjs --profile .local/readiness/stability-profile.json

# A short profile debugging run is still correctness-only evidence.
node scripts/stability.mjs --profile .local/readiness/stability-profile.json \
  --seconds 30 --clients 4 --sample-ms 5000
```

## Required database sampling coverage

Every selected database threshold, including `sampleGapMs`, requires all of the following independently for Chat and Agent:

- At least `max(2, ceil(seconds * 1000 / sampleMs) + 1)` successful samples. For a 24-hour run with 30-second cadence this is 2,881 samples; two isolated endpoints cannot pass.
- Strictly increasing, valid sample timestamps.
- A baseline sample at or before `workloadStartedAt` and a final sample at or after `workloadFinishedAt`.
- The maximum of the baseline-to-workload-start gap, every consecutive successful-sample gap, and the workload-finish-to-final-sample gap must be at most `sampleGapMs`.

If count, monotonicity, start/end coverage, or timestamps are invalid, all selected observations for that database are `unverified`; they are not evaluated as passing two-point growth. Sampling query failures and incomplete runs independently prevent a successful run. A missing Agent stream never borrows Chat samples.

Offline evaluation requires `samples: { chat: [...], agent: [...] }` plus `runWindow: { workloadStartedAt, workloadFinishedAt }`; the profile supplies duration and cadence. A bare array or a missing database stream is invalid evidence and produces `unverified`, never an inferred Chat-only pass.

## Exact threshold meanings

Database limits are applied once to `chat_cluster` and once to `agent_cluster`. Their check names and result summaries are prefixed with `chat.` or `agent.`. Only metrics produced by the wrapper and its current Chat cluster report are evaluated. Missing, malformed, or unusable evidence produces `unverified`, never an assumed zero or pass.

| Profile limit | Observation and required evidence for each database |
| --- | --- |
| `databaseGrowthBytes` | Peak `pg_database_size(current_database())` minus that database's persisted baseline, clamped at zero. Using the peak retains intermediate growth even if the final size falls. |
| `tableRowGrowth.sessions` | Peak `sessions` row count minus the same database's baseline, clamped at zero. |
| `tableRowGrowth.idempotency_results` | Peak `idempotency_results` row count minus its baseline, clamped at zero. |
| `tableRowGrowth.jobs` | Peak `oban_jobs` row count (reported as `jobs`) minus its baseline, clamped at zero. |
| `pendingRuns` | Maximum sampled count of `fyrlet_runs` with status `pending`. |
| `pendingAgeSeconds` | Maximum sampled `oldest_pending_seconds`, derived from the oldest pending Run's `inserted_at`; the existing query reports zero when there is no pending Run. |
| `unresolvedEffects` | Maximum sampled count of Effects where `resolution_required` is true or status is `unknown`. |
| `databaseLockWaiters` | Maximum sampled count of current-database `pg_stat_activity` rows whose wait event type is `Lock`. This is a waiter count, not lock duration. |
| `sampleGapMs` | Maximum successful-sample gap described above, including expected workload start/end coverage. |

The two non-database limits use Chat soak samples:

- `memoryGrowthBytes`: maximum over Chat nodes of peak `memory_bytes` minus that node's initial value. Requires the initial node set and at least two complete, matching node samples. This is BEAM VM memory telemetry, not OS RSS or a leak-rate estimate.
- `poolQueuePerQueryMs`: across both Chat nodes and every adjacent node-sample interval, sum nonnegative deltas of cumulative `db_queue_microseconds`, divide by the summed deltas of `db_queries`, then convert to milliseconds. Requires a positive total query delta and monotonic counters. This is an arithmetic mean per issued DB query, **not** a maximum, percentile, or mean restricted to queries that actually waited. Counter resets or zero query deltas make it unverified.

The Agent report has no equivalent node-memory/pool series. The wrapper does not infer Agent memory, per-table byte sizes, lock-wait age, pool-wait percentiles, OS RSS, or host-wide resource usage. Peak-minus-baseline growth does not establish a leak rate, and a mean pool queue ratio can hide individual slow waits.

## Per-database outcomes, logs and exit status

`result.json` stores `samples.chat` and `samples.agent` separately, with per-database sampling counters in `databaseSampling`. Each threshold check has a fixed name, a `database` field (`chat`, `agent`, or `null` for node-level checks), and numeric evidence:

```json
{
  "name": "agent.databaseGrowthBytes",
  "database": "agent",
  "status": "failed",
  "observed": 1073741825,
  "limit": 1073741824,
  "unit": "bytes",
  "aggregation": "peak-minus-baseline-sample"
}
```

`thresholdGate.databaseResults.chat` and `.agent` contain independent `status`, `violations`, `unverified`, and `samplingCoverage` summaries. An Agent-only violation therefore fails Agent and the overall gate without changing a passing Chat observation. Check status is `passed`, `failed`, or `unverified`; top-level `violations` contains only actual `observed > limit` failures.

The gate statuses are:

- `not-run`: no profile was selected; no threshold result is claimed.
- `running`: initial state while preparation or the workload is active.
- `passed`: the run and required sampling completed, and every selected check passed.
- `failed`: a limit was violated, evidence was unverified, or the gated run was incomplete/interrupted.

The process exits nonzero for actual threshold violations, incomplete/failed workloads, sampling failures, source changes, invalid configuration, interruption, or unavailable required evidence. An unverified or not-run result is never converted into a gate pass. Threshold outcomes contain only fixed names, units, aggregations, statuses, database identifiers, and numeric/boolean coverage evidence; database errors, secrets, and arbitrary profile content are not copied into them.

The unique report directory contains `cluster.log` and `cluster/chat-node-0.log`, `cluster/chat-node-1.log`, `cluster/agent-node-0.log`, and `cluster/agent-node-1.log`. These per-run logs are created with mode 0600; the report/cluster directories are requested as 0700. Default cluster fixtures outside this wrapper retain their existing log behavior.

## Offline helper tests

```sh
node --test bench/test/stability.test.mjs
node --test bench/test/readiness.test.mjs
npm --prefix bench test
```

The focused tests use synthetic independent database streams and temporary profile files. They do not start the cluster, connect to PostgreSQL, run migrations, run a 24-hour workload, or validate production threshold values.
