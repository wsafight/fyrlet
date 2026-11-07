#!/usr/bin/env bash
# One limited-resource run of a Fyrlet image under the soak workload.
# usage: [CPUS=1] [EXTRA="-e K=V"] [ERLF="+sbwt none"] [USERS=1000] run.sh <image> <rate> <tag> [duration_ms]
# The database is re-created and re-seeded from the working tree for every run, so only the image differs.
set -euo pipefail
. "$(dirname "$0")/env.sh"
cd "$ROOT"
IMG=$1; RATE=$2; TAG=$3; DUR=${4:-20000}
USERS=${USERS:-1000}; DEVICES=${DEVICES:-2}; ROWS=${ROWS:-50}; PAYLOAD=${PAYLOAD:-128}
OUT="$OUT_ROOT/runs/$TAG"; mkdir -p "$OUT"
REL_OUT="${OUT#"$ROOT"/}"
FIX="$OUT_ROOT/fixtures.json"

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
for _ in $(seq 40); do
  $DOCKER run --rm --network "$NET" curlimages/curl -s -m 2 http://fair-fyrlet:4200/health 2>/dev/null | grep -q ok && break
  sleep 1
done

cg() { for c in fair-fyrlet "$PG"; do
  echo "$c $1 $($DOCKER exec "$c" sh -c 'grep -E "usage_usec|nr_throttled" /sys/fs/cgroup/cpu.stat | tr "\n" " "; grep -E "^oom_kill " /sys/fs/cgroup/memory.events; cat /sys/fs/cgroup/memory.current' | tr '\n' ' ')"
done; }
cg before > "$OUT/cgroup.txt"
( while true; do $DOCKER exec fair-fyrlet sh -c 'grep -E "^anon " /sys/fs/cgroup/memory.stat' >> "$OUT/anon.txt" 2>/dev/null; sleep 2; done ) &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null || true' EXIT

# GENERATORS=N shards the users and the offered rate across N runner processes (one container each, all in
# GEN_CPUSET). A single Node process drops ticks first at high rates, which hides the server's limit.
N=${GENERATORS:-1}
GEN="$DOCKER run --rm --network $NET --cpuset-cpus $GEN_CPUSET --ulimit nofile=65536:65536 -v $ROOT:/work -w /work node:24.22.1-bookworm-slim"
common=(--target fyrlet --endpoint http://fair-fyrlet:4200 --fixtures "${FIX#"$ROOT"/}" --scenario soak
  --users "$USERS" --devices "$DEVICES" --sessions shared --rows "$ROWS" --payload-bytes "$PAYLOAD"
  --rate "$RATE" --duration-ms "$DUR" --warmup 1 --repeats 1 --timeout-ms 60000)
if [ "$N" -le 1 ]; then
  $GEN node bench/runner.mjs "${common[@]}" --concurrency 64 --out "$REL_OUT/r" > "$OUT/log.txt" 2>&1 || true
else
  # Every shard waits for the same start time (read from the daemon's clock) so measurement windows coincide.
  START=$($DOCKER run --rm node:24.22.1-bookworm-slim node -e "console.log(Date.now() + ${SETUP_BUDGET_S:-90} * 1000)")
  pids=()
  for i in $(seq 0 $((N - 1))); do
    $GEN node bench/runner.mjs "${common[@]}" --concurrency $(( (64 + N - 1) / N )) --shard "$i/$N" --start-at "$START" \
      --out "$REL_OUT/shard-$i" > "$OUT/log-$i.txt" 2>&1 &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || true; done
  shards=(); for i in $(seq 0 $((N - 1))); do shards+=("$REL_OUT/shard-$i"); done
  $GEN node bench/merge.mjs "$REL_OUT/r" "${shards[@]}" > "$OUT/log.txt" 2>&1 || true
fi
kill $SAMPLER 2>/dev/null || true
cg after >> "$OUT/cgroup.txt"

python3 -I - "$OUT" <<'P'
import json, re, sys
d = sys.argv[1]
try:
    r = json.load(open(d + "/r/results.json"))["results"][0]
    cg = open(d + "/cgroup.txt").read().splitlines()
    v = lambda l, k: int(re.search(k + r" (\d+)", l).group(1))
    cpu = (v(cg[2], "usage_usec") - v(cg[0], "usage_usec")) / 1e6
    load = r.get("pacedLoad") or {}
    anon = max([int(l.split()[1]) for l in open(d + "/anon.txt") if l.startswith("anon")] or [0]) / 2**20
    print(f"RESULT {d.split('/')[-1]:22} writes={r['completedWrites']:6} p95={r['propagationMs']['p95']:8.2f}ms "
          f"cov={r['deliveryCoverage']:.2f} appCPU={cpu:5.1f}s throttled={v(cg[2],'nr_throttled')-v(cg[0],'nr_throttled'):4} "
          f"mem={int(cg[2].split()[-1])/2**20:4.0f}MiB oom={v(cg[2],'oom_kill')} setupMs={r['setupDurationMs']:.0f} "
          f"ok={r['success']} anonPeakMiB={anon:.0f} genDropped={load.get('generatorDropped','?')}")
except Exception as e:
    print("RESULT", d, "FAILED", e, open(d + "/log.txt").read()[-200:])
P
