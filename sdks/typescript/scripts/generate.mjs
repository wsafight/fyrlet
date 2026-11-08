import { readFile, mkdir, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

export function schemaType(schema, mode = "input") {
  if (schema.anyOf) return schema.anyOf.map((option) => schemaType(option, mode)).join(" | ");
  if (schema.enum) return schema.enum.map((value) => JSON.stringify(value)).join(" | ");
  switch (schema.type) {
    case "string": return "string";
    case "integer": return "number";
    case "boolean": return "boolean";
    case "null": return "null";
    case "array": return `Array<${schemaType(schema.items, mode)}>`;
    case "object": {
      if (schema.additionalProperties !== false) throw new Error("Generated contracts require closed objects");
      const fields = Object.entries(schema.properties ?? {}).map(([name, property]) => {
        const required = schema.required?.includes(name) && !(mode === "input" && "default" in property);
        return `${JSON.stringify(name)}${required ? "" : "?"}: ${schemaType(property, mode)}`;
      });
      return fields.length ? `{ ${fields.join("; ")} }` : "Record<string, never>";
    }
    default: throw new Error(`Unsupported schema type: ${schema.type}`);
  }
}

export function generate(contract) {
  if (contract.protocol_version !== 1 || contract.schema_dialect !== "fyrlet-subset") throw new Error("Unsupported contract protocol or dialect");
  const sections = ["operations", "subscriptions"].map((kind) => {
    const entries = Object.entries(contract[kind]).sort(([left], [right]) => left.localeCompare(right)).map(([name, specification]) =>
      `    ${JSON.stringify(name)}: { ${kind === "operations" ? `kind: ${JSON.stringify(specification.kind)}; ` : ""}input: ${schemaType(specification.input)}; output: ${schemaType(specification.output, "output")} };`,
    );
    return `  ${kind}: {\n${entries.join("\n")}\n  };`;
  });
  const rooms = Object.entries(contract.presence ?? {}).sort(([left], [right]) => left.localeCompare(right)).map(([name, specification]) =>
    `    ${JSON.stringify(name)}: { input: ${schemaType(specification.input)}; meta: ${schemaType(specification.meta ?? { type: "object", additionalProperties: false })} };`,
  );
  sections.push(`  presence: {\n${rooms.join("\n")}\n  };`);
  const metadata = Object.fromEntries(Object.entries(contract.operations).sort(([left], [right]) => left.localeCompare(right)).map(([name, specification]) => {
    if (!["read", "write", "run", "ingest"].includes(specification.kind)) throw new Error(`Unsupported operation kind: ${specification.kind}`);
    return [name, { kind: specification.kind }];
  }));
  return `export interface AppContract {\n${sections.join("\n")}\n}\n\nexport const operationMetadata = ${JSON.stringify(metadata, null, 2)} as const;\n`;
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  const [source, destination] = process.argv.slice(2);
  if (!source || !destination) throw new Error("Usage: node generate.mjs CONTRACT_JSON OUTPUT_TS");
  const contract = JSON.parse(await readFile(source, "utf8"));
  await mkdir(dirname(destination), { recursive: true });
  await writeFile(destination, generate(contract));
}
