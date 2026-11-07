# Optimization log

This document records the optimizations made to Fyrlet, the methods and evidence behind them, and the experiments that were reverted or left off by default after measurement. The principle is **measure first, then change**: each item states the level of its evidence (function-level, statement count, end-to-end), and a function-level gain is never written up as a gain for the service as a whole. For same-resource comparison results and the benchmark method, see [PERFORMANCE.md](PERFORMANCE.md).

Earlier raw run data is in `.local/fair/` on the local machine (ignored by version control). Section 13 includes a sanitized report in `docs/bench/` for the subscription footprint measurements.

## Overview

| Item | Status | Evidence |
| --- | --- | --- |
| Unbounded growth of completed Oban jobs | Fixed | Dependency source; table size is an estimate, not run for 24 hours |
| `View.reset` reuses sizes of unchanged records | Optimized | Pure-function microbenchmark −45%; no end-to-end data |
| Automatic cleanup of idempotency records | Implemented | Correctness tests; no performance data |
| Channel idle hibernation | Implemented, default unchanged | 3 alternating rounds: memory about −12%, CPU about +5% (within noise) |
| Delayed fallback Oban job | Implemented, off by default | 8-round comparison, no measurable gain |
| Batching of connection authentication | Reverted | 6 alternating rounds, 2–3% difference, below noise |
| `snapshot_with_metadata` dead code | Moved to test helpers | Cleanup, no performance data |
| Configurable idempotency retention period | Done, default unchanged | Estimate |
| Private view state embedded in Channel; encoded cache released | Implemented | Channel/process A/B: 200 private views use 200 instead of 400 processes; 64 KiB idle retained memory −45.3% |
| Contract snapshot budgets and node-wide Channel cap | Implemented | Startup validation and runtime regression tests; no capacity claim |
| Channel and SDK duplication | Simplified | Production source −131 physical / −115 nonblank lines; lifecycle and handle-ownership regression tests |

## 1. Oban pruner capacity

The dependency source shows that `Oban.Pruner` by default deletes at most 10,000 rows every 30 seconds, about 333 rows/second; the original configuration also kept jobs for 24 hours. Every write inserts one fallback job, so when sustained writes exceed about 333 per second, `oban_jobs` grows without converging.

The configuration is now `pruner: [max_age: 3_600, interval: 10_000, limit: 50_000]` (about 5000 rows/second), and it uses the non-deprecated `pruner:` / `cron:` configuration keys. Estimated at 500 writes/s (measured on a small table at about 2 KB per job including indexes, so the figure is on the high side): previously the 24-hour steady state was about 43 million rows, about 86 GB; now it is about 1.8 million rows, about 4 GB. **This is an estimate; it was not run for 24 hours.**

## 2. `View.reset` reuses record sizes

Additions, deletions and records moving into or out of the window go through `View.reset`, which used to re-encode every record in the window (50 by default) as JSON to compute sizes. Now `View.new/3` receives the previous view, records with identical content reuse the sizes already computed, and only added or changed records are encoded.

Microbenchmark `bench/view_reset.exs` (pure function, 50 records × 128 B, 3000 iterations per round, 5 rounds):

| | Time per addition, µs (5 rounds) | Median |
| --- | --- | --- |
| Before | 128.8 / 130.5 / 130.0 / 128.4 / 133.2 | 130.0 |
| After | 71.4 / 68.6 / 70.3 / 71.2 / 72.4 | 71.2 |

Built-in checks in the benchmark: the byte counts equal a full recomputation, and the added and removed content of the patch is correct. `test/fyrlet/view_test.exs` compares the "reused result" with a "full rebuild" on records, order, sizes and bytes, and covers changed content, no change, and fallback for non-indexed views.

**Limitation**: this is only the pure-function time of the view layer. It excludes database queries (`update_membership` still queries once) and the network. The existing load-test framework only supports "update an existing record" and has no add/delete scenario, so it cannot say how much faster things are end to end.

## 3. Idempotency record cleanup and retention

`Fyrlet.PruneWorker` uses Oban Cron to delete, every 10 minutes and in batches (5000 rows per batch), expired idempotency records and sessions that expired more than 24 hours ago, and a new index `idempotency_results(expires_at)` avoids a full table scan during cleanup. Previously there was only the manual `mix fyrlet.prune`. The index adds one index maintenance operation to every write; this cost was not measured separately.

The retention period is product semantics (the window in which a client can safely retry the same Idempotency-Key), so it was only made configurable, and the default remains 24 hours. For capacity estimates and configuration, see "Data retention and capacity" in [SERVER.md](SERVER.md).

## 4. Channel idle hibernation

`FYRLET_CHANNEL_HIBERNATE_MS` (build time, default 15000, which is the Phoenix default). Comparison: same source, same database migration, only hibernation of 15000 ms against 1000 ms; app at 1 vCPU / 1 GiB, 500 writes/s × 20 seconds, alternating A B B A A B.

| Round | Hibernate ms | Writes completed | P95 ms | App CPU seconds | Throttled periods | anon memory peak MiB |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 15000 | 9966 | 5.56 | 18.2 | 1 | 578 |
| 2 | 1000 | 9854 | 9.88 | 18.3 | 3 | 523 |
| 3 | 1000 | 9772 | 4.40 | 15.5 | 0 | 574 |
| 4 | 15000 | 9922 | 4.00 | 15.1 | 1 | 634 |
| 5 | 15000 | 9826 | 3.95 | 14.4 | 2 | 634 |
| 6 | 1000 | 9957 | 4.58 | 16.7 | 3 | 533 |

