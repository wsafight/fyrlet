import { parseArgs } from "node:util";
import { mkdir, open, writeFile, rename, readFile, lstat, readlink } from "node:fs/promises";
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "../bench/lib/process.mjs";

const execute = promisify(execFile);

const root = fileURLToPath(new URL("../", import.meta.url));
const groups = {
  core: [["mix", "format", "--check-formatted"], ["mix", "compile", "--warnings-as-errors"], ["bash", "scripts/test_all.sh"]],
  client: [["npm", "--prefix", "sdks/typescript", "run", "test:coverage"], ["npm", "--prefix", "sdks/typescript", "run", "typecheck"],
    ["npm", "--prefix", "sdks/react", "run", "test:coverage"], ["npm", "--prefix", "sdks/react", "run", "typecheck"],
    ["npm", "--prefix", "examples/inbox-react", "run", "test:coverage"]],
  bench: [["npm", "--prefix", "bench", "test"]],
  host: [["bash", "scripts/host_store.sh"]],
  contract: [["bash", "-c", "mkdir -p .local/readiness; (cd examples/inbox && mix fyrlet.contract ../../.local/readiness/contract.json)"],
    ["node", "scripts/check_contract.mjs", ".local/readiness/contract.json"]],
  integration: [["bash", "scripts/integration.sh"]],
  restore: [["node", "scripts/restore_smoke.mjs"]],
  browser: [["bash", "scripts/react.sh"]],
  package: [["bash", "scripts/package.sh"], ["bash", "scripts/install_smoke.sh"]],
  site: [["npm", "--prefix", "site", "run", "build"], ["npm", "--prefix", "site", "run", "check"]],
};

export function acceptancePlan(selected = Object.keys(groups).join(",")) {
  const names = selected.split(",");
  if (names.some((name) => !Object.hasOwn(groups, name)) || new Set(names).size !== names.length) throw new Error("Unknown or duplicate acceptance group");
  return names.flatMap((group) => groups[group].map((command, index) => ({ group, name: `${group}-${index + 1}`, command })));
}

export async function acceptanceFingerprint(directory) {
  const { stdout } = await execute("git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"], { cwd: directory, maxBuffer: 16 * 1024 * 1024 });
  const paths = [...new Set(stdout.split("\0").filter(Boolean))].sort();
  const hash = createHash("sha256");
  for (const path of paths) {
    hash.update(path + "\0");
    try {
      const file = resolve(directory, path);
      const stat = await lstat(file);
      hash.update(stat.isSymbolicLink() ? "link\0" : "file\0");
      hash.update(String(stat.mode & 0o111) + "\0");
      const bytes = stat.isSymbolicLink() ? Buffer.from(await readlink(file)) : await readFile(file);
      hash.update(String(bytes.byteLength) + "\0");
      hash.update(bytes);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      hash.update("deleted\0");
    }
  }
  return { algorithm: "sha256", digest: hash.digest("hex"), fileCount: paths.length, scope: "Git tracked and non-ignored untracked files" };
}

async function main() {
  const { values } = parseArgs({ options: { groups: { type: "string" }, out: { type: "string" }, help: { type: "boolean" } } });
  if (values.help) { console.log(`node scripts/acceptance.mjs [--groups ${Object.keys(groups).join(",")}] [--out DIRECTORY]`); return; }
  const plan = acceptancePlan(values.groups);
  const output = resolve(values.out ?? resolve(root, ".local/readiness", `local-${Date.now()}`));
  await mkdir(output, { recursive: true, mode: 0o700 });
  const fingerprint = await acceptanceFingerprint(root);
  const verify = async () => {
    if ((await acceptanceFingerprint(root)).digest !== fingerprint.digest) throw new Error("Acceptance sources changed during verification; rerun with frozen sources");
  };
  const report = { startedAt: new Date().toISOString(), sourceFingerprint: fingerprint, status: "running", stages: [],
    external: { remoteCI: "not-run", externalIdP: "not-run", physicalDevices: "not-run", multiHostFaults: "not-run", stability24h: "not-run", realMail: "not-run", registryPublication: "deferred" } };
  const persist = async () => {
    await writeFile(resolve(output, "result.json.tmp"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
    await rename(resolve(output, "result.json.tmp"), resolve(output, "result.json"));
  };
  await writeFile(resolve(output, "result.json"), JSON.stringify(report, null, 2) + "\n", { mode: 0o600, flag: "wx" });
  let child;
  let interrupted = false;
  const stop = () => { interrupted = true; void child?.stop(); };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  try {
    for (const stage of plan) {
      if (interrupted) throw new Error("Acceptance interrupted");
      await verify();
      const startedAt = new Date().toISOString();
      const log = await open(resolve(output, `${stage.name}.log`), "wx", 0o600);
      console.log(`Checking ${stage.name}: ${stage.command.join(" ")}`);
      let timedOut = false;
      try {
        child = launch(stage.command[0], stage.command.slice(1), { cwd: root, env: process.env, stdio: ["ignore", log.fd, log.fd] });
        const timeout = setTimeout(() => { timedOut = true; void child?.stop(); }, 30 * 60_000);
        let exited;
        try { exited = await child.finished; } finally { clearTimeout(timeout); }
        child = undefined;
        const status = exited.code === 0 && !timedOut && !interrupted ? "passed" : "failed";
        report.stages.push({ ...stage, startedAt, finishedAt: new Date().toISOString(), status, exitCode: exited.code, timedOut });
        await persist();
        await verify();
        if (status !== "passed") throw new Error(`Acceptance failed at ${stage.name}; inspect ${resolve(output, `${stage.name}.log`)}`);
      } finally { await log.close(); }
    }
    report.status = "passed";
  } catch (error) {
    report.status = "failed";
    report.failure = error.message;
    throw error;
  } finally {
    if (child) await child.stop();
    report.finishedAt = new Date().toISOString();
    await persist();
    process.removeListener("SIGINT", stop);
    process.removeListener("SIGTERM", stop);
    console.log(`Acceptance report: ${resolve(output, "result.json")}`);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
