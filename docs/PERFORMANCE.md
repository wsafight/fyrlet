# Performance comparison

The Fyrlet/Meteor and shared-stream comparisons below were measured on November 7, 2026. A November 8 current-worktree baseline is recorded separately; it does not update the Meteor comparison. For optimization methods, evidence and reverted experiments see [OPTIMIZATIONS.md](OPTIMIZATIONS.md).

## Current-worktree baseline (November 8, 2026)

Production release, application 1 vCPU / 1 GiB, PostgreSQL 2 vCPU / 2 GiB, disjoint CPU sets, four generator shards, 1,000 users × two observing devices (3,000 connections), 50 records × 128 bytes per user. Each point ran for 20 seconds, three times, reversing rate order on the middle round. Default invalidation mode was used. [Sanitized evidence](bench/readiness-performance-2026-11-08.json) retains the measured source fingerprint and resource settings.

| Offered writes/s | Completed writes per run | Propagation p95 range | Application CPU seconds | Sampled anonymous peak MiB |
| --- | --- | --- | --- | --- |
| 100 | 2,000 / 2,000 | 5.86–6.43 ms | 7.20–8.50 | 560–578 |
| 500 | 9,993–10,000 / 10,000 | 5.43–6.78 ms | 15.03–16.03 | 648–657 |

All six runs passed the stated SLO (p95 ≤250 ms, delivery coverage ≥99%, dropped offered slots ≤1%); observed delivery coverage was 100%, with no OOM. Two 500/s runs dropped 4 and 7 generator slots. These are measured offered-rate points, not a capacity maximum. Only existing-record updates are covered, without explicit view confirmation, automatic retry, React rendering, OIDC traffic or TLS. CPU includes connection setup/warmup. Local correctness checks overlapped part of this baseline; cgroups isolate VM resources, not the physical host. Do not interpret the small latency range as a production promise or compare it directly with earlier Meteor runs.

Reproduce with `GENERATORS=4 SETUP_BUDGET_S=20 node bench/fair/scan.mjs --image fair-fyrlet:current --rates 100,500 --repeats 3 --duration-ms 20000 --label UNIQUE_LABEL` after the setup/build commands in [bench/fair/README.md](../bench/fair/README.md). The measured image predates later report-validation refinements; its exact fingerprint is retained in the evidence.

The raw run data is in `.local/fair/` on the local machine (ignored by version control) and is not committed with the repository. For the comparison conditions and the thresholds for drawing conclusions see [bench/FAIRNESS.md](../bench/FAIRNESS.md).

## Optional PostgreSQL notifications: no demonstrated speedup (November 8, 2026)

Two ABBA rounds compared the same production image with default invalidation (A) and `FYRLET_POSTGRES_INVALIDATION=true` (B), both with durable invalidation off. Each side ran four times at 500 offered writes/s for 20 seconds with the baseline resource limits, 1,000 users and two observing devices. Image/source identity matched in every run; the [sanitized evidence](bench/readiness-performance-2026-11-08.json) retains all eight results, including SLO failures.

| Metric, median (range) | A: default | B: PostgreSQL notifications |
| --- | --- | --- |
| Completed writes of 10,000 | 9,941.5 (7,130–9,987) | 9,760 (8,181–10,000) |
| Propagation p95 ms | 29.5 (8.98–348.90) | 81.1 (6.26–267.39) |
| Application CPU seconds | 17.9 (17.04–26.24) | 19.9 (18.84–24.53) |
| Sampled anonymous peak MiB | 681.8 (651.9–723.8) | 692.6 (655.9–724.4) |
| Runs passing SLO | 3/4 | 2/4 |

