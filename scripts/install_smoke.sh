#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_output="$task_root/.local/releases"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/fyrlet-install.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT

FYRLET_SMOKE_CONTEXT="$(cd "$task_root" && node --input-type=module - "$task_output" <<'NODE'
import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { acceptanceFingerprint } from "./scripts/acceptance.mjs";
import { conventionalArtifacts, releaseMetadata, resolveArtifactInventory, validateReleasePolicy, verifyArtifacts } from "./scripts/release_check.mjs";
const output = process.argv[2];
const metadata = await releaseMetadata(process.cwd());
const policy = JSON.parse(await readFile("deploy/release-policy.json", "utf8"));
if (!validateReleasePolicy(policy, metadata, await readFile("LICENSE", "utf8"))) throw new Error("Release metadata and policy are inconsistent");
const expectedArtifacts = resolveArtifactInventory(metadata, policy);
const fingerprint = await acceptanceFingerprint(process.cwd());
const revision = execFileSync("git", ["rev-parse", "--verify", "HEAD^{commit}"], { encoding: "utf8" }).trim();
if (!await verifyArtifacts(output, fingerprint, { version: metadata.version, expectedRevision: revision, expectedArtifacts, requireClean: false })) {
  throw new Error("Artifacts do not match the current source, revision and inventory; run scripts/package.sh again");
}
const artifacts = conventionalArtifacts(metadata);
console.log(JSON.stringify({ version: metadata.version, source: artifacts.source, hex: artifacts.hex,
  client: artifacts.npm["@fyrlet/client"], react: artifacts.npm["@fyrlet/react"] }));
NODE
)"
export FYRLET_SMOKE_CONTEXT
task_source="$(node -p 'JSON.parse(process.env.FYRLET_SMOKE_CONTEXT).source')"
task_hex="$(node -p 'JSON.parse(process.env.FYRLET_SMOKE_CONTEXT).hex')"
task_client="$(node -p 'JSON.parse(process.env.FYRLET_SMOKE_CONTEXT).client')"
task_react="$(node -p 'JSON.parse(process.env.FYRLET_SMOKE_CONTEXT).react')"

node --input-type=module - "$task_root" "$task_output" <<'NODE'
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { archiveEntriesSafe } from "./scripts/release_check.mjs";
const [root, output] = process.argv.slice(2);
const context = JSON.parse(process.env.FYRLET_SMOKE_CONTEXT);
const list = (artifact, gzip, input, verbose = false) => execFileSync("tar", [gzip ? (verbose ? "-tvzf" : "-tzf") : (verbose ? "-tvf" : "-tf"), artifact], { encoding: "utf8", input, maxBuffer: 16 * 1024 * 1024 }).trim().split("\n").filter(Boolean);
const safeEntries = (artifact, gzip = true, input) => {
  const entries = list(artifact, gzip, input);
  const verbose = list(artifact, gzip, input, true);
  assert.ok(archiveEntriesSafe(entries, verbose), `Archive contains an unsafe path, link or special entry: ${artifact}`);
  return entries;
};
const sourceEntries = safeEntries(`${output}/${context.source}`);
for (const required of ["LICENSE", "mix.exs", "priv/contract.json", "deploy/release-policy.json"]) assert.ok(sourceEntries.includes(required), `Missing source file: ${required}`);
for (const entry of sourceEntries) assert.ok(!entry.includes("/.meteor/local/"), `Unexpected Meteor data: ${entry}`);
const license = await readFile(`${root}/LICENSE`, "utf8");
for (const artifact of [context.client, context.react]) {
  const path = `${output}/${artifact}`;
  const entries = safeEntries(path);
  for (const required of ["package/LICENSE", "package/package.json", "package/dist/index.js"]) assert.ok(entries.includes(required), `Missing npm file ${required} in ${artifact}`);
  const manifest = JSON.parse(execFileSync("tar", ["-xOzf", path, "package/package.json"], { encoding: "utf8" }));
  assert.equal(manifest.version, context.version);
  assert.equal(manifest.license, "Apache-2.0");
  assert.notEqual(manifest.private, true);
  assert.equal(execFileSync("tar", ["-xOzf", path, "package/LICENSE"], { encoding: "utf8" }), license);
}
const hexPath = `${output}/${context.hex}`;
const hexEntries = safeEntries(hexPath, false);
assert.deepEqual([...hexEntries].sort(), ["CHECKSUM", "VERSION", "contents.tar.gz", "metadata.config"]);
const contents = execFileSync("tar", ["-xOf", hexPath, "contents.tar.gz"], { maxBuffer: 16 * 1024 * 1024 });
const hexContents = safeEntries("-", true, contents);
for (const required of ["LICENSE", "mix.exs", "lib/fyrlet/application.ex", "priv/contract.json"]) assert.ok(hexContents.includes(required), `Missing Hex file: ${required}`);
assert.equal(execFileSync("tar", ["-xOzf", "-", "LICENSE"], { encoding: "utf8", input: contents }), license);
console.log("Artifact checksums and source, npm and Hex contents passed");
NODE

