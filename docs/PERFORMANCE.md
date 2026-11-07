# Performance comparison

Measurement date: 2026-11-07. This document keeps only the latest same-resource Fyrlet / Meteor comparison and the end-to-end comparison of shared rooms and append streams; for how the optimizations were done, the evidence, and the experiments that were reverted, see [OPTIMIZATIONS.md](OPTIMIZATIONS.md). Earlier rounds of historical reports have been removed, and their conclusions are no longer relied on.

The raw run data is in `.local/fair/` on the local machine (ignored by version control) and is not committed with the repository. For the comparison conditions and the thresholds for drawing conclusions see [bench/FAIRNESS.md](../bench/FAIRNESS.md).

## Limits of the conclusions

- These are results from a **single-core group** (1 vCPU / 1 GiB per application) inside a **single-machine virtual machine**, with 2 repetitions per load point and a load duration of 20 seconds.
- The trend is clear: at 500 writes/s Fyrlet completed the vast majority of the target writes, while Meteor completed only 20–29%. But Meteor's variation between repetitions is large, so **no stable multiple can be given from this**.
- The business guarantees of the two sides are **not aligned** (see "Conditions that are not aligned" below). It cannot be taken as an "engine ranking under the same guarantees".
- No multi-core group, long-duration stability, cold start or disconnect-recovery comparison was done.

## Test conditions (enforced by the operating system)

| Item | Configuration |
| --- | --- |
| Environment | Colima Linux virtual machine (10 vCPU / 24 GiB), Docker containers, cgroup v2 |
| Applications | Fyrlet and Meteor each with `--cpus 1 --memory 1g --memory-swap 1g`, `--cpuset-cpus 0` |
| Databases | PostgreSQL 17 and MongoDB 7.0 (replica set + oplog), each 2 vCPU / 2 GiB, `cpuset 1-2` |
| Generator | Separate container, `cpuset 4-9`, sharing no cores with the applications or databases |
| Build artifacts | Fyrlet: `mix release`; Meteor: the production bundle from `meteor build`, Node 24.22.1 |
| Load | 1000 users × 2 devices (3000 connections), `sessions=shared`, 50 items × 128 B per user, 20 seconds, concurrency 64, warmup 1, timeout 60 seconds |
| Order | Fyrlet / Meteor / Meteor / Fyrlet alternating; data re-seeded for every round |
| Limit evidence | Before and after every round, the container cgroup's `cpu.stat` (usage, nr_throttled), `memory.events` (oom_kill) and `memory.peak` are read |
| BEAM | `schedulers_online=1` under the cgroup (host has 10 cores) |

The containers' default soft file descriptor limit is only 1024, and 3000 connections get stuck at about 1050; the applications and the generator on both sides were raised to 65536.

## Comparison results

| Round | Implementation | Target writes/s | Completed writes | Propagation P95 ms | App CPU seconds | Throttled periods | App peak memory MiB* | OOM |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Fyrlet | 500 | 9732 | 9.74 | 15.3 | 1 | 636 | 0 |
| 2 | Meteor | 500 | 2917 | 498.84 | 34.1 | 22 | 554 | 0 |
| 3 | Meteor | 500 | 1995 | 933.48 | 38.8 | 21 | 539 | 0 |
| 4 | Fyrlet | 500 | 9895 | 1.98 | 12.4 | 3 | 727 | 0 |
| 5 | Fyrlet | 100 | 2000 | 3.25 | 6.8 | 2 | 680 | 0 |
| 6 | Meteor | 100 | 2000 | 14.15 | 31.1 | 3 | 553 | 0 |
| 7 | Meteor | 100 | 2000 | 253.96 | 35.6 | 5 | 524 | 0 |
| 8 | Fyrlet | 100 | 1975 | 4.56 | 9.5 | 1 | 627 | 0 |

\* `memory.peak` includes the page cache and is not RSS; it is suitable only for comparing relative changes within the same implementation. App CPU seconds include the connection and warmup phases; at 100 writes/s connection setup is a large share, so it cannot be divided directly by the number of writes to get CPU per write.

Reading:

