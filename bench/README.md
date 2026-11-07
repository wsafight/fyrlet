# Fyrlet benchmarks

English | [简体中文](README.zh-CN.md)

See the [performance comparison](../docs/PERFORMANCE.md) for the latest comparison under equal resource budgets, and the [optimization log](../docs/OPTIMIZATIONS.md) for the changes behind it.

This directory contains repeatable Fyrlet baselines, a Meteor inbox reference application, shared scenarios and result reports. Verify business correctness before interpreting performance numbers. Local smoke runs do not establish capacity or product rankings.

Future Meteor / Fyrlet comparisons used to support performance conclusions follow the [equal-conditions specification](FAIRNESS.md): equal application and database resource limits, business guarantees, load and warmup, with separate single-core and multicore budgets. The current local launcher does not enforce resource limits. Cross-implementation reports are marked `observational-only` and cannot establish rankings under equal resources. Reports check the complete workload, source fingerprints and host information. The launcher aborts the comparison if source files change before or after measurement.

## Quick start

Use the project's Elixir / Erlang versions, PostgreSQL and Node ≥ 22. The local Fyrlet launcher uses production configuration, connects to the separate `fyrlet_bench` database by default, and listens on port 4200.

```sh
bash scripts/postgres.sh start
bash scripts/bench.sh --profile smoke
bash scripts/bench.sh --scenario fanout --devices 50 --repeats 3
```

The launcher builds the SDK, compiles the server, migrates the database, creates a test project, starts the service, runs the workload and stops the service processes it started. By default, it deletes the current run's test project and retains the database and reports. Development projects are preserved. Set `BENCH_DATABASE_URL` to use another database and `--port` to choose the local service port.

Results are written to `.local/bench/<run-id>/` by default:

```text
<target>/results.json    Raw samples, per-round statistics, environment and capabilities
<target>/report.md       Report for one implementation
comparison.md           Report for all implementations in this run
private/<target>/       Credentials and logs with mode 0600; parent directory mode 0700
```

Use `--out PATH` to choose the report directory. Credentials always stay in the ignored `.local/` directory and are excluded from JSON reports. `--keep-data` retains the current run's test data for debugging. Sessions expire after 15 minutes by default; longer workloads require separate session renewal management.

## Meteor reference

The reference application lives in `apps/meteor/` and pins Meteor 3.5.4. It uses a MongoDB replica set, cursor publications, DDP deltas, version-conditional updates, and a single transaction for business updates and successful idempotency results.

The installation script puts the official toolchain in `.local/meteor-toolchain/` without installing system commands or changing shell configuration. The download is about 486 MiB and requires more space after extraction. To use an existing Meteor CLI, set `METEOR_BIN` to its absolute path.

```sh
bash scripts/bench-meteor.sh
bash scripts/bench.sh --target meteor --profile smoke
bash scripts/bench.sh --target all --profile smoke
```

If a proxy is needed, pass its environment variables to both installation and execution. `NO_PROXY` keeps local test traffic directly connected to the services.

```sh
HTTPS_PROXY=http://127.0.0.1:7890 \
HTTP_PROXY=http://127.0.0.1:7890 \
NO_PROXY=localhost,127.0.0.1,::1 \
bash scripts/bench-meteor.sh

HTTPS_PROXY=http://127.0.0.1:7890 \
HTTP_PROXY=http://127.0.0.1:7890 \
NO_PROXY=localhost,127.0.0.1,::1 \
bash scripts/bench.sh --target all --profile smoke
```

The first Meteor run also resolves and downloads application packages. Startup waits up to 180 seconds by default; use `--startup-timeout-ms 600000` to extend it. The launcher uses `meteor run --production`: the application build is optimized, but resource statistics include the Meteor CLI and proxy. This differs from directly deploying a built Node bundle. Meteor's bundled MongoDB uses a separate local database. Fyrlet uses the project's existing PostgreSQL cluster by default, so resource statistics include other background activity in that cluster. Reports record these differences explicitly.