Memory (cgroup anon peak): the 15000 mean is about 615 MiB and the 1000 mean about 543 MiB, about 12% lower, but the worst and best values overlap (574 against 578); CPU is about +5%, within the ±10% fluctuation inside a group; P95 and writes completed show no reliable difference. Conclusion: this is a small trade-off that favors saving memory and is **not a speed optimization**; with more connections (for example 5000 users / 10000 connections) the gain is more likely to be significant, but this was not measured.

## 5. Experiments reverted or left off by default for lack of benefit

- **Delayed fallback Oban job** (`FYRLET_INVALIDATION_FALLBACK_DELAY_S`): the broadcast is already sent immediately after commit, and the fallback job is only needed on failure, so it was delayed by a few seconds. In an 8-round alternating comparison the mean CPU differed by about 1.5%, while rounds under the same settings fluctuate by about ±10%; there was no measurable gain. The option was removed, and the fallback job is always enqueued immediately.
- **Batching of connection authentication**: make the session lookup in `UserSocket.connect` also go through batching. With 1000 users × 2 devices and 10 writes/s × 2 seconds, so that the CPU of the whole run came mainly from connection setup, 6 alternating rounds: before the change mean CPU 4.17 seconds and connection setup 3775 ms; after, 4.07 seconds and 3697 ms, a 2–3% difference. The code and tests were reverted, to avoid adding an unproven branch to a hot path.

## 6. Other

- `Runtime.snapshot_with_metadata/4` has no production caller in `lib/`, yet on every call it computes a SHA-256 fingerprint and an O(n) index comparison, and only tests use it. It was moved as a whole to `test/support/fixtures.ex`, and `Runtime.snapshot/2` was simplified to fetch the view directly.
- New environment variable `POOL_SIZE` (database connection pool, default 10). A write transaction occupies one connection for its whole duration; whether this value limits throughput has not been measured.

## 7. Static data cache (contract index and plugin loading)

**Finding**: microbenchmarks measured about 205 µs per `Registry.fetch/2` (it called `contract()` again for every definition and rebuilt the whole contract), and about 100 µs per `Capabilities.enabled?/1` (it re-validated all plugins). The former runs on every operation call and subscription join; the latter runs in 11 places, including routing, negotiation and `Runtime`.

**What was done**: `Fyrlet.StaticCache` (`:persistent_term`; reads do not copy or lock). The contract index is cached by "list of definition modules", and the plugin loading result is cached by "plugin and capability configuration"; when the configuration changes it is recomputed automatically, and `Fyrlet.Registry.refresh/0` and `Fyrlet.Plugins.reload/0` can clear it explicitly. `config :fyrlet, runtime_cache: false` turns it off (the core test suite turns it off, because many cases rewrite contracts at runtime; the cached path is covered by `static_cache_test` and by the example, plugin package and SDK integration tests, which run with the cache on by default). The contract is treated as unchanged for a given set of definitions: code that rewrites contracts at runtime must call `refresh/0`.

| Call | Before | After |
| --- | --- | --- |
| `Registry.fetch/2` | about 205 µs | about 1.6 µs |
| `Capabilities.enabled?/1`, `supported/0` | about 100 µs | about 1 µs |
| `Capabilities.negotiate/2` | about 100 µs | about 1 µs |

End to end (cache toggled alternately in the same process, median of 4 rounds):

| Operation | Cache off µs | Cache on µs |
| --- | --- | --- |
| `Runtime.prepare_subscription` (no database write) | 286 | 55 |
| `Runtime.call("inbox.add")` (including database) | 1900 | 1660 |

**Limitation**: the write row **cannot be taken as a conclusion**. Latency drifted with the round from about 870 µs to about 2000 µs (the table and Oban jobs keep growing), and the drift is larger than the difference the cache makes. In the paired comparison, 3 of 4 rounds favored the cache being on, by about 100–240 µs, which is of the same order as the roughly 200–300 µs estimated from the call counts, but it does not reach statistically confirmable level. No cgroup-limited load test like the one in section 3 of PERFORMANCE.md was run, so no change in throughput or CPU at 500 writes/s is claimed; extrapolating from the "Single-core profile" in [PERFORMANCE.md](PERFORMANCE.md) (single core about 53% busy), the gain is a single-core share from the single digits up to about 10%, **and this is an estimate**.

## 8. `Schema.validate` success path (driven by BEAM-level profiling)

**How it was found**: first a few common suspects were ruled out with microbenchmarks (see below), then `:tprof` (`call_time`, 300 rounds) was run on the real path of "write + Observer refresh of 50 records". Method: `Mix.ensure_application!(:tools)`, `:tprof.start(%{type: :call_time})`, `enable_trace(:all)`, `set_pattern(:_, :_, :_)`, run the load, then `:tprof.inspect(data, :total, :measurement)`. Absolute times are inflated by tracing, so only relative shares are used. Result: **the largest single source of CPU in the Elixir layer is `Fyrlet.Schema.check`**: itself plus the `Access.get` it causes (487,000 calls per 300 rounds), `:maps.fold`, `String.length`/`unicode_util`, `DateTime` parsing and `Enum.reduce`, together about 25–30%. Cause: each addition or deletion resets the whole window (`View.reset`), and the entire 50-record snapshot is validated again, about 420 `check` calls per refresh.

