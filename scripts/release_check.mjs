import { parseArgs } from "node:util";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { acceptanceFingerprint } from "./acceptance.mjs";

const execute = promisify(execFile);
const root = fileURLToPath(new URL("../", import.meta.url));
export async function verifyArtifacts(directory, fingerprint) {
  const manifest = JSON.parse(await readFile(resolve(directory, "manifest.json"), "utf8"));
  if (manifest.source_fingerprint?.digest !== fingerprint.digest || !Array.isArray(manifest.artifacts) || manifest.artifacts.length !== 3) return false;
  if (new Set(manifest.artifacts.map((artifact) => artifact.filename)).size !== 3) return false;
  for (const artifact of manifest.artifacts) {
    if (!/^[a-zA-Z0-9][\w.-]+$/.test(artifact.filename)) return false;
    const bytes = await readFile(resolve(directory, artifact.filename));
    if (artifact.bytes !== bytes.length || artifact.sha256 !== createHash("sha256").update(bytes).digest("hex")) return false;
  }
  return true;
}

async function main() {
  const { values } = parseArgs({ options: Object.fromEntries(["artifacts", "policy", "ci-run", "out"].map((name) => [name, { type: "string" }])) });
  if (values["ci-run"] && !/^\d+$/.test(values["ci-run"])) throw new TypeError("Invalid CI run identifier");
  const fingerprint = await acceptanceFingerprint(root);
  const revision = (await execute("git", ["rev-parse", "HEAD"], { cwd: root })).stdout.trim();
  const checks = [];
  const check = async (name, callback) => {
    try { checks.push({ name, status: await callback() ? "passed" : "unverified" }); }
    catch { checks.push({ name, status: "unverified" }); }
  };
  await check("committed-sources", async () => !(await execute("git", ["status", "--porcelain"], { cwd: root })).stdout.trim());
  await check("current-source-artifacts", async () => verifyArtifacts(resolve(values.artifacts ?? resolve(root, ".local/releases")), fingerprint));
  await check("consistent-server-sdk-versions", async () => {
    const server = (await readFile(resolve(root, "mix.exs"), "utf8")).match(/version: "([^"]+)"/)[1];
    const versions = await Promise.all(["sdks/typescript", "sdks/react"].map(async (directory) => JSON.parse(await readFile(resolve(root, directory, "package.json"), "utf8")).version));
    return versions.every((version) => version === server);
  });
  await check("maintainer-license-and-release-policy", async () => {
    const policy = JSON.parse(await readFile(resolve(values.policy ?? resolve(root, "deploy/release-policy.json")), "utf8"));
    if (policy.maintainerApproved !== true || !["license", "compatibility", "deprecation", "registries"].every((name) => typeof policy[name] === "string" && policy[name].trim())) return false;
    if (typeof policy.licenseFile !== "string" || !/^LICENSE(?:\.[a-zA-Z0-9_-]+)?$/.test(policy.licenseFile)) return false;
    return (await readFile(resolve(root, policy.licenseFile), "utf8")).trim().length > 0;
  });
  await check("hosted-ci-exact-revision-both-matrices", async () => {
    if (!values["ci-run"]) return false;
    const remote = (await execute("git", ["remote", "get-url", "origin"], { cwd: root })).stdout.trim();
    const repository = remote.match(/github\.com[:/]([^/]+\/[^/.]+)(?:\.git)?$/)?.[1];
    if (!repository) return false;
    const get = async (path) => JSON.parse((await execute("gh", ["api", `repos/${repository}/${path}`], { cwd: root, timeout: 15000 })).stdout);
    const run = await get(`actions/runs/${values["ci-run"]}`);
    const jobs = await get(`actions/runs/${values["ci-run"]}/jobs?per_page=100`);
    return run.head_sha === revision && run.status === "completed" && run.conclusion === "success" &&
      ["test (1.18, 27)", "test (1.20, 29)"].every((name) => jobs.jobs.some((job) => job.name === name && job.conclusion === "success"));
  });
  const report = { checkedAt: new Date().toISOString(), revision, sourceFingerprint: fingerprint, checks,
    readyForMaintainerReview: checks.every((check) => check.status === "passed"), externalAcceptance: "manual-review-required; use the release checklist", publication: "not-performed" };
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
