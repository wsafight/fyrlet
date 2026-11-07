#!/usr/bin/env bash
# Runs every Elixir test suite: the core, the example applications and the packages.
# Needs the PostgreSQL from scripts/postgres.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== fyrlet (core)"
mix test

for dir in examples/*/ packages/fyrlet_*/; do
  [[ -f "$dir/mix.exs" ]] || continue
  echo "== $dir"
  (cd "$dir" && mix test)
done
