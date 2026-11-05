import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const number = (value) => value === null || value === undefined ? "—" : value.toFixed(2);
const safe = (value) => String(value).replace(/[|\r\n]/g, " ");

export function markdown(runs) {
  const lines = ["# Fyrlet benchmark report", "", "Each row is one repetition. Percentiles are computed from raw samples; percentiles are not averaged.", "",
    "| Target / label | Scenario / repeat | Users × observers | Rows / bytes | Pass | Writes/s¹ | Propagation p50/p95/p99 ms | Coverage | Recovery p95 ms | Payload received KiB² | App peak MiB | DB peak MiB |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"];
  for (const run of runs) {
    for (const result of run.results) {
      const workload = result.workload;
      const propagation = result.propagationMs;
      const received = (result.traffic.httpReceived ?? 0) + (result.traffic.socketReceived ?? 0);
      const coverage = result.deliveryCoverage === null ? "—" : `${number(result.deliveryCoverage * 100)}%`;
      lines.push(`| ${safe(run.target)} / ${safe(run.label)} | ${safe(result.scenario)} / ${result.repetition} | ${workload.users} × ${workload.devices} | ${workload.rows} / ${workload.payloadBytes} | ${result.success ? "yes" : "NO"} | ${number(result.writeRequestsPerSecond)} | ${number(propagation.p50)} / ${number(propagation.p95)} / ${number(propagation.p99)} | ${coverage} | ${number(result.recoveryMs.p95)} | ${number(received / 1024)} | ${number(result.resources?.sampled ? result.resources.application.peakRssBytes / 1048576 : null)} | ${number(result.resources?.sampled ? result.resources.database.peakRssBytes / 1048576 : null)} |`);
    }
  }
  lines.push("", "¹ Observed closed-loop request rate; burst includes write acknowledgements, while converge scenarios wait for all observers. This is not server maximum throughput.",
    "² HTTP response bodies and WebSocket payloads, after warmup; excludes protocol framing, headers and TLS. Full snapshots and deltas are both materialized into the same bounded view.",
    "", "Propagation begins before the write request and ends when an observer applies a matching server record. Coverage is observed intermediate deliveries / potential deliveries. Always evaluate coverage and final correctness beside latency; unobserved intermediate states in burst/slow/reconnect are not treated as lost final data.",
    "", "No automatic winner is assigned. Compare matching workloads, versions, resource budgets, topology and guarantees. Smoke runs verify the harness only.");
  for (const run of runs) {
    const workloads = [...new Map(run.results.map((result) => [result.scenario, result.workload])).values()];
    lines.push("", `## ${safe(run.target)} / ${safe(run.label)}`, "", `Created: ${run.createdAt}; run: ${run.runId}; profile: ${run.profile}.`, "", "```json", JSON.stringify({ environment: run.environment, workloads, capabilities: run.capabilities, measurement: run.measurement }, null, 2), "```");
    for (const result of run.results) {
      if (result.errors.length || result.resources?.errors.length) lines.push("", `Errors for ${result.scenario}/${result.repetition}: ${safe(JSON.stringify({ scenario: result.errors, resources: result.resources?.errors }))}`);
    }
  }
  return lines.join("\n") + "\n";
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length < 3) throw new Error("Usage: node bench/report.mjs RESULTS_JSON [RESULTS_JSON ...]");
    const runs = await Promise.all(process.argv.slice(2).map(async (path) => JSON.parse(await readFile(path, "utf8"))));
    process.stdout.write(markdown(runs));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