The reference application is for isolated local testing and requires a random `BENCH_SECRET` at startup. The local launcher generates it; fixture and cleanup endpoints accept only that secret. Do not deploy this application as a public business service.

## Scenarios

| Scenario | Standard default size | Behavior and correctness |
| --- | --- | --- |
| fanout | 1 user × 10 observers | Update existing records and wait for every observer to apply each result |
| isolated | 10 users × 1 observer | Run users in parallel and verify that each view contains only its user's records |
| burst | 1 user × 5 observers | Wait for each write acknowledgment, then wait for all views to converge; intermediate states may be coalesced |
| reconnect | 5 users × 2 observers | Disconnect observers, update records, reconnect them together and verify the latest complete view |
| slow | 1 user × 2 observers | Delay consumption of every transport message for the last observer in each group and verify eventual convergence |
| idle | 10 users × 2 observers | Keep subscriptions open without writes and observe resources and periodic traffic |
| soak | 100 users × 2 observers | Sustain a global target write rate, allow at most one write per user awaiting all observers, and record unserved target slots |

Each user also gets a write client. Fyrlet writers call business operations through SDK Socket RPC without subscribing. Meteor writers call DDP Methods without publications. Observers on both sides subscribe to the same scope; writers are excluded from propagation-latency samples.

The standard profile seeds 50 records per user, each with 128 bytes of text, warms up with 5 writes per scenario, measures 30 writes and repeats 3 rounds by default. The smoke profile uses less data and one round. Each update preserves the record count and text byte size. Initial data uses a trusted fixture path outside the measured interval.

```sh
bash scripts/bench.sh --scenario isolated --users 100 --devices 2 \
  --rows 50 --payload-bytes 512 --writes 100 --warmup 10 \
  --concurrency 10 --repeats 3 --label local-100-users
```

`--writes` sets writes per user. `--concurrency` controls concurrent user write loops; writes within each user remain sequential to avoid accidental version conflicts. Observers begin recovery together. Use `--interval-ms` for the interval between writes, `--idle-ms` for idle duration and `--delay-ms` for slow-client consumption delay. Slow clients simulate application read delay rather than operating-system TCP throttling. Their receive queues are bounded, and reports include the peak queue size per client.

## Sustained load and capacity steps

Local Meteor workloads connect directly to the fixed `--app-port` (public port + 2), bypassing the development proxy. Resources still record the actual Node process and complete process tree separately. Older reports went through the proxy; distinguish them by date and startup mode rather than treating them as the current direct-connection baseline. The user limit is 5000 and the total observer limit remains 5000. A workload with 5000 users × 1 observer has 10000 connections including writers.

`all` retains the original six functional scenarios. Select the longer `soak` scenario explicitly. `--rate` is the global target writes per second. `--duration-ms` defaults to 60 seconds and is capped at 10 minutes. These replace `--writes` for this scenario. The runner rotates users across scheduled slots. It records an unserved slot when a user is still awaiting convergence or the concurrency limit is reached, without issuing catch-up bursts when the generator falls behind. Reports distinguish busy, concurrency and generator skips, and retain latency and delivery statistics for each 10-second interval.

```sh
npm --prefix sdks/typescript run build
ERL_FLAGS='+S 4:4 +sbwt none +sbwtdcpu none +sbwtdio none' \
node bench/capacity.mjs --levels 100,500,1000 --rates 200 \
  --devices 2 --duration-ms 60000 --repeats 2 \
  --out .local/bench/capacity-example

bash scripts/bench.sh --target all --scenario soak --users 1000 --devices 2 \
  --concurrency 64 --rate 200 --duration-ms 180000 --warmup 1 --repeats 1
```

`capacity.mjs` starts independent services sequentially and writes raw results for every round plus `capacity.json` / `capacity.md`. By default, each round must finish correctly, achieve propagation P95 ≤ 250 ms and delivery coverage ≥ 99%, skip ≤ 1% of target slots, and avoid runner stalls longer than 1 second. Adjust thresholds with `--p95-ms`, `--min-coverage` and `--max-drop-rate`. A load point fails if any round fails. The report describes measured load points without extrapolating maximum production users. Combine user counts and target rates to distinguish connection scale from active write pressure.

