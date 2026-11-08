# Limited-resource Fyrlet runs

## Mixed operations and density scans

`scan.mjs` accepts `--users 10,100`, `--devices 1,4` and `--scenario soak|mixed`. Every user/device/rate combination is repeated at least three times; the whole point order reverses on alternate rounds. Points retain their dimensions and only qualify when every repetition passes. Keep each run label unique.

```sh
GENERATORS=2 SETUP_BUDGET_S=20 node bench/fair/scan.mjs --image fair-fyrlet:current \
  --scenario mixed --users 10 --devices 1,4 --rates 20 --repeats 3 \
  --duration-ms 5000 --label UNIQUE_LABEL
```

The Fyrlet-only mixed workload cycles add/update/archive/restore/delete, reads paginated history after each delete, and explicitly confirms every observer after every write. It validates full records, window refill, duplicate/authorization boundaries and final history. Offered rate counts writes, not the additional reads/confirmations. Warmup uses complete five-write cycles; unfinished cycles are completed outside measurement so repetitions start without leftover records. CPU includes that extra work. Propagation includes confirmation and polling, so it is not comparable to passive update-only latency. Sharded reports sum operation counts. Short low-rate scans verify the harness, not saturation, production capacity or 24-hour stability. Automatic retries, external OIDC, TLS and multi-host faults are not covered.

For one direct run use `FAIR_SCENARIO=mixed bash bench/fair/run.sh IMAGE RATE UNIQUE_TAG DURATION_MS`. The default remains update-only `soak`. Build after any benchmark-source changes; labelled source mismatches are not valid current-source scan points.

Reusable scripts for the cgroup-limited setup described in [PERFORMANCE.md](../../docs/PERFORMANCE.md) (application 1 vCPU / 1 GiB on cpuset 0, PostgreSQL 2 vCPU / 2 GiB on cpuset 1-2, generator on cpuset 4-9). They cover Fyrlet only; the Meteor side of the earlier comparison is not included.

Requirements: a Linux Docker daemon that enforces cgroup v2 limits (on macOS, a Colima VM), Elixir for seeding, and a checkout that builds with `mix`. Point `DOCKER` at the daemon:

The build forwards standard proxy build arguments from the Docker CLI environment without embedding proxy values in source files. If package downloads time out in a VM, configure that CLI environment rather than disabling TLS verification.

```sh
export DOCKER="colima ssh --profile fairbench -- sudo docker"   # default: docker
bash bench/fair/setup.sh                                         # network + limited PostgreSQL (idempotent)
bash bench/fair/build.sh fair-fyrlet:current                     # release image of the working tree
GENERATORS=4 bash bench/fair/run.sh fair-fyrlet:current 1000 try1 20000
```

`run.sh <image> <rate> <tag> [duration_ms]` re-creates and re-seeds the database for every run, starts the application under the limits, runs the soak workload, and prints one `RESULT` line with completed writes, propagation P95, delivery coverage, application CPU seconds, throttled periods, memory, OOM count, peak anonymous memory and the number of ticks the generator dropped. Raw output stays under `.local/fair/runs/<tag>/`. Environment knobs: `CPUS`, `EXTRA` (more `docker run` flags), `ERLF` (`ERL_AFLAGS`), `USERS`, `DEVICES`, `ROWS`, `PAYLOAD`, `GENERATORS`, `SETUP_BUDGET_S`.

`abba.sh <rate> <rounds> <label>` alternates two images (or two settings of one image) as A B B A and summarises medians and ranges. Build a baseline from another revision with `git worktree add` and `build.sh <tag> <worktree>`; seeding always uses the working tree, so only the image differs.

## Repeatable rate scans

```sh
GENERATORS=4 node bench/fair/scan.mjs --image fair-fyrlet:current --rates 100,500,800,1000 --repeats 3 --duration-ms 60000 --label baseline
```

At least three repetitions are required; rate order reverses on alternating rounds. Runs and A/B slots use unique directories and refuse overwrites. Build-time image source fingerprints must match the generator checkout. Docker CPU quota, cpuset, memory and swap settings are recorded alongside monotonic cgroup samples. Missing evidence, generator-command failure, correctness failure and OOM fail the run. A failed SLO point is retained, not presented as supported capacity. Generator drops cannot prove server saturation.

The current-revision scan requires matching image/generator sources. A/B deliberately permits different labeled application revisions while recording both fingerprints in every summary; it never permits missing image provenance. Application and database CPU sets must not overlap. The SDK is rebuilt from the frozen source before each run. Named generator containers are removed during cleanup, including cancellation.

Aggregate scan reports and A/B logs also refuse overwrites. A/B verifies the frozen checkout before and after every run, independently of the deliberately different application-image revisions.

Each run writes `summary.json` with resource evidence and an SLO verdict. CPU includes setup and warmup; cgroup current/anonymous memory is not process RSS. This workload updates existing records only. Fixtures are deleted and the application container is stopped on exit; private logs remain under `.local/fair/`. Use unique labels and keep `FAIR_OUT` inside the checkout. `CONCURRENCY` controls total concurrency across shards. Never run two suites concurrently: they share application-container and database names.

To measure the optional notification path, compare the same image with `EXTRA_A="-e FYRLET_DURABLE_INVALIDATION=false"` and `EXTRA_B="-e FYRLET_DURABLE_INVALIDATION=false -e FYRLET_POSTGRES_INVALIDATION=true"`. This measures the cost of an additional transactional notification, not an assumed speedup. Comparison with durable Oban fallback changes the offline-delivery guarantee and must state that difference.

## Sharded generator details

A single Node process drives all observers and writers and drops ticks first at high rates, which hides the server's limit. `GENERATORS=N` starts N runner processes (`--shard I/N`); each drives every N-th user and its share of the rate, and all wait for the same `--start-at` time so the measurement windows coincide. `bench/merge.mjs` combines the shards by pooling raw latency samples (percentiles are exact up to 100 000 samples per shard) and summing counters; per-shard generator data stays under `shards` in the merged result. Per-window latency is not pooled, only the counters. `--concurrency` is divided among the shards (total 64). Raise `SETUP_BUDGET_S` if setup takes longer than 90 s.

## Profiling a running server

Two scripts attach to the release with `bin/inbox_example rpc` while a sharded run is in its load phase. Both wait for activity, then a quiet period, then three consecutive seconds above 300 operations/s, so they skip the warmup burst and the idle gap before `--start-at`. Use `MEM=2g` for the profiled run: sampling adds memory pressure and the application container can otherwise be OOM-killed (CPU limits stay as they are).

- `sampler.exs`: reductions by process type and scheduler thread time by state (`:msacc`) over 10 s.
- `profile.exs`: a stack sampler for the `OperationChannel` processes (no `:tools` needed). Only running/runnable samples count, grouped by top frame and by first Fyrlet frame. Samples are few (hundreds), so treat the split as indicative.

```sh
docker cp bench/fair/profile.exs fair-fyrlet:/tmp/profile.exs
docker exec fair-fyrlet bin/inbox_example rpc 'Code.eval_file("/tmp/profile.exs")'
```

Start `run.sh` first (with `GENERATORS=4 MEM=2g SETUP_BUDGET_S=30`) and run the two commands once the container answers.
