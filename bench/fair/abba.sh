#!/usr/bin/env bash
# A/B/B/A alternation of two images (or two settings of one image).
# usage: abba.sh <rate> <rounds> <label>
#   IMG_A / IMG_B       images (default fair-fyrlet:base / fair-fyrlet:current)
#   EXTRA_A / EXTRA_B   extra `docker run` flags, e.g. "-e FYRLET_CHANNEL_HIBERNATE_MS=0"
#   ERLF_A / ERLF_B     ERL_AFLAGS for each side
#   CPUS                application CPU quota (default 1)
set -euo pipefail
. "$(dirname "$0")/env.sh"
RATE=$1; ROUNDS=$2; LABEL=$3
[[ "$LABEL" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,50}$ ]] || { echo 'Invalid A/B label' >&2; exit 1; }
IA=${IMG_A:-fair-fyrlet:base}; IB=${IMG_B:-fair-fyrlet:current}
LOG="$OUT_ROOT/$LABEL.log"; mkdir -p "$OUT_ROOT"
if ! (set -C; : > "$LOG") 2>/dev/null; then echo "A/B log already exists: $LOG" >&2; exit 1; fi
cd "$ROOT"
source_digest() {
  node --input-type=module -e 'import {sourceFingerprint} from "./bench/lib/manifest.mjs"; console.log((await sourceFingerprint(process.cwd())).digest)'
}
FROZEN_SOURCE=$(source_digest)
for r in $(seq "$ROUNDS"); do
  attempt=0
  for v in A B B A; do
    [[ "$(source_digest)" = "$FROZEN_SOURCE" ]] || { echo 'A/B sources changed during the suite' >&2; exit 1; }
    attempt=$((attempt + 1))
    if [ $v = A ]; then I=$IA; X=${EXTRA_A:-}; E=${ERLF_A:-}; else I=$IB; X=${EXTRA_B:-}; E=${ERLF_B:-}; fi
    FAIR_ALLOW_SOURCE_MISMATCH=1 ERLF="$E" EXTRA="$X" "$ROOT/bench/fair/run.sh" "$I" "$RATE" "$LABEL-r$r-$attempt-$v" | grep RESULT | tee -a "$LOG"
    [[ "$(source_digest)" = "$FROZEN_SOURCE" ]] || { echo 'A/B sources changed during the suite' >&2; exit 1; }
  done
done
python3 -I "$ROOT/bench/fair/summarize.py" "$LOG"