**Causes (all on the success path)**: for each field a `path <> "." <> name` path string is built (only needed on error); every string goes through `String.length/1` (which counts grapheme clusters); every field is rebuilt into the normalized map with `Map.put`; bracket access such as `schema["format"]` goes through two layers of remote calls, `Access.get/2 → Access.get/3`; `DateTime.from_iso8601` parses every timestamp; `Enum.with_index |> map_reduce` allocates a tuple for every record.

**What was done** (`lib/fyrlet/schema.ex`, semantics unchanged): the path is a reversed list (one cons per level) rendered only when an error is reported; graphemes are counted only when `minLength` is set or the byte count exceeds `maxLength` (a string of N bytes has at most N graphemes); the map is rebuilt only for entries whose value changed; each key is read with `Map.get` only once; timestamps in canonical format are recognized by binary pattern matching, and other forms are handed back to `DateTime.from_iso8601` (the fast path answers "yes" only when that parser would also accept); arrays use tail recursion with an index.

**How semantics are kept unchanged**: the old implementation is frozen as it was in `test/support/schema_reference.ex`; `schema_differential_test` uses a seeded random generator to produce 6000 schema × value combinations (including out-of-range, multibyte, invalid types, defaults, `anyOf` and nesting), and requires the normalized values and every error path and message to be identical character for character; in addition, for all registered contracts and for 20,000 strings made by a single-character mutation of a valid timestamp, each result is compared against `DateTime.from_iso8601`. Three mutation checks were done (minLength counted in bytes, calendar check removed from the fast path, nested defaults dropped), and the differential test raised an alarm in each case.

| Validated object | Old µs | New µs | Factor |
| --- | --- | --- | --- |
| `inbox.add` input | 0.97 | 0.59 | 1.65 |
| 1 record | 3.48 | 1.66 | 2.09 |
| 50 records (snapshot refresh) | 148.4 | 69.6 | **2.13** |

(Median of 5 runs, side by side in the same process.) Profiling again, the total traced time of the same load dropped by about 15%.

**Limitation**: this is the time of the validation function itself and its share of the trace, not end-to-end throughput; the incremental update path validates only one record and benefits little, so the gain is concentrated in window resets and subscription joins. No cgroup-limited load test was run.

**Suspects ruled out (measured, not worth changing)**: the `~r` regex in the module attribute is not recompiled on every call, and costs about 0.75 µs per call (handwritten binary matching is 0.07 µs, but the absolute value is too small); `Application.get_env`/`fetch_env!` costs about 0.08 µs, and evaluating the default first in `Limits.get/1` has no visible cost; the standard library `JSON` encodes 1.44 times and decodes 2.2 times faster than Jason, but the Observer splices the encoded result into frames with `Jason.Fragment` to avoid re-encoding for each subscriber, so switching encoders would save only about 15 µs per call, and byte-level output differences would have to be verified one by one; the gain does not justify the risk.

## 9. "Measure first, then change", item by item (2026-11-07)

All load tests are written as ExUnit files that run **inside the sandbox** and live in `test/bench/` (file names do not end in `_test.exs`, so a routine `mix test` does not run them; specify the path explicitly when needed), and they roll back automatically when done, leaving no data in the test database. (When non-sandbox scripts were used earlier, residual data was left behind and caused an unrelated test failure; it was cleaned up and this approach adopted.)

After separating core tests from Inbox, ordinary operations and subscriptions in `query_counts.exs` and `revalidate_callers.exs` use `Fyrlet.TestRecords`. These measure framework paths without Inbox-specific optimizations such as its reserve window. Comparisons with earlier Inbox measurements must account for the different definition.

| File | What it measures | Usage |
| --- | --- | --- |
| `append_fanout.exs` | N subscribers, P messages: database queries and delivery time per message | `FANOUT=100 POSTS=20 mix test test/bench/append_fanout.exs` |
| `query_counts.exs` | Statement counts of user-visible operations, classified by kind | `mix test test/bench/query_counts.exs` |
| `revalidate_callers.exs` | Uses `:dbg` tracing to find who calls `Auth.revalidate` and why the Observer refreshes | Same as above |
| `run_view.exs` | Time of `Runs.View.build` when step outputs are large | `OUTPUT_KB=30 STEPS=10 mix test test/bench/run_view.exs` |
| `lease_count.exs` | Cost of the "per-project concurrency limit" check when the system holds many leases (including `EXPLAIN ANALYZE`) | `PROJECTS=200 RUNS=100 mix test test/bench/lease_count.exs` |
| `advance_statements.exs` | Every statement issued to advance one Run step, and the duplicates | Same as above |
| `packages/fyrlet_ops/test/bench/status_scale.exs` | Time of the Ops status snapshot as history grows | `HISTORY=200000 ACTIVE=2000 mix test test/bench/status_scale.exs` |

**Two pitfalls hit while measuring (both lead to misjudgment)**: in the test configuration the periodic reconciliation is 100 ms (30 s in production), which mixes extra refreshes into the counts; and if the fallback Oban jobs left by seeding data are executed by `drain_queue` inside the measurement window, the Observer refreshes a few more times. So the benchmarks raise the reconciliation interval and drain the queue before measuring.

**① Fan-out of append subscriptions** (`Stream.after_cursor_shared/4`, `features/stream/reader.ex`)

