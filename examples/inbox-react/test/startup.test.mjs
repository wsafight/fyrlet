import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

for (const [name, configuration, privateValue] of [
  ["provider JSON", { OIDC_PROVIDERS: '{"clientSecret":"private-provider-startup-value"' }, "private-provider-startup-value"],
  ["database URL", { HOST_STORE_DATABASE_URL: "private-database-startup-value" }, "private-database-startup-value"],
]) {
  test(`invalid ${name} fails startup without disclosing configuration`, () => {
    const child = spawnSync(process.execPath, [fileURLToPath(new URL("../server/index.mjs", import.meta.url))], {
      env: { ...process.env, OIDC_PROVIDERS: "[]", HOST_INSTANCES: "1", HOST_STORE_DATABASE_URL: "", ...configuration },
      encoding: "utf8", timeout: 10000,
    });
    assert.equal(child.error, undefined);
    assert.equal(child.status, 1);
    assert.match(child.stderr, /Host authentication startup failed/);
    assert.ok(!`${child.stdout}${child.stderr}`.includes(privateValue));
  });
}
