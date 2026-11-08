#!/usr/bin/env bash
# Build the Fyrlet release image from a source tree: build.sh [tag] [context-dir]
# The context defaults to this checkout; pass a `git worktree` path to build another revision.
set -euo pipefail
. "$(dirname "$0")/env.sh"
TAG="${1:-fair-fyrlet:current}"
CTX="${2:-$ROOT}"
cp "$ROOT/bench/fair/Dockerfile" "$CTX/Dockerfile.fair"
cp "$ROOT/bench/fair/Dockerfile.dockerignore" "$CTX/Dockerfile.fair.dockerignore"
trap 'rm -f "$CTX/Dockerfile.fair" "$CTX/Dockerfile.fair.dockerignore"' EXIT
SOURCE=$(node --input-type=module - "$ROOT" "$CTX" <<'NODE'
import { pathToFileURL } from 'node:url';
const {sourceFingerprint} = await import(pathToFileURL(`${process.argv[2]}/bench/lib/manifest.mjs`));
console.log((await sourceFingerprint(process.argv[3])).digest);
NODE
)
$DOCKER build --progress=plain --build-arg HTTP_PROXY --build-arg HTTPS_PROXY --build-arg NO_PROXY \
  --label "fyrlet.source=$SOURCE" -f "$CTX/Dockerfile.fair" -t "$TAG" "$CTX"
