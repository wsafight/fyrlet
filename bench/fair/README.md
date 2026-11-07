# Limited-resource Fyrlet runs

Reusable scripts for the cgroup-limited setup described in [PERFORMANCE.md](../../docs/PERFORMANCE.md) (application 1 vCPU / 1 GiB on cpuset 0, PostgreSQL 2 vCPU / 2 GiB on cpuset 1-2, generator on cpuset 4-9). They cover Fyrlet only; the Meteor side of the earlier comparison is not included.

Requirements: a Linux Docker daemon that enforces cgroup v2 limits (on macOS, a Colima VM), Elixir for seeding, and a checkout that builds with `mix`. Point `DOCKER` at the daemon:

```sh
export DOCKER="colima ssh --profile fairbench -- sudo docker"   # default: docker
bash bench/fair/setup.sh                                         # network + limited PostgreSQL (idempotent)
bash bench/fair/build.sh fair-fyrlet:current                     # release image of the working tree
GENERATORS=4 bash bench/fair/run.sh fair-fyrlet:current 1000 try1 20000
```

`run.sh <image> <rate> <tag> [duration_ms]` re-creates and re-seeds the database for every run, starts the application under the limits, runs the soak workload, and prints one `RESULT` line with completed writes, propagation P95, delivery coverage, application CPU seconds, throttled periods, memory, OOM count, peak anonymous memory and the number of ticks the generator dropped. Raw output stays under `.local/fair/runs/<tag>/`. Environment knobs: `CPUS`, `EXTRA` (more `docker run` flags), `ERLF` (`ERL_AFLAGS`), `USERS`, `DEVICES`, `ROWS`, `PAYLOAD`, `GENERATORS`, `SETUP_BUDGET_S`.

`abba.sh <rate> <rounds> <label>` alternates two images (or two settings of one image) as A B B A and summarises medians and ranges. Build a baseline from another revision with `git worktree add` and `build.sh <tag> <worktree>`; seeding always uses the working tree, so only the image differs.

## Sharded generator

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
