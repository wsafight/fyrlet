#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/fyrlet-install.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
node --input-type=module - "$task_root/.local/releases" <<'NODE'
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
const output = process.argv[2];
const manifest = JSON.parse(await readFile(`${output}/manifest.json`, "utf8"));
for (const artifact of manifest.artifacts) {
  const body = await readFile(`${output}/${artifact.filename}`);
  assert.equal(body.length, artifact.bytes);
  assert.equal(createHash("sha256").update(body).digest("hex"), artifact.sha256);
}
const entries = execFileSync("tar", ["-tzf", `${output}/fyrlet-source-0.1.0.tar.gz`], { encoding: "utf8" }).trim().split("\n");
for (const entry of entries) {
  assert.ok(!entry.startsWith("/") && !entry.split("/").includes(".."));
  assert.ok(!entry.split("/").some(part => ["node_modules", "deps", "_build", ".local", ".env", ".git"].includes(part)), `Unexpected local data: ${entry}`);
  assert.ok(!entry.includes("/.meteor/local/"), `Unexpected Meteor data: ${entry}`);
}
console.log("Artifact checksums and source contents passed");
NODE
tar -xzf "$task_root/.local/releases/fyrlet-source-0.1.0.tar.gz" -C "$task_temp"
ln -s "$task_root/deps" "$task_temp/deps"
ln -s "$task_root/sdks/typescript/node_modules" "$task_temp/sdks/typescript/node_modules"
cd "$task_temp/examples/inbox"
mix test
cd "$task_temp/examples/agent"
mix test
mkdir -p "$task_temp/consumer"
cd "$task_temp/consumer"
npm init -y >/dev/null
npm install "$task_root/.local/releases/fyrlet-client-0.1.0.tgz" --ignore-scripts --no-audit --no-fund >/dev/null
node --input-type=module -e 'import {createClient} from "@fyrlet/client"; import {createSessionService} from "@fyrlet/client/server"; if(typeof createClient !== "function" || typeof createSessionService !== "function") process.exit(1); console.log("Packed SDK imports passed")'
