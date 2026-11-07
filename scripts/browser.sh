#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
export PORT="${BROWSER_PORT:-4210}"
export DOMAIN_PROVIDER_PORT="${BROWSER_PROVIDER_PORT:-4211}"
export INTEGRATION_ENDPOINT="http://127.0.0.1:$PORT"
export PHX_SERVER=true
export FYRLET_DOMAIN_INTEGRATION=1
for task_port in "$PORT" "$DOMAIN_PROVIDER_PORT"; do
  if lsof -nP -iTCP:"$task_port" -sTCP:LISTEN >/dev/null 2>&1; then
    printf 'Browser test port %s is occupied.\n' "$task_port" >&2
    exit 1
  fi
done
npm --prefix "$task_root/sdks/typescript" run build
for task_domain in ${*:-notify flow agent chat}; do
  export FYRLET_DOMAIN="$task_domain"
  export DATABASE_URL="ecto://postgres:postgres@127.0.0.1:55432/${task_domain}_browser"
  export INTEGRATION_APP="$task_root/examples/$task_domain"
  export INTEGRATION_FIXTURES="$task_root/.local/integration/$task_domain-browser-credentials.json"
  cd "$INTEGRATION_APP"
  mix fyrlet.migrate --create --quiet
  mix run "$task_root/scripts/integration_fixtures.exs"
  cd "$task_root/sdks/typescript"
  node --test test/browser.test.mjs
done
