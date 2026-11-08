import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { AsyncLocalStorage } from "node:async_hooks";

const digest = (value) => createHash("sha256").update(value).digest("hex");
const unavailable = () => Object.assign(new Error("登录存储暂时不可用，请稍后重试"), { status: 503 });
const full = () => Object.assign(new Error("登录容量已满，请稍后重试"), { status: 429 });
const identify = (host, identifier) => host && Object.defineProperty(host, "identifier", { value: identifier, configurable: true });
export const hostStoreScope = (namespace, context) => digest(JSON.stringify([namespace, context]));

export function storeConfiguration(environment) {
  const instances = Number(environment.HOST_INSTANCES ?? 1);
  if (!Number.isSafeInteger(instances) || instances < 1 || instances > 100) throw new TypeError("Invalid HOST_INSTANCES");
  const postgres = Boolean(environment.HOST_STORE_DATABASE_URL);
  if (instances > 1 && !postgres) throw new TypeError("Multiple hosts require PostgreSQL session storage");
  if (postgres) {
    const url = new URL(environment.HOST_STORE_DATABASE_URL);
    if (!["postgres:", "postgresql:"].includes(url.protocol)) throw new TypeError("Invalid host store database URL");
    const key = environment.HOST_STORE_KEY ?? "";
    if (!/^[A-Za-z0-9_-]{43}$/.test(key) || Buffer.from(key, "base64url").length !== 32) throw new TypeError("HOST_STORE_KEY must be a 32-byte base64url key");
  }
  return { instances, postgres };
}

export function createMemoryStore() {
  const pending = new Map();
  const hosts = new Map();
  const locks = new Map();
  return {
    shared: false,
    async bind() {},
    async putPending(identifier, value, now) {
      for (const [key, attempt] of pending) if (attempt.expiresAt <= now) pending.delete(key);
      if (pending.size >= 1000) throw full();
      pending.set(identifier, value);
    },
    async takePending(identifier, now) {
      const value = pending.get(identifier);
      pending.delete(identifier);
      return value?.expiresAt > now ? value : undefined;
    },
    async putHost(identifier, value) {
      if (hosts.size >= 1000) throw full();
      hosts.set(identifier, identify(value, identifier));
    },
    async getHost(identifier) { return hosts.get(identifier); },
    async markClosed(identifier) { const host = hosts.get(identifier); if (host) host.closed = true; },
    async isActive(identifier, now) { const host = hosts.get(identifier); return Boolean(host && !host.closed && host.expiresAt > now); },
    async deleteHost(identifier) { hosts.delete(identifier); },
    async expired(now, limit) { return [...hosts].filter(([_key, host]) => host.closed || host.expiresAt <= now).slice(0, limit).map(([key]) => key); },
    async withHost(identifier, callback) {
      const previous = locks.get(identifier) ?? Promise.resolve();
      const operation = previous.catch(() => {}).then(() => callback(hosts.get(identifier)));
      locks.set(identifier, operation);
      try { return await operation; } finally { if (locks.get(identifier) === operation) locks.delete(identifier); }
    },
    async close() { pending.clear(); hosts.clear(); },
  };
}

