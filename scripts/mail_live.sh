#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_missing=()
for task_name in RESEND_API_KEY MAIL_FROM MAIL_TO; do
  if [[ -z "${!task_name:-}" ]]; then task_missing+=("$task_name"); fi
done
if (( ${#task_missing[@]} )); then
  printf 'Missing required settings: %s\n' "${task_missing[*]}" >&2
  exit 2
fi
if [[ "${1:-}" == --check ]]; then
  printf 'Required settings are present. No email was sent.\n'
  exit 0
fi
if (( $# )); then
  printf 'Usage: bash scripts/mail_live.sh [--check]\n' >&2
  exit 2
fi
export PORT="${MAIL_SMOKE_PORT:-4212}"
export INTEGRATION_ENDPOINT="http://127.0.0.1:$PORT"
export INTEGRATION_APP="$task_root/examples/notify"
export INTEGRATION_FIXTURES="$task_root/.local/integration/notify-live-credentials.json"
export DATABASE_URL="${MAIL_SMOKE_DATABASE_URL:-ecto://postgres:postgres@127.0.0.1:55432/notify_live}"
export PHX_SERVER=true
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  printf 'Live email test port %s is occupied.\n' "$PORT" >&2
  exit 1
fi
npm --prefix "$task_root/sdks/typescript" run build
cd "$INTEGRATION_APP"
mix fyrlet.migrate --create --quiet
mix run "$task_root/scripts/integration_fixtures.exs"
cd "$task_root/sdks/typescript"
node --test test/mail-live.test.mjs
