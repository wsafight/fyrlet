#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_output="$task_root/.local/releases"
mkdir -p "$task_root/.local"
task_temp="$(mktemp -d "$task_root/.local/package.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
task_artifacts="$task_temp/artifacts"
mkdir -m 700 "$task_artifacts"

FYRLET_PACKAGE_CONTEXT="$(cd "$task_root" && node --input-type=module <<'NODE'
import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { acceptanceFingerprint } from "./scripts/acceptance.mjs";
import { conventionalArtifacts, releaseMetadata, resolveArtifactInventory, validateReleasePolicy } from "./scripts/release_check.mjs";
const metadata = await releaseMetadata(process.cwd());
const policy = JSON.parse(await readFile("deploy/release-policy.json", "utf8"));
const license = await readFile("LICENSE", "utf8");
if (!validateReleasePolicy(policy, metadata, license)) throw new Error("Release metadata and policy are inconsistent");
const revision = execFileSync("git", ["rev-parse", "--verify", "HEAD^{commit}"], { encoding: "utf8" }).trim();
const clean = execFileSync("git", ["status", "--porcelain=v1", "--untracked-files=all"], { encoding: "utf8" }).trim() === "";
console.log(JSON.stringify({
  version: metadata.version,
  revision,
  clean,
  source: await acceptanceFingerprint(process.cwd()),
  artifacts: conventionalArtifacts(metadata),
  expectedArtifacts: resolveArtifactInventory(metadata, policy),
}));
NODE
)"
export FYRLET_PACKAGE_CONTEXT
task_source="$(node -p 'JSON.parse(process.env.FYRLET_PACKAGE_CONTEXT).artifacts.source')"
task_hex="$(node -p 'JSON.parse(process.env.FYRLET_PACKAGE_CONTEXT).artifacts.hex')"
task_client="$(node -p 'JSON.parse(process.env.FYRLET_PACKAGE_CONTEXT).artifacts.npm["@fyrlet/client"]')"
task_react="$(node -p 'JSON.parse(process.env.FYRLET_PACKAGE_CONTEXT).artifacts.npm["@fyrlet/react"]')"

node --test "$task_root/scripts/test/release_packaging.test.mjs"
rm -rf -- "$task_root/sdks/typescript/dist" "$task_root/sdks/react/dist"
mkdir -p -- "$task_root/sdks/typescript/dist" "$task_root/sdks/react/dist"
npm --prefix "$task_root/sdks/typescript" run typecheck
npm --prefix "$task_root/sdks/typescript" test
npm --prefix "$task_root/sdks/react" run typecheck
npm --prefix "$task_root/sdks/react" test

# Pack from staging so every npm artifact contains the repository's Apache-2.0
# license without adding generated files to the source worktree.
node --input-type=module - "$task_root" "$task_temp" <<'NODE'
import { copyFile, cp, mkdir } from "node:fs/promises";
import { join } from "node:path";
const [root, temporary] = process.argv.slice(2);
for (const [source, destination] of [["sdks/typescript", "client"], ["sdks/react", "react"]]) {
  const stage = join(temporary, destination);
  await mkdir(stage, { recursive: true });
  await copyFile(join(root, source, "package.json"), join(stage, "package.json"));
  await copyFile(join(root, "LICENSE"), join(stage, "LICENSE"));
  for (const file of ["README.md", "README.zh-CN.md"]) await copyFile(join(root, source, file), join(stage, file));
  await cp(join(root, source, "dist"), join(stage, "dist"), { recursive: true });
}
NODE
npm pack "$task_temp/client" --pack-destination "$task_artifacts" --json --ignore-scripts > "$task_temp/client-pack.json"
npm pack "$task_temp/react" --pack-destination "$task_artifacts" --json --ignore-scripts > "$task_temp/react-pack.json"
node --input-type=module - "$task_root" "$task_temp/source-files" <<'NODE'
import { writeFile } from "node:fs/promises";
import { sourceArchiveFiles } from "./scripts/release_check.mjs";
const [root, output] = process.argv.slice(2);
const sourcePaths = ["LICENSE", "mix.exs", "mix.lock", ".formatter.exs", ".gitignore", ".env.example", "compose.yaml",
  "lib", "config", "priv", "test", "docs", "examples", "packages", "scripts", "sdks", "bench", "deploy", "README.md", "README.zh-CN.md"];
const files = await sourceArchiveFiles(root, sourcePaths);
if (files.length === 0 || !sourcePaths.slice(0, 3).every((path) => files.includes(path))) throw new Error("Source archive inventory is incomplete");
await writeFile(output, files.map((path) => `${path}\0`).join(""), { mode: 0o600 });
NODE
(
  cd "$task_root"
  mix hex.build --output "$task_artifacts/$task_hex"
  tar --null -T "$task_temp/source-files" -czf "$task_artifacts/$task_source"
)

node --input-type=module - "$task_artifacts" "$task_temp" <<'NODE'
import { readFile, writeFile, readdir } from "node:fs/promises";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { acceptanceFingerprint } from "./scripts/acceptance.mjs";
const [output, temporary] = process.argv.slice(2);
const context = JSON.parse(process.env.FYRLET_PACKAGE_CONTEXT);
if ((await acceptanceFingerprint(process.cwd())).digest !== context.source.digest) throw new Error("Package sources changed during build; rebuild with frozen sources");
const revision = execFileSync("git", ["rev-parse", "--verify", "HEAD^{commit}"], { encoding: "utf8" }).trim();
const clean = execFileSync("git", ["status", "--porcelain=v1", "--untracked-files=all"], { encoding: "utf8" }).trim() === "";
if (revision !== context.revision || clean !== context.clean) throw new Error("Git state changed during build; rebuild with frozen sources");
for (const [file, name] of [["client-pack.json", "@fyrlet/client"], ["react-pack.json", "@fyrlet/react"]]) {
  const packed = JSON.parse(await readFile(`${temporary}/${file}`, "utf8"))[0];
  if (packed.name !== name || packed.version !== context.version || packed.filename !== context.artifacts.npm[name]) throw new Error("Unexpected npm pack result");
}
const entries = await readdir(output);
if (entries.length !== context.expectedArtifacts.length || entries.some((entry) => !context.expectedArtifacts.includes(entry))) throw new Error("Unexpected build artifact inventory");
const artifacts = await Promise.all(context.expectedArtifacts.map(async (filename) => {
  const body = await readFile(`${output}/${filename}`);
  return { filename, bytes: body.length, sha256: createHash("sha256").update(body).digest("hex") };
}));
await writeFile(`${output}/manifest.json`, JSON.stringify({
  version: context.version,
  built_at: new Date().toISOString(),
  registry_published: false,
  publication: "not-performed",
  source_fingerprint: context.source,
  git_revision: context.revision,
  working_tree_clean: context.clean,
  expected_artifacts: context.expectedArtifacts,
  artifacts,
}, null, 2) + "\n", { mode: 0o600 });
console.log(`Built ${artifacts.length} installable artifacts; no publication performed`);
NODE

task_backup="$task_temp/previous-releases"
if [[ -e "$task_output" || -L "$task_output" ]]; then mv "$task_output" "$task_backup"; fi
if ! mv "$task_artifacts" "$task_output"; then
  if [[ -e "$task_backup" || -L "$task_backup" ]]; then mv "$task_backup" "$task_output"; fi
  exit 1
fi
printf 'Release artifacts: %s\n' "$task_output"