Each user includes a writer connection, so 1000 users × 2 observers means 3000 WebSocket connections. Reports preserve connection / warmup, steady-load and post-close resources separately. For soak, `--settle-ms` defaults to 2000 to observe resources after close; RSS staying high alone does not prove a leak. Meteor runtime diagnostics read the pinned version's private `_observeMultiplexers` / `_observeDriver` and record the actual driver and logged-in session count. Normal shutdown sends DDP disconnect to avoid the default 15-second recovery retention window affecting the next round. Brief abnormal disconnects recover with session / receivedCount, falling back to resubscription on mismatch.

Long-running latency series retain at most 100,000 samples, then use uniform reservoir sampling for percentiles. Count, minimum, maximum and mean remain exact. Delivery markers are released as soon as all deliveries complete; incomplete markers are capped at 100,000. Application, database and runner resources are sampled every 250 ms, preserving RSS start, end, mean and trend plus runner heap and event-loop stalls. `applicationWorker` records the actual BEAM / Node service PID separately and is a subset of the `application` process tree; do not add them. This excludes the Meteor CLI and proxy from the individual Node application's numbers. Summed process-tree RSS can still count shared pages more than once.

Keep source files fixed during a run and avoid concurrent builds, tests or other benchmarks. On macOS, prefix a command with `caffeinate -is` to prevent idle sleep. Long stalls caused by sleep, host suspension or runner saturation invalidate capacity inference. Sessions default to 15 minutes; allow initialization time for long runs.

By default, `--sessions shared` gives all devices and the writer for one user the same session, enabling Fyrlet Observer reuse. `--sessions device` issues a separate session for each writer and device while retaining the same user and business data. Fyrlet then isolates Observers by session; Meteor can still share its Mongo observer for identical queries. Interpret the two modes separately. Results using shared login sessions do not establish capacity for independently authenticated devices.

```sh
bash scripts/bench.sh --target all --scenario soak --users 1000 --devices 5 \
  --sessions device --rate 200 --duration-ms 60000 --concurrency 64 --warmup 1 --repeats 1
```

Propagation timing and live convergence checks use id / text / version. After timing ends and resource sampling stops, the runner strictly compares every complete record, including dates and other business fields. This final check is excluded from propagation latency and the target-rate window.

## Measurement definitions

- `propagationMs`: time from immediately before a write until another client applies the same server text marker. One runner's monotonic clock measures the request, transaction, notification, transport and client application, excluding the writer's optimistic result.
- `writeMs`: time from a write request to its successful response. The Meteor driver waits for DDP `result` and `updated`; the current Fyrlet driver waits for a successful Socket RPC reply, while older reports used HTTP success. Reports preserve these different protocol completion conditions.
- `firstReadyMs`: time from creating an observer until its complete view is ready, including identity and connection initialization. Samples are collected before warmup; parallel initialization can introduce queuing.
- `recoveryMs`: time from starting reconnection for a batch of observers until each applies the latest data written while offline. This measures application rejoin; the runner explicitly reconnects the Meteor driver.
- `writeRequestsPerSecond`: observed request rate for the current closed-loop round. Fanout / isolated wait for observers after every write; burst / slow wait only for write acknowledgment. This does not measure maximum server throughput. `convergedWritesPerSecond` applies only to scenarios that await convergence after each write.
- `deliveryCoverage`: observed intermediate changes divided by potential observations. High-frequency, offline and slow-client scenarios may coalesce changes. Interpret latency percentiles together with this ratio; the final complete view must still be correct.
- `traffic`: HTTP JSON body and WebSocket application payload bytes after warmup, excluding handshakes, frame headers, HTTP headers, TLS and compressed wire traffic. Both sides materialize snapshots and deltas with identical record counts and field scopes.
- `resources`: process-tree RSS and changes in cumulative CPU time sampled every 250 ms, with application and database recorded separately. Runner RSS, CPU and event-loop delay are also recorded. Sampling can miss short-lived children, and summed RSS can duplicate shared memory. CPU precision is limited in short rounds.

