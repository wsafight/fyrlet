#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
export DATABASE_URL="${INTEGRATION_DATABASE_URL:-ecto://postgres:postgres@127.0.0.1:55432/realtime_integration}"
export PORT="${INTEGRATION_PORT:-4100}"
export INTEGRATION_ENDPOINT="http://127.0.0.1:$PORT"
export INTEGRATION_FIXTURES="$task_root/.local/integration/credentials.json"

if curl --silent --fail "$INTEGRATION_ENDPOINT/health" >/dev/null 2>&1; then
  printf 'Integration port %s is occupied; set INTEGRATION_PORT.\n' "$PORT" >&2
  exit 1
fi

mix ecto.create --quiet
mix ecto.migrate --quiet
mix run scripts/integration_fixtures.exs
npm --prefix sdks/typescript run test:integration