- 500 writes/s: Fyrlet completed about 97–99% of the target writes; Meteor completed only 20–29%, with CPU throttled for 21–22 periods, meaning 1 core was saturated.
- 100 writes/s: both sides completed all target writes. Fyrlet's P95 was 3.3 and 4.6 ms; Meteor's two runs were 14.2 and 254.0 ms, an 18-fold difference, which only shows that Meteor is already close to the single-core limit under this load and cannot give a stable figure.
- Memory stayed within 1 GiB on both sides, with no OOM.
- In all rounds the final complete view was verified correct, and the intermediate delivery coverage of accepted writes was 100%.

### Why higher rates were not tested

When the target rate was raised to 900 and 1300 writes/s, it was the **load generator** (single-threaded Node) that first dropped ticks (`generatorDropped`), while Fyrlet's cgroup throttling was 0. Under the rules in FAIRNESS.md, a point where the generator drops ticks cannot demonstrate the server's capacity limit, so this comparison cannot give Fyrlet's capacity limit.

## Conditions that are not aligned

- **Authentication guarantees**: before every push Fyrlet re-reads the session and checks expiry and revocation; the write transaction takes a `FOR SHARE` lock on the session and uses an advisory lock to serialize requests with the same key, and there is also a durable fallback notification. Meteor checks the session only once, at login and subscription, and relies on a timer for expiry. Fyrlet does more.
- **Write acknowledgement strength**: Meteor's writes use MongoDB multi-document transactions with `readConcern: snapshot` plus `writeConcern: majority`; the PostgreSQL side uses the default commit. The two sides are not aligned item by item, which is unfavourable to Meteor.
- **Fixed architectural cost**: Meteor handles DDP, EJSON, oplog tailing and the per-connection mergebox in a single Node event loop, and they contend with each other under a one-core limit; Fyrlet computes the same subscription only once. This is an inference from reading the code; **no CPU profiling was done on Meteor**.
- The multi-core group (4 vCPU / 4 GiB, Meteor multi-process with a sticky proxy) was not run; database flushing and write acknowledgement were not aligned item by item; the load covers only "updating existing records".

## Fyrlet single-core profile (500 writes/s)

During the steady write phase, observed with `:msacc` and reductions summed by process type:

- The scheduler was about 53% busy; **500 writes/s did not saturate Fyrlet at 1 vCPU**.
- Share of reductions: write handling (`OperationChannel`) about 51%, Bandit connection processes about 9%, session check shards about 10% combined, Oban producers about 5.8%, Observers about 5%.
- Only when the application was squeezed to 0.4 vCPU did CPU become the bottleneck, but two repetitions of the same baseline already differed by about ±20% (completed writes 7464 vs 9909), so a measurable gain needs at least 3 alternating repetitions.
- The idea of merging the advisory lock and the idempotency SELECT into one statement **does not hold**: under READ COMMITTED, after waiting for the lock within a single statement the snapshot is already fixed, so the just-committed idempotency row cannot be seen, which leads to duplicate execution.

The remaining candidates on the write path (merging the session check with the advisory lock, inserting a placeholder idempotency row first) are each expected to save 1 database round trip, on the order of 10%, which is below the current noise and was not implemented.

## Reproduction and current state

The Dockerfile and run scripts used for the comparison currently exist only in `.local/fair/` on the local machine, contain local absolute paths and a temporary `docker` wrapper script, and **have not yet been turned into a reusable tool**. Reproduction requires:

1. Build the Fyrlet image with `mix release` (the runtime layer must match the build layer's glibc version; this run used `debian:trixie-slim`); build the Meteor bundle with `meteor build --server-only --architecture os.linux.aarch64` and put it into `node:24.22.1`.
2. In a Linux virtual machine, start the application, database and generator containers with `--cpus`, `--memory`, `--memory-swap` and `--cpuset-cpus`, and raise the file descriptor limit to 65536.
3. Run in the external endpoint mode of `bench/runner.mjs --endpoint ... --fixtures ...`, re-seeding the data every round, alternating the execution order, and reading the container cgroup counters before and after each run.

Fyrlet is seeded with `bench/fixtures/seed.exs`; Meteor with `seed()` in `bench/adapters/meteor.mjs`, and `runId` must match `bench-<digits>-<8 hexadecimal digits>`.

## Still not covered

End-to-end add/delete load tests, 24-hour stability, the multi-core group, CPU profiling of Meteor, alignment of the authentication and write-acknowledgement guarantees, and cold-start and disconnect-recovery comparison.

## Shared rooms and append streams compared end to end (2026-11-07)

This group uses the Chat domain application with real PostgreSQL / HTTP / WebSocket. 25 users with different subjects and different sessions join a room in the same project, write one after another, and after each write wait for all clients to receive the corresponding content. Each mode does 20 writes per round, for 3 rounds; the message mode first fills the 100-item live window, with each text 128 bytes. The SDK has field-level `delta-v1` turned off, and compares ordinary private snapshots against `sharing: identical`, and full message snapshots against append. Raw report: [shared-2026-11-07.json](bench/shared-2026-11-07.json).

| Mode | View builds per round | Snapshot data encodings per round | Database queries per round | Downstream application payload bytes per round | p50 range per round (ms) | p95 range per round (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Room private snapshot | 500 | 500 | 2435–2478 | 240300 | 14.04–15.24 | 16.66–21.57 |
| Room public shared projection | 20 | 20 | 1586–1590 | 240300 | 13.33–13.78 | 14.21–16.28 |
| Latest 100 messages, full snapshot | 500 | 500 | 3036–3053 | 13531300 | 13.51–14.32 | 14.87–25.35 |
| Latest 100 messages, append | 0 | 0 | 2330–2358 | 209300 | 13.93–16.20 | 15.45–18.79 |

For the same room projection, query construction and snapshot data encoding were both reduced by **96%**, from 25 copies per update to 1; the per-connection envelope and network send remain, so the downstream payload is the same before and after sharing. The encoding count comes from actual `fyrlet.subscription.serialize` calls, is not inferred from the number of connections, and does not include per-connection protocol envelope encoding. Message append reduces downstream application payload by **98.45%** compared with sending the whole 100-item window; it does not go through the ordinary Observer snapshot encoding path, so the 0 in the table does not mean there is no serialization cost.

In the three normal-update rounds of append, the `gap` / `overflow` / `refresh` fallbacks were all 0. In each round one subscription is additionally refreshed explicitly, asserting that exactly 1 `refresh` snapshot fallback occurs; the refresh traffic and counts are outside the table's measurement window. Slow clients, window overflow and cursor invalidation are still covered by the core channel tests; this group does not let the happy path stand in for those failure tests.

Statistical boundaries: database queries include session and per-member authorization, operation transactions, durable notifications and background jobs, with no security checks turned off. Byte counts are the UTF-8 size of application messages received by the client over WebSocket, excluding HTTP responses, the initial snapshot, TLS or WebSocket frame headers. Latency includes the HTTP write and the 10ms polling while waiting for all clients; the ranges in the table are the per-round quantile ranges across the three rounds, not quantiles of the pooled samples. The test order is fixed, there is no CPU / memory isolation, and this is a single-node comparison on a local development build, so it cannot be used as a latency advantage or a production capacity commitment. This run was repeated after the shared-subscription revocation fix, and the raw data and the table were replaced with this round's results.

There is also a correctness and resource-cleanup verification on the same machine with two nodes, 120 seconds and 12 clients, which measured 2056 messages and 41 reconnections/renewals, with all history free of gaps or duplicates, and subscriptions, Observers and read caches back to zero after connections closed; see [ACCEPTANCE.md](ACCEPTANCE.md) and the [two-node raw report](bench/cluster-2026-11-07.json). It contains no isolated cache performance comparison and cannot be used to infer cross-host capacity or long-term stability.

Reproduction (separate `chat_benchmark` database, HTTP 4185, metrics 4186):

```sh
bash scripts/shared_bench.sh
FANOUT=10 POSTS=10 ROUNDS=3 bash scripts/shared_bench.sh
```

`SHARED_BENCH_DATABASE_URL`, `SHARED_BENCH_PORT` and `SHARED_BENCH_METRICS_PORT` can override the connection. The metrics service starts only in explicitly enabled local non-production tests; after the test the service process is shut down, and the report is written to `.local/bench/`. It holds the counter table in a separate long-lived process so the counts are not lost after the start script returns; any metrics interface failure or empty telemetry counts makes the acceptance fail.