Results retain raw latency samples and compute nearest-rank percentiles independently for each round rather than averaging round P95 values. Failed scenarios retain completed results and exit with a nonzero status without producing a successful ranking.

Every view is checked for record count, ID range, duplicate IDs and final text / version. Records from another user, missing final records or incorrect final versions fail the run. The current workload updates existing records. Inserts, deletes, movement into and out of windows, team permissions, service crashes, revocation and idempotency races require application tests or future scenarios.

## Comparison boundaries

ACK currently uses notifications without replies, and deltas use compact fields and tuples. For pure field replacements in immutable views, the SDK reuses its ID index while copying the result array and preserving historical snapshots. Run `node --expose-gc bench/views.mjs` to measure the SDK update path separately with 50 / 100 records. It alternates 5 rounds of 10,000 updates by default and writes raw JSON to `.local/bench/views-*.json`. This measures local SDK processing rather than server capacity or end-to-end latency.

Fyrlet uses negotiated field deltas and ACK, with complete snapshots for initial joins and recovery. The current driver calls operations through the public SDK with `operationTransport: socket`. Meteor uses DDP deltas and Methods. Both retain their normal synchronization paths. Older Fyrlet reports may use HTTP writes or full snapshots; check report capabilities and source fingerprints. The Meteor driver is a small Node DDP materializer without full Minimongo, client optimistic stubs or automatic recovery policies. Client CPU therefore does not compare two complete frontend SDKs.

Both implementations provide project / user filtering, version-conditional updates, short-lived random sessions and transactional idempotency. Fyrlet reauthorizes snapshot queries, serializes revocation with writes, broadcasts immediately after the outermost transaction commits, retains durable Oban notifications as a fallback, and skips automatic refreshes whose content is unchanged. The Meteor reference validates sessions for Methods / publications and uses timers for subscription expiry, but does not implement equivalent per-snapshot reauthorization or revocation / write serialization. Database and durable-notification paths also differ. Reports include a capability matrix and do not present the numbers as engine rankings with identical guarantees.

The suite currently excludes separate plain-Phoenix connection / broadcast baselines, cross-node capacity, database query counts per write, system-level network throttling and failure-recovery load testing. These can be added as independent scenarios rather than merged into one QPS number.

## External deployments and multiple reports

The local launcher supports development regression checks. Formal comparisons should fix the machine and resource budget, use a separate load generator, and record database topology, durability and replication settings, generator size and all versions. The runner can connect to services you manage. See the fixture scripts and Meteor seed response for fixture formats. These files contain short-lived user tokens and must remain private.

```sh
node bench/runner.mjs --target fyrlet --endpoint https://benchmark.example \
  --fixtures /private/credentials.json --out .local/bench/remote \
  --scenario isolated --users 10 --devices 1 --rows 50

node bench/report.mjs .local/bench/run-a/fyrlet/results.json \
  .local/bench/run-b/meteor/results.json > .local/bench/comparison.md
```

Use `--app-pid` / `--database-pid` to sample local processes. Collect remote service resources separately. `BENCH_REVISION` can record the source revision; results also include actual source SHA256 fingerprints. `BENCH_APPLICATION_MODE`, `BENCH_VERSIONS` (JSON), `BENCH_TOPOLOGY` and `BENCH_DATABASE_SHARED` describe external deployment conditions.

## Diagnostics and JSON encoding experiments

`FYRLET_OBSERVER_HIBERNATE_AFTER_MS=infinity` disables Observer idle hibernation, whose default is 1000 ms. The launcher records this option so memory and CPU tradeoffs can be measured against identical source. Fix other parameters and run the implementations sequentially.

Diagnostics can also set `BENCH_MEMORY_INTERVAL_MS=10000` to write `memory.ndjson`, grouping process counts, heap memory, queued messages and binary references by initial module, and collecting total BEAM memory and TCP buffer settings. Binary references may be counted across processes and cannot be summed as exclusive memory. Post-close `runtime.json` records the Observer registry, supervisor counts and BEAM memory to distinguish live state from allocator-retained RSS. Diagnostic runs are excluded from normal performance rankings.

