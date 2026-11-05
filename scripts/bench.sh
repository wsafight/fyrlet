#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
if [ ! -x sdks/typescript/node_modules/.bin/tsc ]; then
  npm --prefix sdks/typescript ci
fi
npm --prefix sdks/typescript run build
node bench/local.mjs "$@"
