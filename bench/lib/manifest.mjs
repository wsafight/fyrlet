import { readdir, readFile } from "node:fs/promises";
import { resolve, relative } from "node:path";
import { createHash } from "node:crypto";

export function schedulerOptions(environment) {
  const options = [];
  for (const name of ["ERL_AFLAGS", "ERL_FLAGS", "ELIXIR_ERL_OPTIONS", "ERL_ZFLAGS"]) {
    const flags = environment[name] ?? "";
    for (const match of flags.matchAll(/(?:^|\s)(\+S|\+sbwt|\+sbwtdcpu|\+sbwtdio)\s+([a-z0-9:]+)/g)) {
      options.push({ source: name, flag: match[1], value: match[2] });
    }
  }
  return options;
}

export async function sourceFingerprint(root) {
  const files = [];
  const collect = async (path) => {
    for (const entry of await readdir(path, { withFileTypes: true })) {
      if (["node_modules", "dist", "local", ".DS_Store"].includes(entry.name)) continue;
      const nested = resolve(path, entry.name);
      if (entry.isDirectory()) await collect(nested);
      else if (entry.isFile()) files.push(nested);
    }
  };
  for (const directory of ["lib", "config", "priv/repo/migrations", "sdks/typescript/src", "bench"]) await collect(resolve(root, directory));
  files.push(resolve(root, "mix.exs"), resolve(root, "mix.lock"), resolve(root, "sdks/typescript/package-lock.json"));
  const hash = createHash("sha256");
  for (const path of files.sort()) {
    const bytes = await readFile(path);
    hash.update(relative(root, path));
    hash.update("\0");
    hash.update(String(bytes.byteLength));
    hash.update("\0");
    hash.update(bytes);
  }
  return { algorithm: "sha256", digest: hash.digest("hex"), fileCount: files.length };
}

export async function verifySourceFingerprint(root, expected) {
  const actual = await sourceFingerprint(root);
  if (actual.digest !== expected.digest) throw new Error("Benchmark source changed during the suite; discard the comparison and rerun with frozen sources");
}
