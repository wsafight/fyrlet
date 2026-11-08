import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { generate } from "../sdks/typescript/scripts/generate.mjs";

const exported = process.argv[2];
if (!exported) throw new Error("Usage: node scripts/check_contract.mjs EXPORTED_CONTRACT_JSON");
const [actual, committed, types] = await Promise.all([
  readFile(exported, "utf8"),
  readFile(new URL("../priv/contract.json", import.meta.url), "utf8"),
  readFile(new URL("../sdks/typescript/src/generated/app.ts", import.meta.url), "utf8"),
]);
assert.deepEqual(JSON.parse(actual), JSON.parse(committed), "Exported contract differs from priv/contract.json");
assert.equal(generate(JSON.parse(actual)), types, "Generated SDK types differ from the exported contract");
console.log("Exported contract and generated SDK types match");
