type RecordValue = Record<string, unknown> & { id: string };
const indexes = new WeakMap<object, Map<string, number>>();

const object = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const record = (value: unknown): value is RecordValue => object(value) && typeof value.id === "string";

export function immutable(value: unknown): unknown {
  if (value !== null && typeof value === "object" && !Object.isFrozen(value)) {
    for (const entry of Object.values(value)) immutable(entry);
    Object.freeze(value);
  }
  return value;
}

function viewIndex(data: unknown[]): { positions: Map<string, number>; reusable: boolean } {
  const cached = indexes.get(data);
  if (cached) return { positions: cached, reusable: true };
  const positions = new Map<string, number>();
  let reusable = Object.isFrozen(data);
  for (let position = 0; position < data.length; position += 1) {
    const entry = data[position];
    if (!record(entry) || positions.has(entry.id)) throw new TypeError("Invalid subscription delta");
    positions.set(entry.id, position);
    reusable = reusable && Object.isFrozen(entry) && Object.getOwnPropertyDescriptor(entry, "id")?.value === entry.id;
  }
  if (reusable) indexes.set(data, positions);
  return { positions, reusable };
}

function parseChange(change: unknown): [string, Record<string, unknown>, string[]] {
  if (!Array.isArray(change) || (change.length !== 2 && change.length !== 3) ||
      typeof change[0] !== "string" || !object(change[1]) || Object.hasOwn(change[1], "id")) {
    throw new TypeError("Invalid subscription delta");
  }
  const [identifier, fields] = change;
  const cleared: unknown = change.length === 3 ? change[2] : [];
  if (!Array.isArray(cleared) || !cleared.every((key) => typeof key === "string" && key !== "id" && !Object.hasOwn(fields, key)) ||
      new Set(cleared).size !== cleared.length) throw new TypeError("Invalid subscription delta");
  return [identifier, fields, cleared as string[]];
}

function replaceRecord(previous: RecordValue, fields: Record<string, unknown>, cleared: string[]): RecordValue {
  const updated = { ...previous, ...fields };
  for (const key of cleared) delete updated[key];
  return immutable(updated) as RecordValue;
}

export function applyDelta(data: unknown, patch: unknown): unknown {
  const invalid = (): never => { throw new TypeError("Invalid subscription delta"); };
  if (!Array.isArray(data) || data.length > 100 || !object(patch) ||
      Object.keys(patch).some((key) => !["a", "c", "r", "o"].includes(key))) return invalid();
  const indexed = viewIndex(data);
  const array = (key: string): unknown[] => {
    const value = Object.hasOwn(patch, key) ? patch[key] : [];
    if (!Array.isArray(value) || value.length > 100) return invalid();
    return value;
  };
  const touched = new Set<string>();
  const touch = (identifier: string): void => {
    if (touched.has(identifier)) return invalid();
    touched.add(identifier);
  };

  if (!Object.hasOwn(patch, "a") && !Object.hasOwn(patch, "r") && !Object.hasOwn(patch, "o")) {
    const updated = (data as RecordValue[]).slice();
    for (const change of array("c")) {
      const [identifier, fields, cleared] = parseChange(change);
      const position = indexed.positions.get(identifier);
      if (position === undefined) return invalid();
      touch(identifier);
      updated[position] = replaceRecord(updated[position]!, fields, cleared);
    }
    Object.freeze(updated);
    if (indexed.reusable) indexes.set(updated, indexed.positions);
    return updated;
  }

  const records = new Map<string, RecordValue>((data as RecordValue[]).map((entry) => [entry.id, entry]));
  for (const identifier of array("r")) {
    if (typeof identifier !== "string" || !records.has(identifier)) return invalid();
    touch(identifier);
    records.delete(identifier);
  }
  for (const added of array("a")) {
    if (!record(added) || records.has(added.id)) return invalid();
    touch(added.id);
    records.set(added.id, immutable(added) as RecordValue);
  }
  for (const change of array("c")) {
    const [identifier, fields, cleared] = parseChange(change);
    const previous = records.get(identifier);
    if (!previous) return invalid();
    touch(identifier);
    records.set(identifier, replaceRecord(previous, fields, cleared));
  }
  const order = Object.hasOwn(patch, "o") ? array("o") : data.map((entry) => entry.id);
  if (records.size > 100 || order.length !== records.size || new Set(order).size !== order.length ||
      !order.every((identifier) => typeof identifier === "string" && records.has(identifier))) return invalid();
  return Object.freeze(order.map((identifier) => records.get(identifier as string)!));
}
