import test from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { createMemoryStore, storeConfiguration, createPostgresStore } from "../server/store.mjs";

test("multi-instance configuration requires a database and a valid encryption key", async () => {
  const key = randomBytes(32).toString("base64url");
  assert.equal(storeConfiguration({}).postgres, false);
  assert.equal(storeConfiguration({ HOST_INSTANCES: "2", HOST_STORE_DATABASE_URL: "postgres://localhost/host", HOST_STORE_KEY: key }).postgres, true);
  for (const environment of [{ HOST_INSTANCES: "2" }, { HOST_INSTANCES: "0" }, { HOST_INSTANCES: "1.5" },
    { HOST_STORE_DATABASE_URL: "https://database.example", HOST_STORE_KEY: key }, { HOST_STORE_DATABASE_URL: "postgres://localhost/host", HOST_STORE_KEY: "secret" }]) {
    assert.throws(() => storeConfiguration(environment));
  }
  await assert.rejects(createPostgresStore({ databaseURL: "postgres://localhost/host", key, maxEntries: 0 }), /limits/);
});

test("pending login state is one-shot, expires and has a hard capacity", async () => {
  const store = createMemoryStore();
  for (let index = 0; index < 1000; index++) await store.putPending(String(index), { expiresAt: 100 }, 0);
  await assert.rejects(store.putPending("extra", { expiresAt: 100 }, 0), { status: 429 });
  assert.ok(await store.takePending("0", 1));
  assert.equal(await store.takePending("0", 1), undefined);
  assert.equal(await store.takePending("1", 100), undefined);
  await store.putPending("fresh", { expiresAt: 200 }, 100);
  assert.ok(await store.takePending("fresh", 101));
  await store.close();
});

test("host mutations serialize while logout can close an in-flight host immediately", async () => {
  const store = createMemoryStore();
  await store.putHost("host", { closed: false, expiresAt: 100 });
  const started = Promise.withResolvers();
  const release = Promise.withResolvers();
  const events = [];
  const first = store.withHost("host", async (host) => { events.push("first"); started.resolve(); await release.promise; assert.equal(host.closed, true); });
  await started.promise;
  const second = store.withHost("host", async () => { events.push("second"); });
  await store.markClosed("host");
  assert.equal(await store.isActive("host", 0), false);
  release.resolve(); await Promise.all([first, second]);
  assert.deepEqual(events, ["first", "second"]);
  assert.deepEqual(await store.expired(0, 8), ["host"]);
  await store.deleteHost("host");
  assert.equal(await store.getHost("host"), undefined);
});
