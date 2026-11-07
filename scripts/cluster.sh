#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
export CLUSTER_BASE_PORT="${CLUSTER_BASE_PORT:-4200}"
export PHX_SERVER=true
export FYRLET_DOMAIN_INTEGRATION=1
for task_offset in 0 1 2 3 4; do
  if lsof -nP -iTCP:$((CLUSTER_BASE_PORT + task_offset)) -sTCP:LISTEN >/dev/null 2>&1; then
    printf 'Cluster test port %s is occupied.\n' "$((CLUSTER_BASE_PORT + task_offset))" >&2
    exit 1
  fi
done
npm --prefix "$task_root/sdks/typescript" run build
for task_domain in ${*:-chat agent}; do
  export FYRLET_DOMAIN="$task_domain"
  export DATABASE_URL="${CLUSTER_DATABASE_URL:-ecto://postgres:postgres@127.0.0.1:55432/${task_domain}_cluster}"
  export INTEGRATION_APP="$task_root/examples/$task_domain"
  export INTEGRATION_FIXTURES="$task_root/.local/integration/$task_domain-cluster-credentials.json"
  cd "$INTEGRATION_APP"
  mix fyrlet.migrate --create --quiet
  mix run "$task_root/scripts/integration_fixtures.exs"
  cd "$task_root/sdks/typescript"
  node --test test/cluster.test.mjs
done
