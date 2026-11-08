import { parseArgs } from "node:util";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { sourceFingerprint, verifySourceFingerprint } from "../lib/manifest.mjs";
import { launch } from "../lib/process.mjs";

export function scanConfiguration(arguments_) {
  const { values } = parseArgs({ args: arguments_, options: Object.fromEntries(
    ["image", "rates", "repeats", "duration-ms", "label", "users", "devices", "scenario"].map((name) => [name, { type: "string" }])) });
  const positive = (raw, minimum, maximum) => {
    const value = Number(raw);
    if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new Error(`Expected integer in ${minimum}..${maximum}`);
    return value;
  };
  const label = values.label ?? `scan-${Date.now()}`;
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,50}$/.test(label)) throw new Error("Invalid scan label");
  const list = (raw, fallback, maximum) => [...new Set((raw ?? fallback).split(",").map((value) => positive(value, 1, maximum)))];
  const users = list(values.users, process.env.USERS ?? "1000", 5000);
  const devices = list(values.devices, process.env.DEVICES ?? "2", 100);
  if (users.some((count) => devices.some((fanout) => count * fanout > 5000))) throw new Error("A point is limited to 5000 observers");
  const scenario = values.scenario ?? "soak";
  if (!["soak", "mixed"].includes(scenario)) throw new Error("Invalid fair scenario");
  return { image: values.image ?? "fair-fyrlet:current", label, users, devices, scenario, dimensions: values.users !== undefined || values.devices !== undefined,
    rates: [...new Set((values.rates ?? "100,500,800,1000").split(",").map((rate) => positive(rate, 1, 10000)))],
    repeats: positive(values.repeats ?? 3, 3, 20), durationMs: positive(values["duration-ms"] ?? 60000, 1000, 600000) };
}

async function main() {
  const config = scanConfiguration(process.argv.slice(2));
  const root = fileURLToPath(new URL("../../", import.meta.url));
  const fingerprint = await sourceFingerprint(root);
  const output = resolve(process.env.FAIR_OUT ?? resolve(root, ".local/fair"));
  const report = { createdAt: new Date().toISOString(), config, sourceFingerprint: fingerprint, runs: [],
    caveat: "Only measured points where every repetition passes qualify. Generator drops do not prove server saturation. No interpolation or production-capacity claim." };
  await mkdir(output, { recursive: true });
  await writeFile(resolve(output, `${config.label}.json`), JSON.stringify(report, null, 2) + "\n", { flag: "wx", mode: 0o600 });
  let child;
  let interrupted = false;
  const stop = () => { interrupted = true; void child?.stop(); };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  try {
    for (let repetition = 1; repetition <= config.repeats; repetition++) {
      const points = config.users.flatMap((users) => config.devices.flatMap((devices) => config.rates.map((rate) => ({ users, devices, rate }))));
      if (repetition % 2 === 0) points.reverse();
      for (const { users, devices, rate } of points) {
        if (interrupted) throw new Error("Scan interrupted");
        await verifySourceFingerprint(root, fingerprint);
        const tag = `${config.label}${config.dimensions ? `-${users}u-${devices}d` : ""}-r${repetition}-${rate}`;
        child = launch("bash", ["bench/fair/run.sh", config.image, String(rate), tag, String(config.durationMs)],
          { cwd: root, env: { ...process.env, USERS: String(users), DEVICES: String(devices), FAIR_SCENARIO: config.scenario, GENERATORS: process.env.GENERATORS ?? String(Math.min(4, users, rate)) }, stdio: "inherit" });
        const exited = await child.finished;
        child = undefined;
        await verifySourceFingerprint(root, fingerprint);
        let summary;
        try { summary = JSON.parse(await readFile(resolve(output, "runs", tag, "summary.json"), "utf8")); }
        catch (error) { if (error.code !== "ENOENT") throw error; }
        report.runs.push({ users, devices, rate, repetition, tag, exitCode: exited.code, summary });
        await writeFile(resolve(output, `${config.label}.json`), JSON.stringify(report, null, 2) + "\n");
      }
    }
  } finally {
    if (child) await child.stop();
    process.removeListener("SIGINT", stop);
    process.removeListener("SIGTERM", stop);
  }
  const points = config.users.flatMap((users) => config.devices.flatMap((devices) => config.rates.map((rate) => {
    const runs = report.runs.filter((run) => run.rate === rate && run.users === users && run.devices === devices);
    return { users, devices, rate, pass: runs.length === config.repeats && runs.every((run) => run.exitCode === 0 && run.summary?.sourceMatches && run.summary.capacity.pass) };
  })));
  report.points = points;
  await writeFile(resolve(output, `${config.label}.json`), JSON.stringify(report, null, 2) + "\n");
  console.log(JSON.stringify({ report: resolve(output, `${config.label}.json`), points }));
  if (report.runs.some((run) => run.exitCode !== 0 || !run.summary?.sourceMatches)) process.exitCode = 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
