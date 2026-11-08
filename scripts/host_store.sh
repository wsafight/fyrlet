#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
export HOST_STORE_TEST_DATABASE_URL="${HOST_STORE_TEST_DATABASE_URL:-postgres://postgres:postgres@127.0.0.1:55432/fyrlet_host_test}"
task_database="$(node -e 'const url=new URL(process.env.HOST_STORE_TEST_DATABASE_URL); const name=url.pathname.slice(1); if(!["postgres:","postgresql:"].includes(url.protocol)||!["localhost","127.0.0.1","[::1]"].includes(url.hostname)||url.search||url.hash||!/^[a-z][a-z0-9_]*_host_test$/.test(name)) throw new Error("Use an isolated local *_host_test database"); console.log(name)')"
task_admin="$(node -e 'const url=new URL(process.env.HOST_STORE_TEST_DATABASE_URL);url.pathname="/postgres";console.log(url.toString())')"
if ! psql "$task_admin" -Atqc "SELECT 1 FROM pg_database WHERE datname='$task_database'" | grep -q 1; then
  createdb --maintenance-db="$task_admin" "$task_database"
fi
cd "$task_root/examples/inbox-react"
node --experimental-test-coverage --test --test-coverage-include="server/*.mjs" test/*.test.mjs test/store.integration.mjs
