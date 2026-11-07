#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
export PORT="${SHARED_BENCH_PORT:-4185}"
export DOMAIN_PROVIDER_PORT="${SHARED_BENCH_METRICS_PORT:-4186}"
export INTEGRATION_ENDPOINT="http://127.0.0.1:$PORT"
export DATABASE_URL="${SHARED_BENCH_DATABASE_URL:-ecto://postgres:postgres@127.0.0.1:55432/chat_benchmark}"
export PHX_SERVER=true
export FYRLET_DOMAIN_INTEGRATION=1
export FYRLET_DOMAIN=chat
export INTEGRATION_APP="$task_root/examples/chat"
export INTEGRATION_FIXTURES="$task_root/.local/integration/shared-bench-credentials.json"
if curl --silent --fail "$INTEGRATION_ENDPOINT/health" >/dev/null 2>&1; then
  printf 'Shared benchmark port %s is occupied.\n' "$PORT" >&2
  exit 1
fi
npm --prefix "$task_root/sdks/typescript" run build
cd "$INTEGRATION_APP"
mix fyrlet.migrate --create --quiet
mix run "$task_root/scripts/integration_fixtures.exs"
cd "$task_root"
node bench/shared.mjs
