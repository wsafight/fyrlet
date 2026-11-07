#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
export PORT="${DOMAIN_PORT:-4180}"
export DOMAIN_PROVIDER_PORT="${DOMAIN_PROVIDER_PORT:-4181}"
export INTEGRATION_ENDPOINT="http://127.0.0.1:$PORT"
export PHX_SERVER=true
export FYRLET_DOMAIN_INTEGRATION=1
if curl --silent --fail "$INTEGRATION_ENDPOINT/health" >/dev/null 2>&1; then
  printf 'Domain integration port %s is occupied.\n' "$PORT" >&2
  exit 1
fi
npm --prefix "$task_root/sdks/typescript" run build
for task_domain in ${*:-notify flow agent chat}; do
  export FYRLET_DOMAIN="$task_domain"
  export DATABASE_URL="ecto://postgres:postgres@127.0.0.1:55432/${task_domain}_integration"
  export INTEGRATION_APP="$task_root/examples/$task_domain"
  export INTEGRATION_FIXTURES="$task_root/.local/integration/$task_domain-credentials.json"
  cd "$INTEGRATION_APP"
  mix fyrlet.migrate --create --quiet
  mix run "$task_root/scripts/integration_fixtures.exs"
  cd "$task_root/sdks/typescript"
  node --test test/domains.test.mjs
done
