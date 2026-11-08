import { immutable } from "./delta.js";

export function queryKey(value: unknown): string { return queryParameters(value).key; }

export function queryParameters(value: unknown): { key: string; value: unknown } {
  const seen = new Set<object>();
  function encode(value: unknown): string {
    if (value === null || typeof value === "string" || typeof value === "boolean") return JSON.stringify(value);
    if (typeof value === "number" && Number.isFinite(value)) return JSON.stringify(value);
    if (typeof value !== "object" || seen.has(value)) throw new TypeError("Shared query parameters must be finite JSON values without cycles");
    seen.add(value);
    try {
      if (Array.isArray(value)) return `[${Array.from(value, encode).join(",")}]`;
      if (Object.getPrototypeOf(value) !== Object.prototype && Object.getPrototypeOf(value) !== null) {
        throw new TypeError("Shared query parameters must use plain JSON objects");
      }
      const record = value as Record<string, unknown>;
      return `{${Object.keys(record).sort().map((key) => `${JSON.stringify(key)}:${encode(record[key])}`).join(",")}}`;
    } finally { seen.delete(value); }
  }
  const key = encode(value);
  if (new TextEncoder().encode(key).byteLength > 65_536) throw new TypeError("Shared query parameters must fit within 64 KiB");
  return { key, value: immutable(JSON.parse(key)) };
}
