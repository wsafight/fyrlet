import test from "node:test";
import assert from "node:assert/strict";
import { generate, schemaType } from "../../scripts/generate.mjs";

const empty = { type: "object", additionalProperties: false };
const contract = { protocol_version: 1, schema_dialect: "fyrlet-subset", operations: {}, subscriptions: {} };

test("generated output is deterministic regardless of operation, subscription and room insertion order", () => {
  const operation = { kind: "write", input: empty, output: { type: "string" } };
  const subscription = { input: empty, output: { type: "array", items: { type: "integer" } } };
  const room = { input: empty, meta: empty };
  const entries = (value, reverse) => Object.fromEntries((reverse ? ["z", "a"] : ["a", "z"]).map((name) => [name, value]));
  const build = (reverse) => generate({ ...contract, operations: entries(operation, reverse), subscriptions: entries(subscription, reverse), presence: entries(room, reverse) });
  assert.equal(build(false), build(true));
});

for (const kind of ["read", "write", "run", "ingest"]) {
  test(`generated ${kind} metadata agrees with the operation type`, () => {
    const result = generate({ ...contract, operations: { action: { kind, input: empty, output: { type: "null" } } } });
    assert.ok(result.includes(`"action": { kind: "${kind}"; input: Record<string, never>; output: null }`));
    const runtime = JSON.parse(result.slice(result.indexOf("= ") + 2, result.lastIndexOf(" as const")));
    assert.deepEqual(runtime, { action: { kind } });
  });
}

test("input defaults are optional while generated output retains required fields", () => {
  const schema = { ...empty, properties: { limit: { type: "integer", default: 20 }, enabled: { type: "boolean" }, note: { anyOf: [{ type: "string" }, { type: "null" }] } }, required: ["limit", "enabled"] };
  assert.equal(schemaType(schema), '{ "limit"?: number; "enabled": boolean; "note"?: string | null }');
  assert.equal(schemaType(schema, "output"), '{ "limit": number; "enabled": boolean; "note"?: string | null }');
});

test("nested arrays, unions and enum literals retain their schema types", () => {
  const schema = { ...empty, properties: { items: { type: "array", items: { ...empty, properties: {
    state: { enum: ["queued", "done"] }, value: { anyOf: [{ type: "integer" }, { type: "null" }] },
  }, required: ["state", "value"] } } }, required: ["items"] };
  assert.equal(schemaType(schema), '{ "items": Array<{ "state": "queued" | "done"; "value": number | null }> }');
});

test("absent Presence exports an empty typed room set and an empty metadata object", () => {
  const result = generate(contract);
  assert.match(result, /presence: \{\n\n  \}/);
  assert.match(result, /operationMetadata = \{\} as const/);
});

for (const [name, overrides] of [["protocol", { protocol_version: 2 }], ["dialect", { schema_dialect: "json-schema" }],
  ["kind", { operations: { action: { kind: "other", input: empty, output: empty } } }]]) {
  test(`unsupported ${name} fails generation`, () => assert.throws(() => generate({ ...contract, ...overrides }), /Unsupported/));
}

for (const schema of [{ type: "number" }, { type: "object", additionalProperties: true }, { type: "object" }]) {
  test(`unsupported schema ${JSON.stringify(schema)} fails rather than weakening generated types`, () => {
    assert.throws(() => schemaType(schema), /Unsupported schema|closed objects/);
  });
}
