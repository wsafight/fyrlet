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
IA=${IMG_A:-fair-fyrlet:base}; IB=${IMG_B:-fair-fyrlet:current}
LOG="$OUT_ROOT/$LABEL.log"; mkdir -p "$OUT_ROOT"; : > "$LOG"
for r in $(seq "$ROUNDS"); do
  for v in A B B A; do
    if [ $v = A ]; then I=$IA; X=${EXTRA_A:-}; E=${ERLF_A:-}; else I=$IB; X=${EXTRA_B:-}; E=${ERLF_B:-}; fi
    ERLF="$E" EXTRA="$X" "$(dirname "$0")/run.sh" "$I" "$RATE" "$LABEL-r$r-$v" | grep RESULT | tee -a "$LOG"
  done
done
python3 -I "$(dirname "$0")/summarize.py" "$LOG"
