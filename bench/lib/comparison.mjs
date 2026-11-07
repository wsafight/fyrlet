function signature(value) {
  if (Array.isArray(value)) return value.map(signature);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, signature(value[key])]));
  }
  return value;
}

function matching(values) {
  return values.every((value) => value === values[0]);
}

export function comparisonAssessment(runs) {
  if (new Set(runs.map((run) => run.target)).size < 2) {
    return { status: "single-target", reasons: ["A single target does not establish comparative performance."] };
  }
  const reasons = [
    "Application and database CPU/memory limits are not OS-enforced or verified by this harness; BEAM scheduler counts are not CPU quotas.",
    "Equivalent authorization, revocation, acknowledgement and durability guarantees have not been verified for these reference applications.",
    "Generator isolation and equivalent production deployment paths require a separate deployment audit.",
  ];
  const workloadsRecorded = runs.every((run) => run.results.length > 0 && run.results.every((result) =>
    result.workload && Object.hasOwn(result.workload, "timeoutMs")));
  const workloadsMatch = workloadsRecorded && matching(runs.map((run) => JSON.stringify(run.results.map((result) =>
    signature({ repetition: result.repetition, workload: result.workload })).map(JSON.stringify).sort())));
  if (!workloadsMatch) reasons.push(workloadsRecorded ? "Workloads or repetition counts differ." : "Complete workload settings, including timeouts, are missing.");
  const fingerprints = runs.map((run) => run.environment?.sourceFingerprint?.digest);
  const sourceMatches = fingerprints.every((digest) => typeof digest === "string" && /^[a-f0-9]{64}$/.test(digest)) && matching(fingerprints);
  if (!sourceMatches) reasons.push("Source fingerprints are missing or differ.");
  const hostFields = ["hostname", "platform", "release", "arch", "cpu", "logicalCpus", "totalMemoryBytes", "generatorNode"];
  const hostsRecorded = runs.every((run) => hostFields.every((field) => run.environment?.[field] !== undefined));
  const hostsMatch = hostsRecorded && matching(runs.map((run) => JSON.stringify(hostFields.map((field) => run.environment[field]))));
  if (!hostsMatch) reasons.push("Host or generator metadata are missing or differ.");
  return { status: "observational-only", workloadsMatch, sourceMatches, hostsMatch, reasons };
}
