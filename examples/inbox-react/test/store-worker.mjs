import { createPostgresStore } from "../server/store.mjs";

if (!new URL(process.env.HOST_STORE_TEST_DATABASE_URL).pathname.endsWith("_host_test")) throw new Error("Use an isolated host test database");
const store = await createPostgresStore({ databaseURL: process.env.HOST_STORE_TEST_DATABASE_URL, key: process.env.HOST_STORE_KEY, namespace: process.env.HOST_STORE_NAMESPACE });
await store.bind(JSON.parse(process.env.HOST_STORE_TEST_SCOPE));
await store.withHost(process.env.HOST_STORE_TEST_IDENTIFIER, async () => {
  process.send({ locked: true });
  await new Promise(() => {});
});