tar -xzf "$task_output/$task_source" -C "$task_temp"
ln -s "$task_root/deps" "$task_temp/deps"
# Agent's compile-time web wrapper reads Phoenix's browser asset. Copy just that
# third-party package rather than linking the SDK's entire node_modules tree.
mkdir -p "$task_temp/sdks/typescript/node_modules"
cp -R "$task_root/sdks/typescript/node_modules/phoenix" "$task_temp/sdks/typescript/node_modules/phoenix"
(
  cd "$task_temp/examples/inbox"
  mix test
)
(
  cd "$task_temp/examples/agent"
  mix test
)

# Exercise the actual Hex contents as a dependency without contacting a registry.
mkdir -p "$task_temp/hex-package/contents" "$task_temp/hex-consumer"
tar -xf "$task_output/$task_hex" -C "$task_temp/hex-package"
tar -xzf "$task_temp/hex-package/contents.tar.gz" -C "$task_temp/hex-package/contents"
ln -s "$task_root/deps" "$task_temp/hex-consumer/deps"
ln -s "$task_root/mix.lock" "$task_temp/hex-consumer/mix.lock"
cat > "$task_temp/hex-consumer/mix.exs" <<'ELIXIR'
defmodule FyrletHexSmoke.MixProject do
  use Mix.Project

  def project do
    [
      app: :fyrlet_hex_smoke,
      version: "0.0.0",
      elixir: "~> 1.18",
      deps: [{:fyrlet, path: "../hex-package/contents"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
ELIXIR
(
  cd "$task_temp/hex-consumer"
  mix compile --warnings-as-errors
  mix run --no-start -e 'unless Code.ensure_loaded?(Fyrlet.Application), do: raise("Fyrlet was not loaded from the Hex package"); IO.puts("Unpacked Hex dependency compile passed")'
)

# Pack already-installed third-party runtime dependencies locally. An empty cache,
# offline mode and disabled user/global npm config make this independent of registry
# credentials and network availability.
touch "$task_temp/npm-userconfig" "$task_temp/npm-globalconfig"
export NPM_CONFIG_USERCONFIG="$task_temp/npm-userconfig"
export NPM_CONFIG_GLOBALCONFIG="$task_temp/npm-globalconfig"
export NPM_CONFIG_CACHE="$task_temp/npm-cache"
mkdir -p "$task_temp/npm-cache" "$task_temp/npm-dependencies" "$task_temp/consumer"
npm pack "$task_root/sdks/typescript/node_modules/phoenix" --pack-destination "$task_temp/npm-dependencies" --json --ignore-scripts > "$task_temp/phoenix-pack.json"
npm pack "$task_root/sdks/react/node_modules/react" --pack-destination "$task_temp/npm-dependencies" --json --ignore-scripts > "$task_temp/react-dependency-pack.json"
npm pack "$task_root/sdks/typescript/node_modules/@types/phoenix" --pack-destination "$task_temp/npm-dependencies" --json --ignore-scripts > "$task_temp/types-phoenix-pack.json"
npm pack "$task_root/sdks/react/node_modules/@types/react" --pack-destination "$task_temp/npm-dependencies" --json --ignore-scripts > "$task_temp/types-react-pack.json"
npm pack "$task_root/sdks/react/node_modules/csstype" --pack-destination "$task_temp/npm-dependencies" --json --ignore-scripts > "$task_temp/csstype-pack.json"
task_phoenix_dependency="$(node -e 'const fs=require("node:fs"); const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8"))[0]; process.stdout.write(`${process.argv[2]}/${p.filename}`)' "$task_temp/phoenix-pack.json" "$task_temp/npm-dependencies")"
task_react_dependency="$(node -e 'const fs=require("node:fs"); const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8"))[0]; process.stdout.write(`${process.argv[2]}/${p.filename}`)' "$task_temp/react-dependency-pack.json" "$task_temp/npm-dependencies")"
task_types_phoenix_dependency="$(node -e 'const fs=require("node:fs"); const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8"))[0]; process.stdout.write(`${process.argv[2]}/${p.filename}`)' "$task_temp/types-phoenix-pack.json" "$task_temp/npm-dependencies")"
task_types_react_dependency="$(node -e 'const fs=require("node:fs"); const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8"))[0]; process.stdout.write(`${process.argv[2]}/${p.filename}`)' "$task_temp/types-react-pack.json" "$task_temp/npm-dependencies")"
task_csstype_dependency="$(node -e 'const fs=require("node:fs"); const p=JSON.parse(fs.readFileSync(process.argv[1], "utf8"))[0]; process.stdout.write(`${process.argv[2]}/${p.filename}`)' "$task_temp/csstype-pack.json" "$task_temp/npm-dependencies")"
(
  cd "$task_temp/consumer"
  npm init -y >/dev/null
  node -e 'const fs=require("node:fs"); const manifest=JSON.parse(fs.readFileSync("package.json", "utf8")); manifest.type="module"; fs.writeFileSync("package.json", JSON.stringify(manifest, null, 2));'
  npm install --offline "$task_output/$task_client" "$task_output/$task_react" "$task_phoenix_dependency" "$task_react_dependency" "$task_types_phoenix_dependency" "$task_types_react_dependency" "$task_csstype_dependency" --ignore-scripts --no-audit --no-fund --package-lock=false >/dev/null
  node --input-type=module - "$task_root" <<'NODE'
import assert from "node:assert/strict";
import { lstat, realpath } from "node:fs/promises";
import { sep } from "node:path";
import { createClient } from "@fyrlet/client";
import { createSessionService } from "@fyrlet/client/server";
import { FyrletProvider, useQuery } from "@fyrlet/react";
assert.equal(typeof createClient, "function");
assert.equal(typeof createSessionService, "function");
assert.equal(typeof FyrletProvider, "function");
assert.equal(typeof useQuery, "function");
for (const path of ["node_modules/@fyrlet/client", "node_modules/@fyrlet/react", "node_modules/phoenix", "node_modules/react"]) {
  assert.equal((await lstat(path)).isSymbolicLink(), false, `${path} must be installed, not linked`);
  assert.ok(!(await realpath(path)).startsWith(`${process.argv[2]}${sep}`), `${path} must not resolve into the source repository`);
}
console.log("Offline packed SDK and React adapter imports passed");
NODE
  cat > consumer.ts <<'TYPESCRIPT'
import { createClient } from "@fyrlet/client";
import type { Client } from "@fyrlet/client";
import { createSessionService } from "@fyrlet/client/server";
import type { AppContract } from "@fyrlet/client/example-contract";
import { FyrletProvider, useQuery } from "@fyrlet/react";

declare const client: Client<AppContract>;
const makeClient = createClient<AppContract>;
const makeSessions = createSessionService;
const provider = FyrletProvider<AppContract>;
const recent = useQuery(client, "inbox.recent", { limit: 1 });
void [makeClient, makeSessions, provider, recent];
TYPESCRIPT
  cat > tsconfig.json <<'JSON'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "types": ["phoenix", "react"],
    "strict": true,
    "exactOptionalPropertyTypes": true,
    "noUncheckedIndexedAccess": true,
    "skipLibCheck": false,
    "noEmit": true
  },
  "include": ["./consumer.ts"]
}
JSON
  node "$task_root/sdks/react/node_modules/typescript/bin/tsc" --project tsconfig.json --pretty false
  printf 'Strict external TypeScript consumer compile passed (skipLibCheck=false)\n'
)
