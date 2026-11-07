# Shared settings for the limited-resource comparison scripts. Source, do not execute.
# Override any of these from the environment.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Command that talks to the Linux Docker daemon that enforces cgroup limits.
# On macOS with Colima: DOCKER="colima ssh --profile fairbench -- sudo docker"
DOCKER="${DOCKER:-docker}"
NET="${FAIR_NET:-fairnet}"
PG="${FAIR_PG:-fair-pg}"
PG_HOST_PORT="${FAIR_PG_PORT:-55433}"
OUT_ROOT="${FAIR_OUT:-$ROOT/.local/fair}"
# CPU sets: app 0, database 1-2, generator 4-9 (see docs/PERFORMANCE.md).
APP_CPUSET="${APP_CPUSET:-0}"
GEN_CPUSET="${GEN_CPUSET:-4-9}"
