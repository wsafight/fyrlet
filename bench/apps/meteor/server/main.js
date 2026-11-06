import { Meteor } from "meteor/meteor";
import { Mongo } from "meteor/mongo";
import { WebApp } from "meteor/webapp";
import { check, Match } from "meteor/check";
import { randomBytes, randomUUID, createHash, timingSafeEqual } from "node:crypto";

const Items = new Mongo.Collection("bench_items");
const Sessions = new Mongo.Collection("bench_sessions");
const Idempotency = new Mongo.Collection("bench_idempotency");
const actors = new Map();
let ready = false;
const hash = (value) => createHash("sha256").update(value).digest("hex");
const serialize = ({ _id, text, content_type, archived, version, inserted_at, updated_at }) => ({
  id: _id, text, content_type, archived, version, inserted_at: inserted_at.toISOString(), updated_at: updated_at.toISOString(),
});
const admin = (secret) => {
  const expected = process.env.BENCH_SECRET;
  if (typeof secret !== "string" || !/^[a-f\d]{64}$/.test(secret) || !expected || secret.length !== expected.length ||
      !timingSafeEqual(Buffer.from(secret), Buffer.from(expected))) throw new Meteor.Error("FORBIDDEN", "Invalid benchmark secret");
};
const authenticated = async (context) => {
  const tokenHash = actors.get(context.connection.id);
  const session = tokenHash && await Sessions.findOneAsync({ _id: tokenHash, expires_at: { $gt: new Date() } });
  if (!session || context.userId !== session.subject_id) throw new Meteor.Error("UNAUTHENTICATED", "Session expired");
  return session;
};

Meteor.onConnection((connection) => connection.onClose(() => actors.delete(connection.id)));

Meteor.methods({
  async "bench.seed"(secret, runId, users, rows, payloadBytes, devices, sessions) {
    admin(secret);
    check(runId, Match.Where((value) => typeof value === "string" && /^bench-[\d]+-[a-f\d-]{8}$/.test(value)));
    for (const [value, maximum] of [[users, 5000], [rows, 100], [payloadBytes, 16384], [devices, 100]]) {
      check(value, Match.Where((number) => Number.isSafeInteger(number) && number >= 1 && number <= maximum));
    }
    check(sessions, Match.OneOf("shared", "device"));
    const fixtures = [];
    for (let index = 0; index < users; index++) {
      const subject = `${runId}:${index}`;
      const token = `mbt_${randomBytes(32).toString("hex")}`;
      await Sessions.insertAsync({ _id: hash(token), project_id: runId, subject_id: subject, expires_at: new Date(Date.now() + 900000) });
      const records = Array.from({ length: rows }, (_, row) => ({
        _id: randomUUID(), project_id: runId, subject_id: subject,
        text: `seed:${row + 1}:`.padEnd(payloadBytes, "x"), content_type: "text", archived: false, version: 1,
        inserted_at: new Date(Date.now() + row), updated_at: new Date(Date.now() + row),
      }));
      await Items.rawCollection().insertMany(records);
      const observerTokens = [];
      if (sessions === "device") for (let device = 0; device < devices; device++) {
        const deviceToken = `mbt_${randomBytes(32).toString("hex")}`;
        await Sessions.insertAsync({ _id: hash(deviceToken), project_id: runId, subject_id: subject, expires_at: new Date(Date.now() + 900000) });
        observerTokens.push(deviceToken);
      }
      fixtures.push({ token, observer_tokens: observerTokens, ids: records.map((item) => item._id) });
    }
    const build = await Items.rawCollection().client.db("admin").command({ buildInfo: 1 });
    return { target: "meteor", run_id: runId, project_id: runId, rows, payload_bytes: payloadBytes, session_model: sessions, users: fixtures, mongo_version: build.version,
      runtime_node: process.version,
      observer_config: { oplogConfigured: Boolean(process.env.MONGO_OPLOG_URL), changeStreamsMode: process.env.METEOR_CHANGE_STREAMS_MODE ?? "default" } };
  },
  async "bench.cleanup"(secret, runId) {
    admin(secret);
    check(runId, String);
    if (!/^bench-[\d]+-[a-f\d-]{8}$/.test(runId)) throw new Meteor.Error("VALIDATION_FAILED", "Invalid run id");
    for (const collection of [Items, Sessions, Idempotency]) await collection.removeAsync({ project_id: runId });
    return true;
  },
  async "bench.login"(token) {
    check(token, String);
    const tokenHash = hash(token);
    const session = await Sessions.findOneAsync({ _id: tokenHash, expires_at: { $gt: new Date() } });
    if (!session) throw new Meteor.Error("UNAUTHENTICATED", "Invalid benchmark session");
    actors.set(this.connection.id, tokenHash);
    await this.setUserId(session.subject_id);
    return true;
  },
  async "inbox.update"(input, key) {
    check(input, { id: String, text: String, expected_version: Match.Integer });
    check(key, String);
    if (key.length < 1 || key.length > 200 || input.text.length < 1 || input.text.length > 16384 || input.expected_version < 1) {
      throw new Meteor.Error("VALIDATION_FAILED", "Invalid mutation");
    }
    const actor = await authenticated(this);
    const identifier = hash(JSON.stringify([actor.project_id, actor.subject_id, "inbox.update", key]));
    const inputHash = hash(JSON.stringify([input.id, input.text, input.expected_version]));
    const items = Items.rawCollection();
    const idempotency = Idempotency.rawCollection();
    const transaction = items.client.startSession();
    try {
      return await transaction.withTransaction(async () => {
        const previous = await idempotency.findOne({ _id: identifier }, { session: transaction });
        if (previous && previous.expires_at > new Date()) {
          if (previous.input_hash !== inputHash) throw new Meteor.Error("CONFLICT", "Idempotency key input changed");
          return previous.result;
        }
        if (previous) await idempotency.deleteOne({ _id: identifier }, { session: transaction });
        const changed = await items.findOneAndUpdate({ _id: input.id, project_id: actor.project_id, subject_id: actor.subject_id, version: input.expected_version },
          { $set: { text: input.text, updated_at: new Date() }, $inc: { version: 1 } },
          { session: transaction, returnDocument: "after", includeResultMetadata: false });
        if (!changed) throw new Meteor.Error("CONFLICT", "Record missing or changed");
        const result = serialize(changed);
        await idempotency.insertOne({ _id: identifier, project_id: actor.project_id, input_hash: inputHash, result, expires_at: new Date(Date.now() + 86400000) }, { session: transaction });
        return result;
      }, { readConcern: { level: "snapshot" }, writeConcern: { w: "majority" } });
    } finally { await transaction.endSession(); }
  },
});

