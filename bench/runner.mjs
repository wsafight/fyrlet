import { readFile, mkdir, writeFile, rename } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { cpus, totalmem, platform, release, arch, hostname } from "node:os";
import { configuration, help } from "./lib/config.mjs";
import { runScenario } from "./lib/scenario.mjs";
import { markdown } from "./report.mjs";
import { sourceFingerprint } from "./lib/manifest.mjs";

export async function run(config) {
  if (config.target === "all") throw new Error("Use the local launcher for --target all");
  if (!config.endpoint || !config.fixtures || !config.out) throw new Error("endpoint, fixtures and out are required");
  const endpoint = new URL(config.endpoint);
  if (!["http:", "https:"].includes(endpoint.protocol) || endpoint.username || endpoint.password || endpoint.search || endpoint.hash) {
    throw new Error("endpoint must be an HTTP(S) URL without credentials, query or fragment");
  }
  const fixture = JSON.parse(await readFile(config.fixtures, "utf8"));
  if (fixture.target !== config.target || fixture.rows !== config.rows || fixture.payload_bytes !== config.payloadBytes ||
      fixture.users.length < Math.max(...config.scenarios.map((scenario) => scenario.users))) throw new Error("Fixtures do not match the selected workload");
  const adapter = await import(`./adapters/${config.target}.mjs`);
  const root = fileURLToPath(new URL("../", import.meta.url));
  const sdk = JSON.parse(await readFile(new URL("../sdks/typescript/package.json", import.meta.url), "utf8"));
  const result = {
    formatVersion: 1, createdAt: new Date().toISOString(), runId: fixture.run_id, label: config.label,
    target: config.target, profile: config.profile, endpoint: endpoint.origin,
    environment: {
      hostname: hostname(), platform: platform(), release: release(), arch: arch(),
      logicalCpus: cpus().length, cpu: cpus()[0]?.model, totalMemoryBytes: totalmem(), generatorNode: process.version,
      applicationMode: process.env.BENCH_APPLICATION_MODE ?? "external-unverified",
      versions: JSON.parse(process.env.BENCH_VERSIONS ?? "{}"), sdkVersion: sdk.version,
      databaseShared: process.env.BENCH_DATABASE_SHARED !== "false",
      topology: process.env.BENCH_TOPOLOGY ?? "external; record topology separately",
      sourceRevision: process.env.BENCH_REVISION ?? "working-tree-unrecorded",
      sourceFingerprint: await sourceFingerprint(root),
    },
    capabilities: adapter.capabilities,
    measurement: {
      propagation: "writer request start to another client's applied server view; no local optimistic result",
      load: "closed-loop per-user versioned writes; bounded parallel users, not a maximum-throughput claim",
      traffic: "UTF-8 HTTP JSON bodies + WebSocket application payloads; excludes headers, framing, TLS and compression",
      cpu: "sampled process CPU-time deltas; includes application descendants and separately sampled database tree",
      caveats: ["Local generator shares the host with services", "Short smoke runs do not establish capacity", "Burst/slow/reconnect may coalesce intermediate states; final views must match", "First-ready samples include client setup and are collected before warmup"],
    },
    results: [],
  };
  const output = resolve(config.out);
  await mkdir(output, { recursive: true });
  const persist = async () => {
    await writeFile(resolve(output, "results.json.tmp"), JSON.stringify(result, null, 2) + "\n");
    await rename(resolve(output, "results.json.tmp"), resolve(output, "results.json"));
    await writeFile(resolve(output, "report.md"), markdown([result]));
  };
  await persist();
  for (let repetition = 1; repetition <= config.repeats; repetition++) {
    for (const scenario of config.scenarios) {
      console.log(`${config.target} ${scenario.name} ${repetition}/${config.repeats}: ${scenario.users} users x ${scenario.devices} observers`);
      const measured = await runScenario(adapter, fixture, config, scenario, repetition);
      result.results.push(measured);
      await persist();
      const latency = measured.propagationMs.p95 === null ? "n/a" : `${measured.propagationMs.p95.toFixed(2)}ms`;
      console.log(`${measured.success ? "PASS" : "FAIL"} ${scenario.name}; writes=${measured.completedWrites}; propagation p95=${latency}; coverage=${measured.deliveryCoverage?.toFixed(3) ?? "n/a"}`);
      if (!measured.success) {
        console.error(measured.errors.map((error) => error.message).join("; "));
        throw new Error(`Benchmark correctness failed; inspect ${resolve(output, "report.md")}`);
      }
    }
  }
  console.log(`Results: ${resolve(output, "results.json")}`);
  return result;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const config = configuration(process.argv.slice(2));
    if (config.help) console.log(help);
    else await run(config);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
