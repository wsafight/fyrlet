#!/usr/bin/env bash
# Starts the inbox example server and runs the SDK integration tests against it.
# Requires the Postgres instance used by scripts/integration.sh.
# Usage: scripts/integration_sdks.sh [python|go|swift|dotnet|rust|java|kotlin]
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
export DATABASE_URL="${INTEGRATION_DATABASE_URL:-ecto://postgres:postgres@127.0.0.1:55432/fyrlet_integration}"
export PORT="${INTEGRATION_PORT:-4100}"
export INTEGRATION_ENDPOINT="http://127.0.0.1:$PORT"
export INTEGRATION_FIXTURES="$task_root/.local/integration/credentials.json"
export FYRLET_INTEGRATION=1
target="${1:-all}"

if curl --silent --fail "$INTEGRATION_ENDPOINT/health" >/dev/null 2>&1; then
  printf 'Integration port %s is occupied; set INTEGRATION_PORT.\n' "$PORT" >&2
  exit 1
fi

mkdir -p .local/integration
(cd examples/inbox && mix fyrlet.migrate --create --quiet && mix run ../../scripts/integration_fixtures.exs)
(cd examples/inbox && exec mix phx.server) >.local/integration/sdks-server.log 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true' EXIT

for _ in $(seq 1 200); do
  curl --silent --fail "$INTEGRATION_ENDPOINT/health" >/dev/null 2>&1 && break
  kill -0 "$server" 2>/dev/null || { echo "server exited; see .local/integration/sdks-server.log" >&2; exit 1; }
  sleep 0.1
done

if [[ "$target" == all || "$target" == python ]]; then
  (cd sdks/python && ${PYTHON:-python3} -m pytest -q)
fi
if [[ "$target" == all || "$target" == go ]]; then
  (cd sdks/go && go test -race -count=1 -v ./...)
fi
if [[ "$target" == all || "$target" == swift ]]; then
  (cd sdks/swift && swift test)
fi
if [[ "$target" == all || "$target" == dotnet ]] && [[ -d sdks/dotnet ]]; then
  (cd sdks/dotnet && dotnet test --nologo -v q)
fi
if [[ "$target" == all || "$target" == rust ]]; then
  (cd sdks/rust && cargo test)
fi
if [[ "$target" == all || "$target" == java ]]; then
  (cd sdks/java && ${MAVEN:-mvn} -q test)
fi
if [[ "$target" == all || "$target" == kotlin ]]; then
  (cd sdks/kotlin && ${MAVEN:-mvn} -q test)
fi