Meteor.publish("inbox.recent", async function (rows) {
  check(rows, Match.Where((value) => Number.isSafeInteger(value) && value >= 1 && value <= 100));
  const actor = await authenticated(this);
  const timer = setTimeout(() => this.stop(), actor.expires_at.getTime() - Date.now());
  this.onStop(() => clearTimeout(timer));
  return Items.find({ project_id: actor.project_id, subject_id: actor.subject_id, archived: false }, {
    fields: { project_id: 0, subject_id: 0 }, sort: { inserted_at: -1, _id: -1 }, limit: rows,
  });
});

WebApp.handlers.use("/__bench/health", (_request, response) => {
  response.writeHead(ready ? 200 : 503, { "content-type": "application/json" });
  const multiplexers = Object.values(Items._driver?.mongo?._observeMultiplexers ?? {}).filter((entry) =>
    entry._observeDriver?._cursorDescription?.collectionName === "bench_items");
  const activeDrivers = {};
  for (const entry of multiplexers) {
    const name = entry._observeDriver?.constructor?.name || "unknown";
    activeDrivers[name] = (activeDrivers[name] ?? 0) + 1;
  }
  response.end(JSON.stringify({ ready, applicationPid: process.pid, loggedInConnections: actors.size, observedQueries: multiplexers.length, activeDrivers,
    driverIntrospection: "Meteor 3.5.4 private _observeMultiplexers/_observeDriver; benchmark diagnostics only" }));
});

Meteor.startup(async () => {
  if (!process.env.BENCH_SECRET) throw new Error("BENCH_SECRET is required; this app is for isolated benchmarks");
  await Items.rawCollection().createIndex({ project_id: 1, subject_id: 1, archived: 1, inserted_at: -1, _id: -1 });
  await Sessions.rawCollection().createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 });
  await Idempotency.rawCollection().createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 });
  ready = true;
});
