import { readdir, readFile } from "node:fs/promises";
import { resolve, relative } from "node:path";
import { createHash } from "node:crypto";

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
