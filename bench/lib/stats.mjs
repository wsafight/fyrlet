export function summary(samples) {
  if (!samples.length) return { count: 0, min: null, p50: null, p95: null, p99: null, max: null, mean: null };
  const sorted = [...samples].sort((left, right) => left - right);
  const percentile = (fraction) => sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)];
  return {
    count: sorted.length, min: sorted[0], p50: percentile(0.5), p95: percentile(0.95),
    p99: percentile(0.99), max: sorted.at(-1), mean: sorted.reduce((total, value) => total + value, 0) / sorted.length,
  };
}

export function view(records) {
  return records.map(({ id, text, version }) => ({ id, text, version }))
    .sort((left, right) => left.id.localeCompare(right.id));
}

export function assertView(actual, expected) {
  if (JSON.stringify(view(actual)) !== JSON.stringify(view(expected))) {
    throw new Error("Final materialized view differs from committed records");
  }
}

export function payload(marker, bytes) {
  if (Buffer.byteLength(marker) > bytes) throw new Error("Marker exceeds payload size");
  return marker + "x".repeat(bytes - Buffer.byteLength(marker));
}
