import { parseArgs } from "node:util";
import { readFile, writeFile, mkdir, readdir, lstat } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { acceptanceFingerprint } from "./acceptance.mjs";

const execute = promisify(execFile);
const root = fileURLToPath(new URL("../", import.meta.url));
const sdkDefinitions = [
  { directory: "sdks/typescript", name: "@fyrlet/client", artifactStem: "fyrlet-client" },
  { directory: "sdks/react", name: "@fyrlet/react", artifactStem: "fyrlet-react" },
];
const semver = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
const safeFilename = /^[a-zA-Z0-9][a-zA-Z0-9._+-]*$/;
const localArchiveParts = new Set(["node_modules", "deps", "_build", ".local", ".env", ".git", "cover"]);
const coreWorkflowPath = ".github/workflows/core.yml";
const coreMatrixJobs = ["test (1.18, 27)", "test (1.20, 29)"];

export async function releaseMetadata(directory = root) {
  const mixSource = await readFile(resolve(directory, "mix.exs"), "utf8");
  const app = mixSource.match(/\bapp:\s*:([a-z0-9_]+)/)?.[1];
  const version = mixSource.match(/\bversion:\s*"([^"]+)"/)?.[1];
  if (!app || !version || !semver.test(version)) throw new TypeError("Invalid Mix release metadata");
  const packages = await Promise.all(sdkDefinitions.map(async (definition) => {
    const manifest = JSON.parse(await readFile(resolve(directory, definition.directory, "package.json"), "utf8"));
    if (manifest.name !== definition.name || manifest.version !== version) throw new TypeError("Inconsistent SDK release metadata");
    return { ...manifest, ...definition };
  }));
  return { app, version, packages };
}

export async function sourceArchiveFiles(directory, sourcePaths) {
  if (!Array.isArray(sourcePaths) || sourcePaths.length === 0) throw new TypeError("Missing source archive paths");
  const { stdout } = await execute("git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", ...sourcePaths], {
    cwd: directory, encoding: "utf8", maxBuffer: 16 * 1024 * 1024,
  });
  const files = [];
  for (const path of stdout.split("\0").filter(Boolean)) {
    if (/[\0\r\n]/.test(path)) throw new TypeError("Control characters are not allowed in source archive paths");
    if (path.split("/").some((part) => localArchiveParts.has(part))) continue;
    let stat;
    try { stat = await lstat(resolve(directory, path)); }
    catch (error) { if (error.code === "ENOENT") continue; throw error; }
    if (!stat.isFile()) throw new TypeError(`Source archive only supports regular files: ${path}`);
    files.push(path);
  }
  return files;
}

export function conventionalArtifacts(metadata) {
  const artifacts = {
    source: `${metadata.app}-source-${metadata.version}.tar.gz`,
    hex: `${metadata.app}-${metadata.version}.tar`,
    npm: Object.fromEntries(metadata.packages.map((manifest) => [manifest.name, `${manifest.artifactStem}-${metadata.version}.tgz`])),
  };
  return { ...artifacts, inventory: [artifacts.source, artifacts.hex, ...metadata.packages.map((manifest) => artifacts.npm[manifest.name])] };
}

export function resolveArtifactInventory(metadata, policy) {
  if (!Array.isArray(policy.artifactInventory)) throw new TypeError("Missing artifact inventory");
  const expected = conventionalArtifacts(metadata).inventory;
  const inventory = policy.artifactInventory.map((template) => {
    if (typeof template !== "string" || (template.match(/\{version\}/g) ?? []).length !== 1) throw new TypeError("Invalid artifact template");
    const filename = template.replaceAll("{version}", metadata.version);
    if (!safeFilename.test(filename) || /[{}]/.test(filename)) throw new TypeError("Unsafe artifact filename");
    return filename;
  });
  if (inventory.length !== expected.length || new Set(inventory).size !== inventory.length ||
      inventory.some((filename) => !expected.includes(filename))) throw new TypeError("Artifact inventory does not match formal packages");
  return inventory;
}

