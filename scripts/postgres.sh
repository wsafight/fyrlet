#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_data="$task_root/.local/postgres"
task_port="${PGPORT:-55432}"
task_action="${1:-start}"

case "$task_action" in
  start)
    if [ ! -f "$task_data/PG_VERSION" ]; then
      mkdir -p "$task_data"
      initdb -D "$task_data" -U postgres --auth-local=trust --auth-host=trust >/dev/null
    fi
    if pg_ctl -D "$task_data" status >/dev/null 2>&1; then
      printf 'Project PostgreSQL is already running on port %s.\n' "$task_port"
    elif pg_isready -h 127.0.0.1 -p "$task_port" >/dev/null 2>&1; then
      printf 'Port %s is occupied; choose PGPORT and DATABASE_URL explicitly.\n' "$task_port" >&2
      exit 1
    else
      pg_ctl -D "$task_data" -l "$task_data/server.log" -o "-p $task_port -h 127.0.0.1" -w start
    fi
    ;;
  stop)
    pg_ctl -D "$task_data" -m fast -w stop
    ;;
  status)
    pg_ctl -D "$task_data" status
    ;;
  *)
    printf 'Usage: bash scripts/postgres.sh [start|stop|status]\n' >&2
    exit 1
    ;;
esac