All eight runs passed correctness checks, delivered 100% of expected deliveries for completed writes, and had no OOM. The physical host was not isolated: an unrelated high-CPU process was observed during the suite, and both variants varied substantially. **This does not demonstrate a speedup or stable capacity.** The option remains off by default; its transactional notification semantics, rather than a performance gain, are the reason to evaluate it. It is not a durable delivery queue and does not replace reconciliation or `durable_invalidation: true`. See [optimization log, section 17](OPTIMIZATIONS.md#17-optional-transactional-postgresql-notifications-2026-11-08).

Reproduction after building one image: `IMG_A=fair-fyrlet:readiness IMG_B=fair-fyrlet:readiness EXTRA_B='-e FYRLET_POSTGRES_INVALIDATION=true' GENERATORS=4 SETUP_BUDGET_S=20 bash bench/fair/abba.sh 500 2 UNIQUE_LABEL`. An isolated host and longer repetitions are still needed before drawing performance conclusions.

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

*Update (sharded generator):* the generator can now be split across processes (`GENERATORS=N`, see [`bench/fair/`](../bench/fair/README.md)). In one pair of runs at 1000 writes/s, 1 vCPU, a single generator process dropped 5204 of 20000 ticks itself, while 4 shards dropped 271, so the generator is no longer the first limit at this rate. This does **not** establish the server's capacity: repeated runs of the same 4-shard configuration completed anywhere from 70% to 99% of the offered writes (13.9k/20k, 26.9k/30k, 28.1k/30k, 19.9k/20k), and 1000 writes/s sits at the edge of what one vCPU sustains. Capacity needs a rate sweep with at least 3 alternating repetitions per point. The rest of this section describes the earlier single-generator runs.

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

The **Fyrlet side** is now reproducible with the scripts in [`bench/fair/`](../bench/fair/README.md) (limited PostgreSQL, release image, single run, A B B A alternation, sharded generator). The **Meteor side** (Dockerfile, MongoDB replica set, runner) still exists only in `.local/fair/` on the local machine with local absolute paths, and has not been turned into a reusable tool. The original reproduction steps were:

1. Build the Fyrlet image with `mix release` (the runtime layer must match the build layer's glibc version; this run used `debian:trixie-slim`); build the Meteor bundle with `meteor build --server-only --architecture os.linux.aarch64` and put it into `node:24.22.1`.
2. In a Linux virtual machine, start the application, database and generator containers with `--cpus`, `--memory`, `--memory-swap` and `--cpuset-cpus`, and raise the file descriptor limit to 65536.
3. Run in the external endpoint mode of `bench/runner.mjs --endpoint ... --fixtures ...`, re-seeding the data every round, alternating the execution order, and reading the container cgroup counters before and after each run.

Fyrlet is seeded with `bench/fixtures/seed.exs`; Meteor with `seed()` in `bench/adapters/meteor.mjs`, and `runId` must match `bench-<digits>-<8 hexadecimal digits>`.

## Still not covered

Sustained mixed-operation saturation tests, 24-hour stability, the multi-core group, CPU profiling of Meteor, alignment of the authentication and write-acknowledgement guarantees, and cold-start and disconnect-recovery comparison. A short Fyrlet-only add/delete and density drill is recorded below, not a capacity result.

## Mixed operations and observer density drill (2026-11-08)

The mixed runner cycles add, update, archive, restore and delete, reads paginated history after each delete, and explicitly confirms every observer after each write. It compares complete records and window refill, rejects duplicates/authorization leakage, and checks final history. Offered rate counts writes, not the additional reads or confirmations; unfinished five-write cycles finish outside the paced window. `scan.mjs` now crosses user, device and rate lists, repeating every point at least three times and reversing point order on alternate rounds.

The measured snapshot used 10 users, 50 initial rows per user, 128-byte text, shared per-user sessions, two generator processes, 20 offered writes/s and a five-second paced window. Application limits were 1 CPU / 1 GiB, PostgreSQL 2 CPU / 2 GiB, swap disabled, with non-overlapping application/database/generator CPU sets. Each run completed 100 writes (20 of each write kind) with 100% observer delivery coverage, no generator drops and no OOM. The one-device and four-device points produced 100 and 400 confirmations per run, respectively.

| Devices per user | Per-round confirmation-inclusive p95 (ms) | Per-round application CPU (s) | Sampled anonymous-memory peak (MiB) |
| --- | --- | --- | --- |
| 1 | 13.08 / 11.15 / 12.53 | 0.642 / 0.738 / 0.638 | 119.25–121.50 |
| 4 | 11.10 / 27.10 / 11.32 | 0.668 / 0.989 / 0.762 | 123.22–128.14 |

Sanitized evidence, exact quantiles, resource limits, image identifiers and the measured source fingerprint are in [mixed-density-2026-11-08.json](bench/mixed-density-2026-11-08.json). Local detailed reports are under `.local/fair/mixed-density-final-20261108.json` and its run directories. CPU includes setup/warmup and cycle completion; memory is a sampled cgroup anonymous peak, not process RSS. An unrelated Node process consumed over 400% physical-host CPU. These **short, low-rate runs validate the harness, not server saturation, speedup or production capacity**. Latency includes explicit confirmation and polling and is not comparable to passive update-only propagation or Meteor. External OIDC, automatic retries, TLS, multi-host faults and 24-hour stability remain outside this drill.

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