Baseline: about 2.3 database queries per subscriber per message (n=1 → 17, n=25 → 75, n=100 → 239 per message). Source: reading the stream head + reading the entries, plus the trailing read "once more to confirm there is nothing more" after the batch has been sent. What was done: (a) a batch returns `more?`, and once the head that was read has been reached, no confirming read is made (the next append has its own notification); (b) a batch for the same cursor is identical for all subscribers in the room and immutable after being written, so it is shared through ETS plus a per-stream-partition "single-flight" reader process (a hit is one ETS lookup in the caller's process; on a miss, other requests arriving at the same time queue up instead of each querying the database); (c) the JSON of a batch is encoded only once. **Only batches are cached**, not `:none` and `:reset` (a stale `:none` would hide an update that was just appended); `reset`/`prune` clear it immediately; a 1-second TTL is the fallback; any problem on the shared path falls back to the caller reading for itself. Authorization and session re-checks still run in the channel before every send, and the cache holds no per-person data.

| Subscribers | Before | After |
| --- | --- | --- |
| 25 | 75 per message | 27 per message |
| 100 | 239 per message, 16.7 ms | 34 per message, 3.8 ms |

The marginal cost dropped from about 2.24 to about 0.17 queries per subscriber (what remains is the batched session re-check). The sandbox has a single connection, so latency is for reference only, and the query count is the reliable metric. Mutation checks: caching `:none`, and not clearing the cache on reset/prune, were both caught by tests.

**② Session queries when joining a subscription** (`Observer.attach/3`)

Measured: a private subscription join takes 6 statements, 5 of which are session queries: 1 in `prepare_subscription`, 1 each for the "before/after re-check" inside `Runtime.view`, then 1 each for the "before/after re-check" of `attach` itself. They cannot simply be deleted, because the re-check in `view` also guarantees "authorization comes before the query". What was done is a reorder: first re-check → authorize → membership check, then load with the new `Runtime.load_view/4` (which has no checks), and finally one post-read re-check. Guarantees are unchanged: the application's query code is not executed for an unauthorized caller; nothing is sent if the session is revoked during loading. The join goes from 6 → 4 statements (session 5 → 3); the delivery path after a write (16 statements, 3 session checks) is deliberate and was not touched. The append join previously had no "post-read re-check"; it was added (statement count unchanged). Mutation checks: removing the post-read re-check, and moving the load back before authorization, were both caught by tests.

**③ Run view** (`Runs.View`)

The number of statements is not large in itself (5 to read a view), but to render a summary line it ran `SELECT *` to read each step's `input`/`output` (up to 64 KiB) and decrypted each side effect's encrypted `payload`/`result`. It now fetches only the columns the summary uses. 10 steps × 30 KB output: 2.06 → 0.73 ms (2.8 times); 1 KB output: 0.67 → 0.57 ms.

**④ Per-project concurrency limit check** (`Engine.project_busy?/2`)

It runs on every step claim: it JOINs all "attempts holding a lease" system-wide with `runs` and then filters by project. `EXPLAIN ANALYZE` shows the plan is a sequential scan of the whole lease table:

| Leases system-wide | Held by this project | Before | After |
| --- | --- | --- | --- |
| 2,000 | 40 | 197 µs (scans 2000 rows) | 62 µs (scans 40 rows) |
| 20,000 | 100 | **1,436 µs** (scans 20,000 rows) | **69 µs** (scans 100 rows) |

The cost is proportional to the concurrency of "all other projects" and is invisible with small data. What was done: a new migration adds `project_id` to `fyrlet_run_attempts` (backfilled and set non-null) and a partial index `(project_id, lease_expires_at)` containing only records that hold a lease; the query no longer JOINs. This rule **had no tests at all before**, so tests were added first (project isolation, expired leases not counted, finished attempts not counted, own lease not counted, and when limited the step stays unclaimed and is retried later), and it was confirmed that **the original JOIN query also passes the same tests** (semantics unchanged); all three mutations were caught. The similar query in `Recovery` that counts leases per project also lost its JOIN.

**⑤ Advancing a Run by one step**

Of the 29 statements, each event takes two round trips, "`UPDATE event_seq` + `INSERT event`", and one step has 3 events. These were fused into a single CTE statement (same transaction, same row lock, semantics unchanged; unlike what was first envisaged, no buffering at the transaction boundary is needed), and the event writes of both Runs and Effects were changed: 29 → 26 statements. When the UPDATE matches nothing, the CTE makes the INSERT silently insert 0 rows, so `num_rows == 1` is checked explicitly to keep the original "fail loudly if not found" behavior. For a duplicate receipt ID, the exception type changed from `Ecto.ConstraintError` to `Postgrex.Error`; no code depends on it (both roll back the transaction).

**⑥ Things confirmed after measurement not to need changing**

- **Ops status snapshot**: with 200,000 historical Runs + 2000 active, `status(:all)` takes 17.4 ms and a single project 7.9 ms; once every 30 seconds this takes about 0.06% of a core. With 10 times the data it is only 0.6%, so it is not optimized.
- **Oban insert trigger**: each job costs two round trips, "INSERT + `pg_notify`", which looks avoidable, but with it turned off the wake-up between Run steps would wait for the polling interval, adding up to about 1 second of delay to every step transition, which is not worth it.
- **Run step context reads the outputs of all completed steps**: this is O(N²) for a Run with N steps, but it is the semantics (the `step/3` context promises to provide previously committed outputs), not an implementation problem.

**Limitation**: all of the above are statement counts, query plans and function/view-level timings, **not end-to-end throughput**, and no cgroup-limited load test was run; the sandbox uses a single database connection, so latency does not represent concurrent behavior under a real connection pool.

## 10. End-to-end re-test: HEAD against the current working tree (2026-11-07)

**Purpose**: answer two questions: did the platform changes slow down the basic path? Did this round of optimizations bring a net gain?

**Conditions**: the same-resource limits of "Test conditions" in [PERFORMANCE.md](PERFORMANCE.md) (app 1 vCPU / 1 GiB, `cpuset 0`, PostgreSQL and the generator each on their own core, cgroup v2 accounting), and the same load generator (using the SDK of the current working tree, with both sides using the basic protocol): 1000 users × 2 devices, `sessions=shared`, 50 records × 128 B per user, 500 writes/s, 20 seconds, warmup 1, database rebuilt and seeded for each run. Order A B B A, two rounds, 8 runs in total. A = repository HEAD (`27bcb2a`, Inbox in `lib/`, release built with `Dockerfile.fyrlet`); B = the current working tree, with Inbox as a **standalone host application** (`examples/inbox`) built into a release.

**The first result showed +26% CPU, caused by configuration rather than code**:

| | HEAD | Current (first) |
| --- | --- | --- |
| App CPU seconds (4 runs) | 14.6 / 12.7 / 12.7 / 12.7 | 18.7 / 17.4 / 15.5 / 15.3 |

Every current run is higher than every head run, so it is not noise. Checking the configuration showed that HEAD's `config/prod.exs` sets `logger level: :info`; the dependency library's own configuration file is not loaded, the host application (`examples/inbox`) did not have it in its configuration, and the release defaults to `:debug`, so every SQL statement was formatted and written out. After adding `config :logger, level: :info` to the three example applications and re-running, this item was also added to the list of required settings in `INSTALL.md` (this is a real pitfall when integrating a host application).

**Corrected result**:

| | HEAD | Current |
| --- | --- | --- |
| Writes completed (4 runs) | 10000 / 9999 / 9999 / 9988 | 10000 / 9991 / 10000 / 10000 |
| Propagation P95 ms | 2.17 / 2.35 / 2.16 / 2.82 (median 2.26) | 2.14 / 2.63 / 2.12 / 2.08 (median 2.13) |
| App CPU seconds | 12.8 / 13.6 / 12.7 / 14.1 (mean 13.3) | 12.4 / 13.0 / 12.7 / 12.5 (mean 12.7) |
| Throttled periods | 0 / 0 / 1 / 1 | 0 / 0 / 0 / 5 |
| anon memory peak MiB | 674 / 674 / 669 / 669 | 568 / 568 / 559 / 561 |
| Coverage / OOM | all 1.00 / 0 | all 1.00 / 0 |

**Reading**:
- **No regression on the basic path**: writes completed, coverage and P95 agree within noise.
- Mean CPU is about 4% lower for current, but the ranges of the two sides overlap (12.4–13.0 against 12.7–14.1), **so it is within noise and no speedup is claimed from it** (the "Single-core profile" in [PERFORMANCE.md](PERFORMANCE.md) records that two repetitions of the same baseline can differ by ±20%).
- The only clear difference is the anon memory peak: the ranges of 4 runs against 4 runs do not overlap at all, and current is about 16% lower. **The cause was not profiled**, and no guess is made.
- This is an overall comparison of "HEAD against the whole working tree": it contains both the platform changes and the optimizations of the earlier sections, so **the difference cannot be attributed to any single item**. The gains of the earlier sections remain function/statement-level evidence (sections 7–9).

**Limitation**: only the inbox load at 500 writes/s was measured; no end-to-end load was measured for Runs, Effects or append subscriptions (these paths do not exist in HEAD, so there is no comparison baseline); each group has only 4 runs.

**Reproduction**: get the baseline with `git worktree add --detach .local/fair/base-src 27bcb2a`; build two images with `Dockerfile.fyrlet` (baseline) and `Dockerfile.current` (current, release built from `examples/inbox`); run a single run with `VARIANT=head|current fyr_ab.sh <image> <rate> <label>`, and run A/B/B/A with `abba_ab.sh <rate> <rounds>`. These scripts are in the ignored `.local/fair/` directory, contain absolute paths of the local machine, and have not yet been turned into reusable tools.

## 11. Batched session re-checks for shared subscriptions, and a round of experiments with no end-to-end gain (2026-11-07)

The starting point was a list of candidates from a static analysis of each layer (compilation and data layout, copying and encoding, GC, allocator, I/O, database round trips, transport, native kernels). After implementing and measuring them one by one, **only one item was kept**; the others had function-level gains of 1.7–3.3 times but showed no difference in end-to-end A/B, and were reverted.

### Kept: member session re-checks of `identical` shared subscriptions are now batched

**Finding**: `test/bench/shared_fanout.exs` (N members subscribe to the same `sharing: "identical"` room, and one change is triggered) counts the session statements per change as **exactly the number of members** (25 / 100 / 300 members give 25 / 100 / 300 statements). Cause: `Observer.deliver/3` and `recheck_clients/1` call `Auth.revalidate/1` for each member one by one **in a single process**, and it is a blocking call to a `SessionChecks` shard; the shard's batching can only merge **concurrent** callers, a single process sends only one request at a time, and each member becomes a query containing just one. (Each subscriber of an append subscription is its own Channel process and could already be merged by the shard, so it is not affected.)

**What was done**: added `SessionChecks.revalidate_many/1` and `Auth.revalidate_many/1` (using `:gen_server.send_request/2` to send all requests first and then collect the replies together, with a 15-second deadline for the whole; when batching is off or inside a transaction it falls back to direct queries one by one). Before the delivery loop, and during reconciliation, the `Observer` first does one batched session pre-check for "the members to be checked this round", then does the authorization and membership checks one by one and sends. A private Observer has only one member, so its behavior is unchanged.

| Members | Before (statements per change) | After |
| --- | --- | --- |
| 25 | 25 | 8 |
| 100 | 100 | 11–14 |
| 300 | 300 | 16 |

The sandbox has a single connection, so only statement counts are trusted and latency is not; over a real network the time of serial round trips grows linearly with the number of members, and after batching it grows with the number of shards (8).

**Semantic change**: the gap between the session check and the authorization and membership checks of the other members in the same round is larger than before (previously they were right next to the send). Within the same delivery round, a revoked session is still stopped (there is a test). The authorization and membership checks themselves still run one by one, before sending.

**Tests**: `session_checks_test` gains three: the result is consistent with calling `revalidate/1` one by one and preserves order (including revoked, cross-project and nonexistent sessions); 20 requests on the same shard produce only one batched query; and with batching off or inside a transaction a direct query is used. `shared_scope_test` gains one: with batching on, of three members the one whose session was revoked is stopped, and the other two receive the snapshot as usual. Mutation check: making the batched pre-check let all members through raises an alarm in two tests.

### Reverted: four items with function-level gain but no end-to-end gain

| Candidate | What was done | Function-level measurement |
| --- | --- | --- |
| Compile the contract into closures | Extract the schema's keyword reads, attribute table and defaults once, so validation no longer does `Map.get` item by item | 1 record 1.44 → 0.67 µs; 50 records 64 → 37 µs (about 1.9 times) |
| Reuse record encodings | `View` keeps the JSON of each record, and the snapshot is spliced from these fragments instead of being re-encoded as a whole | First snapshot of 50 records 209 → 137 µs; rebuild after changing 1 record 178 → 110 µs |
| Window reset skips validation of unchanged records | Records strictly equal to the previous version are not validated again, and any exception falls back to full validation as a whole | 28.6 → 8.7 µs (1/50 changed) |
| `View.new` / `reset` single pass | Remove the discarded `RecordIndex` position table; the delta and unchanged decisions look only at records "different from the previous version" | `reset` (1/50 changed) 159 → 91 µs |

All four have differential tests (the old implementation frozen as a reference, compared field by field on random input) and mutation checks, and have no known correctness problem. The reason for reverting is that there is **no end-to-end evidence** while about 300 lines of code are added.

**How the end-to-end A/B was done**: a "baseline copy" was made on top of the current code, with the four items above turned off one by one (the registry does not carry the compiled schema; `validate_known` is switched back to `validate`; `View.new`/`reset` are switched to the frozen old implementation; snapshots are re-encoded as a whole), and each was built into an image, everything else identical; the seed data is prepared by the same code, so only the image differs. The load is the same as in section 10 (1000 users × 2 devices, `sessions=shared`, 50 records × 128 B per user, 20 seconds, warmup 1), alternating A B B A, 6 runs per side.

| Condition | Metric | Baseline (off) | Current (on) |
| --- | --- | --- | --- |
| 500 writes/s, 1 vCPU | Writes completed (median) | 9990 | 9976 |
| | P95 ms (median) | 2.66 | 2.65 |
| | App CPU seconds (median / range) | 13.5 / 12.8–14.4 | 13.2 / 12.3–13.6 |
| 500 writes/s, 0.5 vCPU (CPU is the bottleneck) | Writes completed (median / minimum) | 9928 / 9603 | 9984 / 9773 |
| | P95 ms (median / range) | 42.9 / 11.6–86.1 | 25.0 / 16.2–75.6 |
| | App CPU seconds (median) | 12.9 | 13.1 |

Reading: all differences fall within the fluctuation between repetitions (the CPU ranges overlap; the P95 range at 0.5 vCPU is 11–86 ms, so the difference in medians is not trustworthy; writes completed differ by only 0.6%), so **no end-to-end gain can be claimed**. The median anon memory peak of the current image is 6–8% higher in both groups (588 against 624, 620 against 669 MiB), the ranges overlap, and the cause was not profiled.

This is consistent with the "Single-core profile" in [PERFORMANCE.md](PERFORMANCE.md): at 500 writes/s on 1 vCPU the app is busy only about half the time, these changes save a few tens to over a hundred microseconds per refresh, and a write spends most of its time on database round trips.

### Connection pool size: 10 against 30, no difference

Same image, only `POOL_SIZE` differs, 800 writes/s, 1 vCPU, A B B A, 6 runs per side:

| | `POOL_SIZE=10` | `POOL_SIZE=30` |
| --- | --- | --- |
| Writes completed (median) | 15776 | 15805 |
| P95 ms (median / range) | 7.1 / 3.7–11.9 | 4.5 / 3.6–11.5 |
| App CPU seconds (median) | 18.3 | 18.0 |

At this point app CPU is not saturated (almost no throttling) and the connection pool is not the bottleneck, so the default of 10 is kept. Whether this changes at higher rates or with a slower database was **not measured**.

### No conclusion

- **BEAM scheduler busy-wait parameters** (`+sbwt none` and so on): a comparison was set up (`ERL_AFLAGS` passed to the same image), then it was decided not to continue and it was aborted, so there is no usable data.
- **Saving one round trip on the write path** (insert a placeholder row first for idempotency): not implemented; the "Single-core profile" in [PERFORMANCE.md](PERFORMANCE.md) estimates about 10%, below noise.

### Limitations

- The end-to-end load is the inbox with private subscriptions (`soak`); **shared rooms were not measured end to end**; the gain of batched re-checks for shared rooms has only statement-count evidence.
- With 6 runs per side, and two repetitions of the same baseline able to differ by ±20% (see the "Single-core profile" in [PERFORMANCE.md](PERFORMANCE.md)), the table above can only rule out large differences.
- Microbenchmark factors cannot be converted directly into service throughput: when the optimized part accounts for 20% of the total time, even a 5-times speedup of it gives only about 1.19 times overall.

### Reproduction

```sh
FANOUT=100 ROUNDS=5 mix test test/bench/shared_fanout.exs      # Session queries per shared-room change
```

The end-to-end A/B follows the script approach of section 10 (images, the same seed, A B B A). The scripts are still in the ignored `.local/fair/`, contain absolute paths of the local machine, and have not been turned into reusable tools.

## 12. Still not done

- **Advancing one step still has duplicate reads**: the same step row is read with a lock 3–4 times in one advance, and the Run row twice. They are all necessary reads (row locks) in their own transactions; merging them requires restructuring the transaction boundaries of `Engine`, and this module is guarded by fault-injection tests of the state-machine invariants, so the gain (a few index lookups) does not outweigh the risk.
- **The Run is loaded twice when reading a view** (once for `run_authorize/4`, once for the view). One load could be saved by passing the already loaded Run through the call chain, but that would change the interface between authorization and the view, for a small gain.
- **Session re-checks of append subscriptions**: now every subscriber is re-checked before every send (with batching shards), which is the main marginal cost remaining after the fan-out; lowering it further requires a trade-off in the authorization semantics and needs a separate review. (The member re-checks of shared `identical` subscriptions are a different matter, and were made batched in section 11.)
- **BEAM VM parameters** (such as `+sbwt none`: in a 1 vCPU cgroup, scheduler busy-waiting consumes CPU quota): there is no reproducible container environment on the local machine, and no changes are made on speculation.
- End-to-end throughput and the comparison under cgroup limits require re-running the external load tests of "Comparison results" in [PERFORMANCE.md](PERFORMANCE.md); none of the changes above has yet been re-tested in that environment.

### Directions decided against

The following directions were listed during the static analysis. Without evidence of a corresponding bottleneck or load they are not pursued; those that were tried and reverted are in section 11:

- **Native kernels (Rustler / NIF)**: no computational hotspot was measured. The call granularity, the cost of constructing BEAM terms, scheduling and the maintenance cost of the deployment architecture are all not low.
- **GC, process heaps and `off_heap`**: no evidence of message buildup or GC problems; a uniform setting brings extra allocation, and the trade-off differs between processes.
- **Allocators (mimalloc / jemalloc), io_uring, replacing the whole I/O model, Nx / EXLA / GPU**: no allocator contention, transport-layer bottleneck or vector-computation load has appeared.
- **Splitting serial nodes (`Tracker`, the Observer's `DynamicSupervisor`)**: `claim` does only a few map operations, and there is no evidence it is limited under a connection storm; splitting would make the limit accounting and cleanup of the same transport more complex.
- **Reducing database round trips on the write path**: merging the advisory lock and the idempotency lookup does not hold under READ COMMITTED (see "Single-core profile" in [Performance comparison](PERFORMANCE.md)); "insert a placeholder row first for idempotency" is expected to save one round trip, about 10%, below measurement noise, and is not implemented.

A general lesson: the factor of a function-level microbenchmark does not represent the service as a whole. If the optimized part accounts for 20% of the total time and is sped up 5 times, the whole is only about 1.19 times faster; the time of this path is mainly database round trips, so **reducing the number of round trips** (the statement count can be counted directly) has real value, while speeding up some Elixir computation by a few tens of microseconds cannot be seen end to end.

## 13. Private subscription process and cache footprint (2026-11-07)

Private subscriptions now embed `Fyrlet.Subscriptions.Observation` inside their Channel. Explicit session sharing and `sharing: "identical"` continue to host that state machine in an Observer. Private Channels retain the normalized View but release encoded snapshot bodies after returning or enqueueing them; queued outbound data is still retained until consumed. Shared Observers keep their encoded cache for reuse across members. The View remains necessary for equality checks, incremental updates and bounded query context, even with snapshot delivery. Dropping it would discard useful state and can add queries.

The controlled experiment alternated before/after three times. Only the Observer and SubscriptionChannel source variants were switched; the remaining runtime, contract limits, benchmark fixture and measurement method stayed fixed. Each run modelled 40 subjects with five Channels each, 32 records per snapshot and six invalidation rounds, using `Phoenix.Socket.V2.JSONSerializer`. One subject's scope was notified at a time (five private views, or one shared view with five members). The shared case is a control. Elixir 1.20.5 / OTP 29, 12 online schedulers, local PostgreSQL. The [report](bench/connection-footprint-2026-11-07.json) contains every successful controlled sample and the measured source fingerprints.

| Case (200 Channels) | Distinct Channel + view-owner processes | Idle retained MiB, before → after | Active retained MiB, before → after |
| --- | --- | --- | --- |
| Private, 1 KiB | 400 → 200 | 4.10 → 4.20 (+2.5%) | 5.89 → 4.21 (−28.6%) |
| Private, 64 KiB | 400 → 200 | 30.28 → 16.57 (−45.3%) | 33.00 → 19.01 (−42.4%) |
| Private, 255,000 B | 400 → 200 | 102.55 → 51.68 (−49.6%) | 105.00 → 55.15 (−47.5%) |
| Session-shared, 64 KiB | 240 → 240 | 7.92 → 7.89 | 7.83 → 7.83 |

Retained memory is the sum of process heaps plus unique referenced ref-counted binaries across the measured processes, after forced GC; a shared binary is counted once. Idle figures are medians of three runs, active figures medians of 18 update samples. These are live retained bytes, not RSS savings; the report records VM and RSS samples separately. Small idle snapshots show the added Channel state can outweigh the saved process heap.

The median of per-round notification-to-receipt P95 was 3.285 → 3.338 ms for private 64 KiB and 7.779 → 7.668 ms for private 255,000 B; the shared control was 2.064 → 2.050 ms. This supports no latency improvement claim. Each round still made 400 session queries for private views or 80 for shared views, with no queued messages at sample time. Business database reads are absent from this synthetic fixture. An earlier all-scope concurrent run exhausted the single SQL sandbox connection's queue; it was excluded rather than reported as product capacity.

**Boundaries:** ChannelTest with real PostgreSQL session checks, one sandbox connection and controlled scope concurrency. It excludes TCP, TLS, Bandit transport and SDK memory, does not measure sustained per-second update rates or maximum connections, and does not justify a 50k/100k-node capacity estimate. Standard production hibernation defaults remain unchanged; the short measurement samples do not establish idle hibernation savings. Reconciliation was extended only in the fixture to avoid unrelated timer work during measurement.

`bench/tracker_claims.exs` also measured bounded arrival bursts including process-monitor cleanup. Requested rates of 1,000 and 5,000 claims/s achieved approximately 1,001 and 4,997 claims/s; P99 call times were 36 and 296 µs (max 64 and 637 µs). Claims returned to the baseline after each run. This isolated result provides no reason to shard Tracker; it excludes authentication, Channel startup and concurrent business load.

Resource protection now separates active Channels from shared Observer processes. `max_subscriptions_per_node` defaults to 10,000, includes ordinary, append and Presence Channels, and is validated at startup. The environment setting `FYRLET_MAX_SUBSCRIPTIONS_PER_NODE` accepts 1–1,000,000. `max_observers` remains a separate shared-process ceiling. A subscription may declare a positive `max_snapshot_bytes` no larger than the global ceiling; definitions are validated at startup, and actual initial/recomputed snapshots are checked at runtime with `LIMIT_EXCEEDED`, never truncated. No arbitrary business-specific budgets were imposed on existing example contracts.

Shared mode stays explicit: `public` permits anonymous access and does not prove actor-independent results. The production reconciliation interval stays 30 seconds to preserve the missed-notification repair window. Multiplexing remains an evidence-gated [roadmap](ROADMAP.md#later-evaluations) item; the project is unlaunched and does not need an old-protocol fallback. VM, GC and OS settings stay unchanged without a measured deployment bottleneck. Reproduction commands and fixture boundaries are in [bench/README.md](../bench/README.md#subscription-process-footprint).

## 14. Channel and SDK code quality (2026-11-07)

This pass extracts shared Channel mechanics into `FyrletWeb.ChannelSupport`: identifier validation, error replies, anonymous capability checks, quota claims, expiry and ACK timer scheduling, timer cleanup, close status, snapshot envelopes and JSON fragments. Subscription, append and Presence Channels keep their authorization order, state machines and backpressure rules. The local/shared dispatch for subscription ACKs and refreshes now uses one path.

The TypeScript client also shares the readiness, success, error and timeout handling for refresh and Presence updates. Presence now extends the existing subscription handle and looks up its entry through the existing WeakMap. The former copied handle lost its ownership registration, so using it in an optimistic write incorrectly raised a TypeError. A regression test reproduced the failure before the fix. The registered handle is now preserved, without scanning all entries.

| Production file | Lines before → after |
| --- | --- |
| `lib/fyrlet_web/subscription_channel.ex` | 321 → 235 |
| `lib/fyrlet_web/append_channel.ex` | 423 → 346 |
| `lib/fyrlet_web/presence_channel.ex` | 223 → 187 |
| `lib/fyrlet_web/operation_channel.ex` | 81 → 69 |
| `lib/fyrlet_web/channel_support.ex` | 0 → 87 |
| `sdks/typescript/src/client.ts` | 572 → 565 |
| **Affected production files, including the new helper** | **1620 → 1489 (−131)** |

The baseline is the working tree at the start of this pass, after section 13. Across `lib/**/*.ex` and `sdks/typescript/src/**/*.ts`, physical lines fell from 13,448 to 13,317; nonblank lines fell from 11,332 to 11,217 (−115). These counts include the new helper and exclude tests, documentation and benchmark code. The reduction comes from removing repeated implementations; line count alone does not establish quality or runtime performance.

Nine new Elixir regressions exercise malformed identifiers, a shared node budget across all three subscription Channel kinds, slot release on leave, expiry and timer cleanup. Three new SDK regressions cover Presence handle ownership, stale handles, readiness, error/timeout replies and preserving the last acknowledged Presence meta after failed updates. Final suite results are recorded in [ACCEPTANCE.md](ACCEPTANCE.md).
