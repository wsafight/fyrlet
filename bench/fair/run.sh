#!/usr/bin/env bash
# One limited-resource run of a Fyrlet image under the soak workload.
# usage: [CPUS=1] [EXTRA="-e K=V"] [ERLF="+sbwt none"] [USERS=1000] run.sh <image> <rate> <tag> [duration_ms]
# The database is re-created and re-seeded from the working tree for every run, so only the image differs.
set -euo pipefail
. "$(dirname "$0")/env.sh"
cd "$ROOT"
IMG=$1; RATE=$2; TAG=$3; DUR=${4:-20000}
USERS=${USERS:-1000}; DEVICES=${DEVICES:-2}; ROWS=${ROWS:-50}; PAYLOAD=${PAYLOAD:-128}
N=${GENERATORS:-1}
SCENARIO=${FAIR_SCENARIO:-soak}
[[ "$SCENARIO" = soak || "$SCENARIO" = mixed ]] || { echo 'Invalid fair scenario' >&2; exit 1; }
[[ "$TAG" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,95}$ ]] || { echo 'Invalid run tag' >&2; exit 1; }
for value in "$RATE" "$DUR" "$USERS" "$DEVICES" "$ROWS" "$PAYLOAD" "$N"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo 'Workload values must be positive integers' >&2; exit 1; }
done
[[ "$N" -le 64 && "$N" -le "$USERS" && "$N" -le "$RATE" ]] || { echo 'Invalid generator count' >&2; exit 1; }
OUT="$OUT_ROOT/runs/$TAG"
[[ ! -e "$OUT" ]] || { echo "Run already exists: $OUT" >&2; exit 1; }
mkdir -p "$OUT"
REL_OUT="${OUT#"$ROOT"/}"
[[ "$REL_OUT" != "$OUT" ]] || { echo 'FAIR_OUT must be inside this checkout' >&2; exit 1; }
FIX="$OUT/fixtures.json"
chmod 700 "$OUT"
SAMPLER=
generator_pids=()
generator_containers=()
for index in $(seq 0 $((N - 1))); do generator_containers+=("fair-gen-$TAG-$index"); done
generator_containers+=("fair-gen-$TAG-merge")
cleanup() {
  [[ -z "$SAMPLER" ]] || kill "$SAMPLER" 2>/dev/null || true
  for pid in "${generator_pids[@]:-}"; do
    [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
  done
  rm -f "$FIX"
  $DOCKER rm -f fair-fyrlet "${generator_containers[@]}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
npm --prefix sdks/typescript run build > "$OUT/sdk-build.log" 2>&1

$DOCKER rm -f fair-fyrlet fair-gen >/dev/null 2>&1 || true
$DOCKER start "$PG" >/dev/null 2>&1 || true
for _ in $(seq 30); do $DOCKER exec "$PG" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
$DOCKER exec "$PG" psql -U postgres -qc "DROP DATABASE IF EXISTS fyrlet_bench WITH (FORCE)" >/dev/null

( export MIX_ENV=prod DATABASE_URL="ecto://postgres:postgres@127.0.0.1:$PG_HOST_PORT/fyrlet_bench" \
    BENCH_FIXTURES="$FIX" BENCH_ROWS=$ROWS BENCH_PAYLOAD_BYTES=$PAYLOAD BENCH_USERS=$USERS BENCH_DEVICES=$DEVICES \
    BENCH_SESSION_MODEL=shared BENCH_RUN_ID="fair-$TAG" SECRET_KEY_BASE=x ALLOWED_ORIGINS=//127.0.0.1
  cd examples/inbox && mix fyrlet.migrate --create --quiet && mix run ../../bench/fixtures/seed.exs ) > "$OUT/prep.log" 2>&1

# shellcheck disable=SC2086  # EXTRA is intentionally word-split
$DOCKER run -d --name fair-fyrlet --network "$NET" --cpus "${CPUS:-1}" --cpuset-cpus "$APP_CPUSET" \
  --memory "${MEM:-1g}" --memory-swap "${MEM:-1g}" --ulimit nofile=65536:65536 \
  -e DATABASE_URL="ecto://postgres:postgres@$PG:5432/fyrlet_bench" \
  -e SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')" \
  -e ALLOWED_ORIGINS=//127.0.0.1,//localhost,//fair-fyrlet -e CORS_ORIGINS=http://127.0.0.1 -e PORT=4200 \
  -e "ERL_AFLAGS=${ERLF:-}" ${EXTRA:-} "$IMG" >/dev/null
ready=0
for _ in $(seq 40); do
  if $DOCKER run --rm --network "$NET" curlimages/curl -fsS -m 2 http://fair-fyrlet:4200/ready >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[[ "$ready" = 1 ]] || { $DOCKER logs fair-fyrlet > "$OUT/server.log" 2>&1; echo 'Application did not become database-ready' >&2; exit 1; }
$DOCKER inspect fair-fyrlet "$PG" --format '{"name":{{json .Name}},"image":{{json .Image}},"source":{{json (index .Config.Labels "fyrlet.source")}},"nanoCpus":{{.HostConfig.NanoCpus}},"cpuset":{{json .HostConfig.CpusetCpus}},"memory":{{.HostConfig.Memory}},"memorySwap":{{.HostConfig.MemorySwap}}}' > "$OUT/limits.jsonl"

cg() { for c in fair-fyrlet "$PG"; do
  echo "$c $1 $($DOCKER exec "$c" sh -c 'grep -E "usage_usec|nr_throttled" /sys/fs/cgroup/cpu.stat | tr "\n" " "; grep -E "^oom_kill " /sys/fs/cgroup/memory.events; cat /sys/fs/cgroup/memory.current' | tr '\n' ' ')"
done; }
cg before > "$OUT/cgroup.txt"
( while true; do $DOCKER exec fair-fyrlet sh -c 'grep -E "^anon " /sys/fs/cgroup/memory.stat' >> "$OUT/anon.txt" 2>/dev/null; sleep 2; done ) &
SAMPLER=$!

# GENERATORS=N shards the users and the offered rate across N runner processes (one container each, all in
# GEN_CPUSET). A single Node process drops ticks first at high rates, which hides the server's limit.
generator() {
  local container=$1
  shift
  $DOCKER run --rm --name "$container" --network "$NET" --cpuset-cpus "$GEN_CPUSET" \
    --ulimit nofile=65536:65536 -v "$ROOT:/work" -w /work node:24.22.1-bookworm-slim "$@"
}
common=(--target fyrlet --endpoint http://fair-fyrlet:4200 --fixtures "${FIX#"$ROOT"/}" --scenario "$SCENARIO"
  --users "$USERS" --devices "$DEVICES" --sessions shared --rows "$ROWS" --payload-bytes "$PAYLOAD"
  --rate "$RATE" --duration-ms "$DUR" --warmup 1 --repeats 1 --timeout-ms 60000)
runner_status=0
if [ "$N" -le 1 ]; then
  generator "${generator_containers[0]}" node bench/runner.mjs "${common[@]}" --concurrency "${CONCURRENCY:-64}" --out "$REL_OUT/r" > "$OUT/log.txt" 2>&1 || runner_status=$?
else
  # Every shard waits for the same start time (read from the daemon's clock) so measurement windows coincide.
  START=$($DOCKER run --rm node:24.22.1-bookworm-slim node -e "console.log(Date.now() + ${SETUP_BUDGET_S:-90} * 1000)")
  for i in $(seq 0 $((N - 1))); do
    generator "${generator_containers[$i]}" node bench/runner.mjs "${common[@]}" --concurrency $(( (${CONCURRENCY:-64} + N - 1) / N )) --shard "$i/$N" --start-at "$START" \
      --out "$REL_OUT/shard-$i" > "$OUT/log-$i.txt" 2>&1 &
    generator_pids+=($!)
  done
  for pid in "${generator_pids[@]}"; do wait "$pid" || runner_status=$?; done
  generator_pids=()
  shards=(); for i in $(seq 0 $((N - 1))); do shards+=("$REL_OUT/shard-$i"); done
  generator "fair-gen-$TAG-merge" node bench/merge.mjs "$REL_OUT/r" "${shards[@]}" > "$OUT/log.txt" 2>&1 || runner_status=$?
fi
kill $SAMPLER 2>/dev/null || true
SAMPLER=
cg after >> "$OUT/cgroup.txt"
$DOCKER logs fair-fyrlet > "$OUT/server.log" 2>&1
rm -f "$FIX"

node bench/fair/result.mjs "$OUT" "$runner_status"