export function validateReleasePolicy(policy, metadata, licenseText) {
  try {
    const repository = new URL(policy.sourceRepository);
    const expectedRepository = `git+${policy.sourceRepository}.git`;
    return policy.schemaVersion === 1 && policy.maintainerApproved === true && typeof policy.publicationApproved === "boolean" &&
      policy.license === "Apache-2.0" && policy.licenseFile === "LICENSE" &&
      repository.protocol === "https:" && !repository.username && !repository.password &&
      policy.formalPackages?.hex === metadata.app &&
      JSON.stringify([...(policy.formalPackages?.npm ?? [])].sort()) === JSON.stringify(metadata.packages.map((manifest) => manifest.name).sort()) &&
      metadata.packages.every((manifest) => manifest.license === policy.license && manifest.private !== true &&
        manifest.publishConfig?.access === "public" && manifest.repository?.url === expectedRepository &&
        manifest.repository?.directory === manifest.directory) &&
      ["dotnet", "go", "java", "kotlin", "python", "rust", "swift"].every((name) => policy.experimentalSdks?.includes(name)) &&
      !["typescript", "react"].some((name) => policy.experimentalSdks.includes(name)) &&
      ["compatibility", "deprecation", "registries"].every((name) => typeof policy[name] === "string" && policy[name].trim()) &&
      policy.publication?.performed === false && typeof policy.publication?.ownershipVerified === "boolean" &&
      policy.publication?.credentialsStoredInRepository === false && policy.publication?.mode === "manual-maintainer-action-only" &&
      licenseText.includes("Apache License") && licenseText.includes("Version 2.0, January 2004") &&
      licenseText.includes("END OF TERMS AND CONDITIONS") && resolveArtifactInventory(metadata, policy).length === 4;
  } catch {
    return false;
  }
}

export function archiveEntriesSafe(entries, verboseEntries) {
  if (!Array.isArray(entries) || !Array.isArray(verboseEntries) || entries.length !== verboseEntries.length) return false;
  return entries.every((entry, index) => {
    const verbose = verboseEntries[index];
    return typeof entry === "string" && typeof verbose === "string" && (verbose.startsWith("-") || verbose.startsWith("d")) &&
      !/[\0\r\n]/.test(entry) && !entry.startsWith("/") && !/^[a-zA-Z]:/.test(entry) && !entry.includes("\\") &&
      !entry.split("/").includes("..") && !entry.split("/").some((part) => localArchiveParts.has(part));
  });
}

export function hostedCiRunPasses({ run, jobPage, revision, expectedRunId, repository }) {
  try {
    const jobs = jobPage.jobs;
    const runId = String(expectedRunId);
    const matchingPullRequest = run.pull_requests.some((pullRequest) => pullRequest.head?.sha === revision &&
      pullRequest.head?.ref === run.head_branch && pullRequest.base?.repo?.url === `https://api.github.com/repos/${repository}`);
    return /^\d+$/.test(runId) && String(run.id) === runId && run.path === coreWorkflowPath && run.event === "pull_request" &&
      run.head_sha === revision && run.status === "completed" && run.conclusion === "success" && matchingPullRequest &&
      Array.isArray(jobs) && jobPage.total_count === jobs.length && coreMatrixJobs.every((name) => {
        const matching = jobs.filter((job) => job.name === name);
        return matching.length === 1 && matching[0].run_id === run.id && matching[0].status === "completed" && matching[0].conclusion === "success";
      });
  } catch {
    return false;
  }
}

export async function releaseSourceMatches(directory, fingerprint, revision) {
  try {
    const [currentFingerprint, currentRevision, status] = await Promise.all([
      acceptanceFingerprint(directory),
      execute("git", ["rev-parse", "--verify", "HEAD^{commit}"], { cwd: directory }),
      execute("git", ["status", "--porcelain=v1", "--untracked-files=all"], { cwd: directory }),
    ]);
    return currentFingerprint.digest === fingerprint.digest && currentRevision.stdout.trim() === revision && !status.stdout.trim();
  } catch {
    return false;
  }
}

export async function verifyArtifacts(directory, fingerprint, expectations) {
  try {
    const manifest = JSON.parse(await readFile(resolve(directory, "manifest.json"), "utf8"));
    if (manifest.source_fingerprint?.digest !== fingerprint.digest || !Array.isArray(manifest.artifacts) || !expectations) return false;
    const expected = expectations.expectedArtifacts;
    if (!Array.isArray(expected) || expected.length === 0 || new Set(expected).size !== expected.length ||
        expected.some((filename) => !safeFilename.test(filename))) return false;
    if (manifest.version !== expectations.version || manifest.git_revision !== expectations.expectedRevision ||
        typeof manifest.working_tree_clean !== "boolean" || (expectations.requireClean && manifest.working_tree_clean !== true) ||
        manifest.registry_published !== false || manifest.publication !== "not-performed") return false;
    if (!Array.isArray(manifest.expected_artifacts) || manifest.expected_artifacts.length !== expected.length ||
        new Set(manifest.expected_artifacts).size !== expected.length || manifest.expected_artifacts.some((filename) => !expected.includes(filename))) return false;
    if (manifest.artifacts.length !== expected.length || manifest.artifacts.some((artifact) => !expected.includes(artifact.filename))) return false;
    const entries = await readdir(directory);
    const expectedEntries = [...expected, "manifest.json"];
    if (entries.length !== expectedEntries.length || entries.some((entry) => !expectedEntries.includes(entry))) return false;
    if (!(await lstat(resolve(directory, "manifest.json"))).isFile()) return false;
    if (new Set(manifest.artifacts.map((artifact) => artifact.filename)).size !== manifest.artifacts.length) return false;
    for (const artifact of manifest.artifacts) {
      if (typeof artifact.filename !== "string" || !safeFilename.test(artifact.filename) ||
          !Number.isSafeInteger(artifact.bytes) || artifact.bytes < 0 || !/^[a-f0-9]{64}$/.test(artifact.sha256)) return false;
      const path = resolve(directory, artifact.filename);
      if (!(await lstat(path)).isFile()) return false;
      const bytes = await readFile(path);
      if (artifact.bytes !== bytes.length || artifact.sha256 !== createHash("sha256").update(bytes).digest("hex")) return false;
    }
    return true;
  } catch {
    return false;
  }
}

