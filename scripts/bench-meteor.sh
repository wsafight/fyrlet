#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_release="$(sed 's/^METEOR@//' "$task_root/bench/apps/meteor/.meteor/release" | tr -d '\r\n')"
task_install="$task_root/.local/meteor-toolchain"
task_system="$(uname -s)"
task_arch="$(uname -m)"
case "$task_system/$task_arch" in
  Darwin/arm64) task_platform="os.osx.arm64" ;;
  Darwin/x86_64) task_platform="os.osx.x86_64" ;;
  Linux/x86_64) task_platform="os.linux.x86_64" ;;
  Linux/aarch64|Linux/arm64) task_platform="os.linux.aarch64" ;;
  *) printf 'Unsupported Meteor platform: %s/%s\n' "$task_system" "$task_arch" >&2; exit 1 ;;
esac

if [ -x "$task_install/.meteor/meteor" ]; then
  METEOR_WAREHOUSE_DIR="$task_install/.meteor" "$task_install/.meteor/meteor" --release "$task_release" --version
  exit 0
fi

mkdir -p "$task_root/.local" "$task_install"
task_archive="$task_root/.local/meteor-bootstrap-$task_release-$task_platform.tar.gz"
task_staging="$(mktemp -d "$task_root/.local/meteor-extract.XXXXXX")"
trap 'rm -rf "$task_staging"' EXIT
curl --fail --location --retry 2 --connect-timeout 20 --max-time 900 --continue-at - \
  "https://packages.meteor.com/bootstrap-link?arch=$task_platform&release=$task_release" \
  --output "$task_archive"
tar -xzf "$task_archive" -C "$task_staging"
test -x "$task_staging/.meteor/meteor"
mv "$task_staging/.meteor" "$task_install/.meteor"
METEOR_WAREHOUSE_DIR="$task_install/.meteor" "$task_install/.meteor/meteor" --release "$task_release" --version
printf 'Project Meteor CLI: %s/.meteor/meteor\n' "$task_install"
