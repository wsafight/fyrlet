// usage: node bench/merge.mjs OUT_DIR SHARD_DIR... — combine the results.json files of one sharded run.
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import { mergeShards } from "./lib/merge.mjs";
import { markdown } from "./report.mjs";

const [out, ...inputs] = process.argv.slice(2);
if (!out || inputs.length < 2) throw new Error("usage: node bench/merge.mjs OUT_DIR SHARD_DIR SHARD_DIR...");
const documents = await Promise.all(inputs.map(async (dir) => JSON.parse(await readFile(resolve(dir, "results.json"), "utf8"))));
const counts = new Set(documents.map((document) => document.results.length));
if (counts.size !== 1) throw new Error("Shards contain a different number of results");
const merged = { ...documents[0], results: documents[0].results.map((_result, index) => mergeShards(documents.map((document) => document.results[index]))) };
await mkdir(resolve(out), { recursive: true });
await writeFile(resolve(out, "results.json"), JSON.stringify(merged, null, 2) + "\n");
await writeFile(resolve(out, "report.md"), markdown([merged]));
console.log(`Merged ${documents.length} shards: ${resolve(out, "results.json")}`);