async function main() {
  const { values } = parseArgs({ options: Object.fromEntries(["artifacts", "policy", "ci-run", "out"].map((name) => [name, { type: "string" }])) });
  if (values["ci-run"] && !/^\d+$/.test(values["ci-run"])) throw new TypeError("Invalid CI run identifier");
  const fingerprint = await acceptanceFingerprint(root);
  const revision = (await execute("git", ["rev-parse", "--verify", "HEAD^{commit}"], { cwd: root })).stdout.trim();
  const checks = [];
  let metadata;
  let policy;
  let expectedArtifacts = [];
  const check = async (name, callback) => {
    try { checks.push({ name, status: await callback() ? "passed" : "unverified" }); }
    catch { checks.push({ name, status: "unverified" }); }
  };
  await check("committed-sources", async () => !(await execute("git", ["status", "--porcelain=v1", "--untracked-files=all"], { cwd: root })).stdout.trim());
  await check("consistent-server-sdk-versions", async () => {
    metadata = await releaseMetadata(root);
    const mixSource = await readFile(resolve(root, "mix.exs"), "utf8");
    return metadata.packages.every((manifest) => manifest.license === "Apache-2.0" && manifest.private !== true && manifest.publishConfig?.access === "public") &&
      mixSource.includes('licenses: ["Apache-2.0"]') && mixSource.includes("package: package()");
  });
  await check("maintainer-license-and-release-policy", async () => {
    metadata ??= await releaseMetadata(root);
    policy = JSON.parse(await readFile(resolve(values.policy ?? resolve(root, "deploy/release-policy.json")), "utf8"));
    const licenseText = await readFile(resolve(root, policy.licenseFile), "utf8");
    const approved = validateReleasePolicy(policy, metadata, licenseText);
    if (approved) expectedArtifacts = resolveArtifactInventory(metadata, policy);
    return approved;
  });
  await check("current-source-artifacts", async () => verifyArtifacts(resolve(values.artifacts ?? resolve(root, ".local/releases")), fingerprint, {
    version: metadata?.version,
    expectedRevision: revision,
    expectedArtifacts,
    requireClean: true,
  }));
  await check("hosted-ci-exact-revision-both-matrices", async () => {
    if (!values["ci-run"]) return false;
    const remote = (await execute("git", ["remote", "get-url", "origin"], { cwd: root })).stdout.trim();
    const repository = remote.match(/github\.com[:/]([^/]+\/[^/.]+)(?:\.git)?$/)?.[1];
    if (!repository) return false;
    const get = async (path) => JSON.parse((await execute("gh", ["api", `repos/${repository}/${path}`], { cwd: root, timeout: 15000 })).stdout);
    const run = await get(`actions/runs/${values["ci-run"]}`);
    const jobPage = await get(`actions/runs/${values["ci-run"]}/jobs?per_page=100`);
    return hostedCiRunPasses({ run, jobPage, revision, expectedRunId: values["ci-run"], repository });
  });
  await check("source-stability", async () => releaseSourceMatches(root, fingerprint, revision));
  const report = { checkedAt: new Date().toISOString(), revision, sourceFingerprint: fingerprint, expectedArtifactInventory: expectedArtifacts, checks,
    readyForMaintainerReview: checks.every((check) => check.status === "passed"), externalAcceptance: "manual-review-required; registry ownership, credentials and publication approval are external gates", publication: "not-performed" };
  const path = resolve(values.out ?? resolve(root, ".local/readiness", `release-check-${Date.now()}.json`));
  await mkdir(resolve(path, ".."), { recursive: true, mode: 0o700 });
  await writeFile(path, JSON.stringify(report, null, 2) + "\n", { flag: "wx", mode: 0o600 });
  for (const check of checks) console.log(`${check.name}: ${check.status}`);
  console.log(`Release preflight: ${path}; no publication performed`);
  if (!report.readyForMaintainerReview) process.exitCode = 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await main(); } catch { console.error("Release preflight could not start; verify arguments and prerequisites"); process.exitCode = 1; }
}
