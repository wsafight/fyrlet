#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_output="$task_root/.local/releases"
mkdir -p "$task_output"
export FYRLET_PACKAGE_SOURCE="$(cd "$task_root" && node --input-type=module -e 'import {acceptanceFingerprint} from "./scripts/acceptance.mjs"; console.log(JSON.stringify(await acceptanceFingerprint(process.cwd())))')"
npm --prefix "$task_root/sdks/typescript" run typecheck
npm --prefix "$task_root/sdks/typescript" test
npm --prefix "$task_root/sdks/react" run typecheck
npm --prefix "$task_root/sdks/react" test
npm pack "$task_root/sdks/typescript" --pack-destination "$task_output" --json > "$task_output/npm-pack.json"
npm pack "$task_root/sdks/react" --pack-destination "$task_output" --json > "$task_output/react-pack.json"
cd "$task_root"
tar --exclude='node_modules' --exclude='deps' --exclude='_build' --exclude='.git' \
  --exclude='.local' --exclude='.env' --exclude='*/.meteor/local' --exclude='cover' \
  --exclude='*.log' --exclude='erl_crash.dump' --exclude='.DS_Store' \
  -czf "$task_output/fyrlet-source-0.1.0.tar.gz" \
  mix.exs mix.lock .formatter.exs .gitignore .env.example compose.yaml lib config priv test docs examples packages scripts sdks bench deploy README.md README.zh-CN.md
node --input-type=module - "$task_output" <<'NODE'
import { readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { acceptanceFingerprint } from "./scripts/acceptance.mjs";
const output = process.argv[2];
const source = JSON.parse(process.env.FYRLET_PACKAGE_SOURCE);
if ((await acceptanceFingerprint(process.cwd())).digest !== source.digest) throw new Error("Package sources changed during build; rebuild with frozen sources");
const packed = JSON.parse(await readFile(`${output}/npm-pack.json`, "utf8"))[0];
const react = JSON.parse(await readFile(`${output}/react-pack.json`, "utf8"))[0];
const files = ["fyrlet-source-0.1.0.tar.gz", packed.filename, react.filename];
const artifacts = await Promise.all(files.map(async (filename) => {
  const body = await readFile(`${output}/${filename}`);
  return { filename, bytes: body.length, sha256: createHash("sha256").update(body).digest("hex") };
}));
await writeFile(`${output}/manifest.json`, JSON.stringify({ version: "0.1.0", built_at: new Date().toISOString(), registry_published: false,
  source_fingerprint: source, git_revision: execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim(),
  working_tree_clean: execFileSync("git", ["status", "--porcelain"], { encoding: "utf8" }).trim() === "", artifacts }, null, 2) + "\n");
console.log(`Built ${artifacts.length} installable artifacts in ${output}`);
NODE
