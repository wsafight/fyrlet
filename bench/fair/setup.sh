#!/usr/bin/env bash
# Create the network and the limited PostgreSQL container used by run.sh (idempotent).
set -euo pipefail
. "$(dirname "$0")/env.sh"
$DOCKER network inspect "$NET" >/dev/null 2>&1 || $DOCKER network create "$NET" >/dev/null
if ! $DOCKER inspect "$PG" >/dev/null 2>&1; then
  $DOCKER run -d --name "$PG" --network "$NET" --cpus 2 --cpuset-cpus 1-2 --memory 2g --memory-swap 2g \
    -e POSTGRES_PASSWORD=postgres -p "127.0.0.1:$PG_HOST_PORT:5432" postgres:17 \
    -c max_connections=300 >/dev/null
  echo "created $PG"
fi
$DOCKER pull curlimages/curl >/dev/null
$DOCKER pull node:24.22.1-bookworm-slim >/dev/null
echo "ready: network=$NET postgres=$PG (host port $PG_HOST_PORT)"