export async function createPostgresStore({ databaseURL, key, namespace = "inbox", maxEntries = 1000, lockTimeoutMs = 6000 }) {
  storeConfiguration({ HOST_STORE_DATABASE_URL: databaseURL, HOST_STORE_KEY: key });
  if (!Number.isSafeInteger(maxEntries) || maxEntries < 1 || maxEntries > 1000 ||
      !Number.isSafeInteger(lockTimeoutMs) || lockTimeoutMs < 100 || lockTimeoutMs > 30000 ||
      typeof namespace !== "string" || namespace.length < 1 || namespace.length > 128) throw new TypeError("Invalid host store limits");
  const { Pool } = await import("pg");
  const pool = new Pool({ connectionString: databaseURL, max: 8, connectionTimeoutMillis: 2000, idleTimeoutMillis: 10000, query_timeout: 5000 });
  pool.on("error", () => {});
  const encryptionKey = Buffer.from(key, "base64url");
  let scope;
  let waiting = 0;
  let leases = 0;
  const transactions = new AsyncLocalStorage();
  let stopped = false;
  let closing;
  const identifierFor = (identifier) => typeof identifier === "object" ? identifier.hash : digest(identifier);
  const encode = (kind, identifier, value) => {
    const bytes = Buffer.from(JSON.stringify(value));
    if (bytes.length > 65536) throw unavailable();
    const nonce = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", encryptionKey, nonce);
    cipher.setAAD(Buffer.from(`${scope}:${kind}:${identifierFor(identifier)}`));
    return Buffer.concat([nonce, cipher.update(bytes), cipher.final(), cipher.getAuthTag()]).toString("base64");
  };
  const decode = (kind, identifier, row) => {
    if (!row) return undefined;
    const bytes = Buffer.from(row.payload, "base64");
    const decipher = createDecipheriv("aes-256-gcm", encryptionKey, bytes.subarray(0, 12));
    decipher.setAAD(Buffer.from(`${scope}:${kind}:${identifierFor(identifier)}`));
    decipher.setAuthTag(bytes.subarray(-16));
    const value = JSON.parse(Buffer.concat([decipher.update(bytes.subarray(12, -16)), decipher.final()]).toString());
    return kind === "host" ? identify({ ...value, closed: row.closed, expiresAt: Number(row.expires_at) }, identifier) : value;
  };
  const validIdentifier = (identifier) => typeof identifier === "string" && identifier.length > 0 && identifier.length <= 256;
  const query = async (...arguments_) => {
    if (stopped || !scope) throw unavailable();
    return (transactions.getStore() ?? pool).query(...arguments_);
  };
  async function put(kind, identifier, value, now) {
    if (stopped || !scope) throw unavailable();
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      await client.query("SET LOCAL lock_timeout = '2s'");
      await client.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [`${scope}:${kind}:capacity`]);
      if (kind === "pending") await client.query("DELETE FROM fyrlet_host_state_v1 WHERE namespace=$1 AND kind='pending' AND expires_at <= $2", [scope, now]);
      const count = await client.query("SELECT count(*) FROM fyrlet_host_state_v1 WHERE namespace=$1 AND kind=$2", [scope, kind]);
      if (Number(count.rows[0].count) >= maxEntries) throw full();
      await client.query("INSERT INTO fyrlet_host_state_v1(namespace,kind,identifier,payload,expires_at) VALUES($1,$2,$3,$4,$5)", [scope, kind, digest(identifier), encode(kind, identifier, value), value.expiresAt]);
      await client.query("COMMIT");
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally { client.release(); }
  }
  return {
    shared: true,
    async migrate() {
      const client = await pool.connect();
      try {
        await client.query("BEGIN");
        await client.query("SET LOCAL lock_timeout = '5s'");
        await client.query("SELECT pg_advisory_xact_lock(hashtextextended('fyrlet_host_state_v1:migrate', 0))");
        await client.query("CREATE TABLE IF NOT EXISTS fyrlet_host_state_v1 (namespace text NOT NULL, kind text NOT NULL CHECK(kind IN ('pending','host')), identifier text NOT NULL, payload text NOT NULL, expires_at bigint NOT NULL, closed boolean NOT NULL DEFAULT false, PRIMARY KEY(namespace,kind,identifier))");
        await client.query("CREATE INDEX IF NOT EXISTS fyrlet_host_state_v1_expiry ON fyrlet_host_state_v1(namespace,kind,expires_at)");
        await client.query("COMMIT");
      } catch (error) { await client.query("ROLLBACK").catch(() => {}); throw error; }
      finally { client.release(); }
    },
    async bind(context) {
      if (scope) throw new TypeError("A store can only be bound once");
      scope = hostStoreScope(namespace, context);
      await query("SELECT namespace FROM fyrlet_host_state_v1 LIMIT 0");
    },
    async putPending(identifier, value, now) { await put("pending", identifier, value, now); },
    async takePending(identifier, now) {
      if (!validIdentifier(identifier)) return undefined;
      const result = await query("DELETE FROM fyrlet_host_state_v1 WHERE namespace=$1 AND kind='pending' AND identifier=$2 RETURNING *", [scope, digest(identifier)]);
      return result.rows[0]?.expires_at > now ? decode("pending", identifier, result.rows[0]) : undefined;
    },
    async putHost(identifier, value) { await put("host", identifier, value); },
    async getHost(identifier) {
      if (!validIdentifier(identifier)) return undefined;
      const result = await query("SELECT * FROM fyrlet_host_state_v1 WHERE namespace=$1 AND kind='host' AND identifier=$2", [scope, digest(identifier)]);
      return decode("host", identifier, result.rows[0]);
    },
    async markClosed(identifier) {
      if (validIdentifier(identifier)) await query("UPDATE fyrlet_host_state_v1 SET closed=true WHERE namespace=$1 AND kind='host' AND identifier=$2", [scope, digest(identifier)]);
    },
    async isActive(identifier, now) {
      const result = await query("SELECT 1 FROM fyrlet_host_state_v1 WHERE namespace=$1 AND kind='host' AND identifier=$2 AND NOT closed AND expires_at > $3", [scope, identifierFor(identifier), now]);
      return result.rowCount === 1;
    },
    async deleteHost(identifier) { await query("DELETE FROM fyrlet_host_state_v1 WHERE namespace=$1 AND kind='host' AND identifier=$2", [scope, identifierFor(identifier)]); },
    async expired(now, limit) {
      const result = await query("SELECT identifier FROM fyrlet_host_state_v1 WHERE namespace=$1 AND kind='host' AND (closed OR expires_at <= $2) ORDER BY expires_at LIMIT $3", [scope, now, limit]);
      return result.rows.map((row) => ({ hash: row.identifier }));
    },
    async withHost(identifier, callback) {
      if (stopped || !scope || waiting >= 64) throw unavailable();
      const identifierHash = identifierFor(identifier);
      const lock = `${scope}:host:${identifierHash}`;
      const deadline = Date.now() + lockTimeoutMs;
      waiting++;
      let client;
      let destroy;
      let reserved = false;
      try {
        do {
          if (leases >= 7) { await delay(20); continue; }
          leases++; reserved = true;
          client = await pool.connect();
          const acquired = await client.query("SELECT pg_try_advisory_lock(hashtextextended($1, 0)) AS acquired", [lock]);
          if (acquired.rows[0].acquired) break;
          client.release(); client = undefined;
          leases--; reserved = false;
          await delay(20);
        } while (Date.now() < deadline && !stopped);
        if (!client) throw unavailable();
        const result = await client.query("SELECT * FROM fyrlet_host_state_v1 WHERE namespace=$1 AND kind='host' AND identifier=$2", [scope, identifierHash]);
        if (!result.rowCount) return await transactions.run(client, () => callback(undefined));
        const host = decode("host", identifier, result.rows[0]);
        try { return await transactions.run(client, () => callback(host)); }
        finally {
          await client.query("UPDATE fyrlet_host_state_v1 SET payload=$3,closed=closed OR $4 WHERE namespace=$1 AND kind='host' AND identifier=$2", [scope, identifierHash, encode("host", identifier, host), host.closed]);
        }
      } catch (error) { destroy = error; throw error; }
      finally {
        waiting--;
        if (client) {
          try { await client.query("SELECT pg_advisory_unlock(hashtextextended($1, 0))", [lock]); }
          catch (error) { destroy = error; }
          client.release(destroy);
        }
        if (reserved) leases--;
      }
    },
    async close() {
      if (!closing) { stopped = true; closing = pool.end().finally(() => encryptionKey.fill(0)); }
      await closing;
    },
  };
}

export async function storeFromEnvironment(environment) {
  const config = storeConfiguration(environment);
  return config.postgres ? createPostgresStore({ databaseURL: environment.HOST_STORE_DATABASE_URL, key: environment.HOST_STORE_KEY, namespace: environment.HOST_STORE_NAMESPACE ?? "inbox" }) : createMemoryStore();
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let store;
  try {
    if (process.argv[2] !== "--migrate" || !storeConfiguration(process.env).postgres) throw new TypeError("Configure PostgreSQL host storage and pass --migrate");
    store = await storeFromEnvironment(process.env);
    await store.migrate();
    console.log("Host session store migration completed");
  } catch { console.error("Host session store migration failed; verify configuration, connectivity and schema permissions"); process.exitCode = 1; }
  finally { await store?.close(); }
}
