import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { restoreSource } from "../../scripts/restore_smoke.mjs";
import { stabilityConfiguration } from "../../scripts/stability.mjs";
import { verifyArtifacts } from "../../scripts/release_check.mjs";

test("restore drills refuse production, remote hosts and unsafe database names", () => {
  assert.equal(restoreSource("postgres://localhost/fyrlet_integration").hostname, "localhost");
  for (const url of ["postgres://localhost/production", "postgres://db.example/fyrlet_integration", "https://localhost/fyrlet_integration", "postgres://localhost/fyrlet_integration;drop",
    "postgres://localhost/fyrlet_integration?host=db.example", "postgres://localhost/fyrlet_integration?options=-c%20search_path=private", "postgres://localhost/fyrlet_integration#fragment"]) assert.throws(() => restoreSource(url));
});

test("shared-host drills reject remote or redirected database URLs before connecting", () => {
  for (const databaseURL of ["postgres://db.example/fyrlet_host_test", "postgres://localhost/fyrlet_host_test?host=db.example", "postgres://localhost/fyrlet_host_test#fragment"]) {
    const child = spawnSync("bash", [fileURLToPath(new URL("../../scripts/host_store.sh", import.meta.url))], {
      env: { ...process.env, HOST_STORE_TEST_DATABASE_URL: databaseURL }, encoding: "utf8", timeout: 5000,
    });
    assert.equal(child.error, undefined);
    assert.equal(child.status, 1);
    assert.equal(child.stdout, "");
    assert.match(child.stderr, /Use an isolated local/);
  }
});

test("stability configuration distinguishes a short drill from a 24-hour run", () => {
  assert.equal(stabilityConfiguration([]).seconds, 86400);
  assert.equal(stabilityConfiguration(["--seconds", "30"]).seconds, 30);
  for (const arguments_ of [["--seconds", "86401"], ["--seconds", "NaN"], ["--clients", "51"], ["--base-port", "65535"], ["--sample-ms", "1"]]) assert.throws(() => stabilityConfiguration(arguments_));
});

test("release artifact checks reject stale fingerprints, tampering and traversal", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "fyrlet-release-check-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const bytes = Buffer.from("artifact");
  const fingerprint = { digest: "current" };
  const expectedArtifacts = ["fyrlet-source-1.2.3.tar.gz", "fyrlet-1.2.3.tar", "fyrlet-client-1.2.3.tgz", "fyrlet-react-1.2.3.tgz"];
  const artifacts = expectedArtifacts.map((filename) => ({ filename, bytes: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") }));
  for (const artifact of artifacts) await writeFile(join(directory, artifact.filename), bytes);
  const manifest = {
    version: "1.2.3", git_revision: "a".repeat(40), working_tree_clean: true,
    registry_published: false, publication: "not-performed", source_fingerprint: fingerprint, expected_artifacts: expectedArtifacts, artifacts,
  };
  const expectations = { version: "1.2.3", expectedRevision: "a".repeat(40), expectedArtifacts, requireClean: true };
  const save = () => writeFile(join(directory, "manifest.json"), JSON.stringify(manifest));
  await save();
  assert.equal(await verifyArtifacts(directory, fingerprint, expectations), true);
  assert.equal(await verifyArtifacts(directory, { digest: "stale" }, expectations), false);
  assert.equal(await verifyArtifacts(directory, fingerprint), false);
  await writeFile(join(directory, "fyrlet-client-1.2.3.tgz"), "tampered");
  assert.equal(await verifyArtifacts(directory, fingerprint, expectations), false);
  manifest.artifacts[0].filename = "../fyrlet-source-1.2.3.tar.gz"; await save();
  assert.equal(await verifyArtifacts(directory, fingerprint, expectations), false);
});
