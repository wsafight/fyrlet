import { parseArgs } from "node:util";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./lib/process.mjs";
import { capacityVerdict } from "./lib/load.mjs";
import { sourceFingerprint, verifySourceFingerprint } from "./lib/manifest.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const options = Object.fromEntries(["levels", "rates", "devices", "duration-ms", "repeats", "rows", "payload-bytes",
  "concurrency", "warmup", "timeout-ms", "out", "p95-ms", "min-coverage", "max-drop-rate", "target", "sessions"].map((name) => [name, { type: "string" }]));
options.help = { type: "boolean", short: "h" };
const { values } = parseArgs({ options });
const help = `node bench/capacity.mjs --levels 100,500,1000 --rates 100,300 --duration-ms 60000 --repeats 2
Runs fresh local servers sequentially. Build the TypeScript SDK first. Defaults: both targets, 2 devices/user,
50 rows, 128-byte text, concurrency 64, warmup 1, 60s duration, 2 repeats; SLO p95<=250ms, coverage>=99%, drops<=1%.
Reports verified load points, not production maximum capacity. Source files must remain unchanged during the suite.`;

async function main() {
  if (values.help) { console.log(help); return; }
  const fingerprint = await sourceFingerprint(root);
  const list = (value, fallback, maximum) => {
    const items = (value ?? fallback).split(",").map(Number);
    if (items.some((item) => !Number.isSafeInteger(item) || item < 1 || item > maximum)) throw new Error("Invalid capacity levels/rates");
    return [...new Set(items)];
  };
  const levels = list(values.levels, "100,500,1000", 5000);
  const rates = list(values.rates, "100", 10000);
  const targets = values.target && values.target !== "all" ? [values.target] : ["fyrlet", "meteor"];
  if (targets.some((target) => !["fyrlet", "meteor"].includes(target))) throw new Error("Invalid target");
  const limits = { p95Ms: Number(values["p95-ms"] ?? 250), minCoverage: Number(values["min-coverage"] ?? 0.99),
    maxDropRate: Number(values["max-drop-rate"] ?? 0.01) };
  if (!Number.isFinite(limits.p95Ms) || limits.p95Ms <= 0 ||
      [limits.minCoverage, limits.maxDropRate].some((value) => !Number.isFinite(value) || value < 0 || value > 1)) throw new Error("Invalid SLO limits");
  const output = resolve(values.out ?? resolve(root, ".local/bench", `capacity-${Date.now()}`));
  const forwarded = { devices: "2", "duration-ms": "60000", repeats: "2", rows: "50", "payload-bytes": "128",
    concurrency: "64", warmup: "1", "timeout-ms": "30000", sessions: "shared" };
  const report = { createdAt: new Date().toISOString(), limits, levels, rates, sessions: values.sessions ?? "shared", runs: [],
    caveat: "Observational only: cohosted generator/services, unverified resource and guarantee equivalence; one converging write per user; not a production maximum" };
  let child;
  let interrupted = false;
  const stop = () => { interrupted = true; void child?.stop(); };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  await mkdir(output, { recursive: true });
  const persist = async () => {
    await writeFile(resolve(output, "capacity.json"), JSON.stringify(report, null, 2) + "\n");
    const rows = report.runs.flatMap((run) => run.results.map((result) => {
      const load = result.pacedLoad;
      return `| ${run.target} | ${run.users} | ${run.rate} | ${result.repetition} | ${result.connections?.total ?? "—"} | ${result.capacity.pass ? "yes" : "NO"} | ${result.completedWrites} | ${result.propagationMs.p95?.toFixed(2) ?? "—"} | ${result.deliveryCoverage ?? "—"} | ${result.capacity.dropRate?.toFixed(4) ?? "—"} | ${load?.generatorDropped ?? "—"} |`;
    }));
    const failures = report.runs.filter((run) => run.exitCode !== 0).map((run) => `${run.target}/${run.users}/${run.rate}: launcher exit ${run.exitCode}; inspect ${run.path}`);
    await writeFile(resolve(output, "capacity.md"), ["# Local verified capacity points", "", report.caveat, "",
      `Limits: ${JSON.stringify(limits)}. Sessions: ${report.sessions}. Every repetition must pass; no interpolation between points.`, "",
      "| Target | Users | Offered/s | Repeat | Connections | SLO pass | Writes | Prop p95 ms | Coverage | Dropped rate | Generator drops |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |", ...rows, "", ...failures].join("\n") + "\n");
  };
  try {
    for (const users of levels) for (const rate of rates) for (const target of targets) {
      if (interrupted) throw new Error("Capacity suite interrupted");
      await verifySourceFingerprint(root, fingerprint);
      const path = resolve(output, `${users}-users-${rate}-rate`, target);
      const args = ["bench/local.mjs", "--scenario", "soak", "--target", target, "--users", String(users), "--rate", String(rate), "--out", path];
      for (const [name, fallback] of Object.entries(forwarded)) args.push(`--${name}`, values[name] ?? fallback);
      console.log(`Capacity: ${target}; ${users} users at ${rate} offered writes/s`);
      child = launch(process.execPath, args, { cwd: root, env: process.env, stdio: "inherit" });
      const exited = await child.finished;
      child = undefined;
      await verifySourceFingerprint(root, fingerprint);
      let results = [];
      try { results = JSON.parse(await readFile(resolve(path, target, "results.json"), "utf8")).results; }
      catch (error) { if (error.code !== "ENOENT") throw error; }
      report.runs.push({ target, users, rate, path, exitCode: exited.code,
        results: results.map((result) => ({ ...result, samples: undefined, capacity: capacityVerdict(result, limits) })) });
      await persist();
    }
  } finally {
    if (child) await child.stop();
    process.removeListener("SIGINT", stop);
    process.removeListener("SIGTERM", stop);
  }
  console.log(`Capacity report: ${resolve(output, "capacity.md")}`);
  if (report.runs.some((run) => run.exitCode !== 0 || !run.results.length || run.results.some((result) => !result.capacity.pass))) process.exitCode = 1;
}

try { await main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
