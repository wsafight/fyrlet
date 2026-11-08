#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
export DATABASE_URL="${REACT_DATABASE_URL:-ecto://postgres:postgres@127.0.0.1:55432/fyrlet_react}"
export PORT="${REACT_API_PORT:-4201}"
export WEB_PORT="${REACT_WEB_PORT:-4202}"
export INTEGRATION_ENDPOINT="http://127.0.0.1:$PORT"
export INTEGRATION_FIXTURES="$task_root/.local/integration/react-credentials.json"
export INTEGRATION_APP="$task_root/examples/inbox"
export FYRLET_INTEGRATION=1
export CORS_ORIGINS="http://127.0.0.1:$WEB_PORT"
export ALLOWED_ORIGINS="http://127.0.0.1:$WEB_PORT"
for task_port in "$PORT" "$WEB_PORT"; do
  if curl --silent --fail "http://127.0.0.1:$task_port/" >/dev/null 2>&1; then
    printf 'Port %s is occupied; set REACT_API_PORT or REACT_WEB_PORT.\n' "$task_port" >&2
    exit 1
  fi
done
cd "$task_root"
npm --prefix sdks/typescript run build
npm --prefix sdks/react run build
npm --prefix examples/inbox-react run build
cd "$INTEGRATION_APP"
mix fyrlet.migrate --create --quiet
mix run "$task_root/scripts/integration_fixtures.exs"
cd "$task_root"
npm --prefix examples/inbox-react run test:e2e