Diagnostics support only local Fyrlet. They additionally record SQL counts, cumulative durations and connection queue time by command and table. `BENCH_EPROF=1` also generates function-call and timing reports. The report explicitly marks instrumentation in `applicationMode`; its time and CPU numbers cannot be compared directly with ordinary runs:

```sh
BENCH_DIAGNOSTICS=1 BENCH_EPROF=1 \
bash scripts/bench.sh --target fyrlet --scenario fanout \
  --devices 20 --rows 50 --writes 500 --warmup 20 --repeats 1
```

`queries.json` and optional `eprof.txt` are written to the current run's `private/fyrlet` directory. Eprof uses the current Erlang installation's bundled tools without adding production dependencies. The process confirms diagnostics are ready before measurement and writes diagnostic files before exit.

The following microbenchmark compares repeated encoding for size checks and sending, reuse of existing encoding, and Jason compile-time macros plus reuse. It verifies identical JSON values and byte counts, including Chinese text, newlines, quotes and backslashes. Each path alternates across 5 rounds:

```sh
ERL_FLAGS='+S 4:4 +sbwt none +sbwtdcpu none +sbwtdio none' \
mix run --no-start bench/json.exs
```

`BENCH_JSON_ITERATIONS` defaults to 10000 and adjusts iterations per round. Results are written to `.local/bench/json-*.json`. Reusing a 50-record snapshot is experimental; production pushes currently reuse encoded bodies only for delta packets. This script compares local encoding work rather than application throughput or complete business latency.

For runtime tuning, set the same `ERL_FLAGS` before an ordinary benchmark command. Reports record only scheduler-related options instead of copying complete VM arguments that might contain credentials. Four schedulers with busy waiting disabled are an option measured on the current machine rather than a default recommendation for every deployment.

## Subscription process footprint

These Elixir microbenchmarks use the test database and do not launch a TCP server:

```sh
FOOTPRINT_LABEL=current FOOTPRINT_BYTES=65536 mix test bench/connection_footprint.exs
FOOTPRINT_LABEL=current FOOTPRINT_BYTES=255000 mix test bench/connection_footprint.exs
FOOTPRINT_LABEL=shared FOOTPRINT_SHARED=1 mix test bench/connection_footprint.exs
mix test bench/tracker_claims.exs
```

`FOOTPRINT_CONNECTIONS` defaults to 40 modelled subjects, `FOOTPRINT_SUBSCRIPTIONS` to five Channels per subject, and `FOOTPRINT_ROUNDS` to six invalidation rounds. No actual network connections are created. Snapshots default to 65,536 bytes; the fixture accepts 1,024–262,144 bytes. Keep the same concurrency, fixture and runtime on both sides of an A/B. Each scope runs sequentially to avoid overloading the single SQL sandbox connection. The production JSON serializer is used; business data is synthetic, while session checks use PostgreSQL.

Reports in `.local/footprint/` record process heaps, unique referenced binaries, VM memory, RSS, query counts, notification-to-receipt P95 and queue lengths after forced GC. They exclude TCP/TLS/Bandit and SDK memory and cannot establish connection capacity or sustained update throughput. `tracker_claims.exs` separately records achieved arrival rates and call latency including process-monitor cleanup. The [controlled report](../docs/bench/connection-footprint-2026-11-07.json) and [interpretation](../docs/OPTIMIZATIONS.md#13-private-subscription-process-and-cache-footprint-2026-11-07) preserve the before/after experiment; running the commands above measures the current checkout only.

## Verification

```sh
npm --prefix bench test
bash scripts/bench.sh --target all --profile smoke
```

Unit tests cover statistical definitions, view validation, workload boundaries, process-tree resource accounting, concurrent-failure cleanup and DDP data / Method completion semantics. A real smoke run verifies that both services and runners work together without establishing a performance ranking.
