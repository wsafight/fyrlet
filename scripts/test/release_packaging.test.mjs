import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile, readFile, symlink } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { archiveEntriesSafe, conventionalArtifacts, hostedCiRunPasses, releaseMetadata, releaseSourceMatches, resolveArtifactInventory, sourceArchiveFiles, validateReleasePolicy, verifyArtifacts } from "../release_check.mjs";
import { acceptanceFingerprint } from "../acceptance.mjs";

const root = fileURLToPath(new URL("../../", import.meta.url));

test("artifact names derive from Mix and formal SDK versions", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "fyrlet-release-metadata-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const version = "2.3.4-rc.1";
  await writeFile(join(directory, "mix.exs"), `defmodule Example do\n  def project, do: [app: :fyrlet, version: "${version}"]\nend\n`);
  for (const [path, name] of [["sdks/typescript", "@fyrlet/client"], ["sdks/react", "@fyrlet/react"]]) {
    await mkdir(join(directory, path), { recursive: true });
    await writeFile(join(directory, path, "package.json"), JSON.stringify({ name, version }));
  }
  const metadata = await releaseMetadata(directory);
  assert.deepEqual(conventionalArtifacts(metadata).inventory, [
    "fyrlet-source-2.3.4-rc.1.tar.gz",
    "fyrlet-2.3.4-rc.1.tar",
    "fyrlet-client-2.3.4-rc.1.tgz",
    "fyrlet-react-2.3.4-rc.1.tgz",
  ]);
});

test("repository license, formal package metadata and policy agree", async () => {
  const metadata = await releaseMetadata(root);
  const policy = JSON.parse(await readFile(join(root, "deploy/release-policy.json"), "utf8"));
  assert.equal(validateReleasePolicy(policy, metadata, await readFile(join(root, "LICENSE"), "utf8")), true);
  assert.deepEqual(resolveArtifactInventory(metadata, policy), conventionalArtifacts(metadata).inventory);
  assert.equal(policy.publication.performed, false);
});

test("strict artifact verification binds revision, clean state and exact inventory", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "fyrlet-release-artifacts-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const expectedArtifacts = ["fyrlet-source-1.2.3.tar.gz", "fyrlet-1.2.3.tar", "fyrlet-client-1.2.3.tgz", "fyrlet-react-1.2.3.tgz"];
  const artifacts = expectedArtifacts.map((filename) => {
    const body = Buffer.from(filename);
    return { filename, bytes: body.length, sha256: createHash("sha256").update(body).digest("hex") };
  });
  for (const artifact of artifacts) await writeFile(join(directory, artifact.filename), artifact.filename);
  const fingerprint = { digest: "current" };
  const manifest = {
    version: "1.2.3",
    git_revision: "a".repeat(40),
    working_tree_clean: true,
    registry_published: false,
    publication: "not-performed",
    source_fingerprint: fingerprint,
    expected_artifacts: expectedArtifacts,
    artifacts,
  };
  const save = () => writeFile(join(directory, "manifest.json"), JSON.stringify(manifest));
  const expectations = { version: "1.2.3", expectedRevision: "a".repeat(40), expectedArtifacts, requireClean: true };
  await save();
  assert.equal(await verifyArtifacts(directory, fingerprint, expectations), true);
  assert.equal(await verifyArtifacts(directory, fingerprint, { ...expectations, expectedRevision: "b".repeat(40) }), false);
  assert.equal(await verifyArtifacts(directory, { digest: "stale" }, expectations), false);
  manifest.working_tree_clean = false;
  await save();
  assert.equal(await verifyArtifacts(directory, fingerprint, expectations), false);
  manifest.working_tree_clean = true;
  await save();
  await writeFile(join(directory, "unexpected.tgz"), "unexpected");
  assert.equal(await verifyArtifacts(directory, fingerprint, expectations), false);
  await rm(join(directory, "unexpected.tgz"));
  await rm(join(directory, expectedArtifacts[1]));
  assert.equal(await verifyArtifacts(directory, fingerprint, expectations), false);
});

test("release source stability rejects edits and a different revision even with identical contents", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "fyrlet-release-source-stability-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const git = (...args) => execFileSync("git", args, { cwd: directory, stdio: "ignore" });
  git("init", "--quiet");
  git("config", "user.name", "Release Test");
  git("config", "user.email", "release@example.invalid");
  await writeFile(join(directory, "source.txt"), "original\n");
  git("add", "--", "source.txt");
  git("commit", "--quiet", "-m", "initial");
  const revision = execFileSync("git", ["rev-parse", "HEAD"], { cwd: directory, encoding: "utf8" }).trim();
  const fingerprint = await acceptanceFingerprint(directory);
  assert.equal(await releaseSourceMatches(directory, fingerprint, revision), true);

  await writeFile(join(directory, "source.txt"), "changed\n");
  assert.equal(await releaseSourceMatches(directory, fingerprint, revision), false);
  git("restore", "--", "source.txt");
  assert.equal(await releaseSourceMatches(directory, fingerprint, revision), true);

  git("commit", "--quiet", "--allow-empty", "-m", "same tree, new revision");
  assert.equal((await acceptanceFingerprint(directory)).digest, fingerprint.digest);
  assert.equal(await releaseSourceMatches(directory, fingerprint, revision), false);
  assert.equal(await releaseSourceMatches(directory, fingerprint, "not-a-revision"), false);
});

test("source archive inventory rejects relative and absolute symlinks", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "fyrlet-source-inventory-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  execFileSync("git", ["init", "--quiet"], { cwd: directory });
  await writeFile(join(directory, "regular.txt"), "source");
  execFileSync("git", ["add", "--", "regular.txt"], { cwd: directory });
  for (const target of ["regular.txt", join(directory, "regular.txt")]) {
    await symlink(target, join(directory, "link.txt"));
    execFileSync("git", ["add", "--", "link.txt"], { cwd: directory });
    await assert.rejects(sourceArchiveFiles(directory, ["regular.txt", "link.txt"]), /only supports regular files/);
    await rm(join(directory, "link.txt"));
  }
  assert.deepEqual(await sourceArchiveFiles(directory, ["regular.txt", "link.txt"]), ["regular.txt"]);
});

test("archive inspection rejects links, special files and unsafe paths", () => {
  const entries = ["package/", "package/index.js"];
  const verbose = ["drwxr-xr-x  0 0 0 0 Jan  1  1970 package/", "-rw-r--r--  0 0 0 1 Jan  1  1970 package/index.js"];
  assert.equal(archiveEntriesSafe(entries, verbose), true);
  for (const type of ["l", "h", "c", "b", "p", "s"]) {
    assert.equal(archiveEntriesSafe(entries, [verbose[0], `${type}${verbose[1].slice(1)}`]), false, `entry type ${type}`);
  }
  for (const path of ["../outside", "/outside", "C:/outside", "package/..\\outside", "package/node_modules/file"]) {
    assert.equal(archiveEntriesSafe([path], [verbose[1]]), false, path);
  }
  assert.equal(archiveEntriesSafe(entries, verbose.slice(1)), false);
});

test("hosted CI evidence requires a coherent successful Core pull_request run", () => {
  const revision = "a".repeat(40);
  const evidence = {
    revision,
    expectedRunId: "424500",
    repository: "wsafight/fyrlet",
    run: {
      id: 424500,
      path: ".github/workflows/core.yml",
      event: "pull_request",
      head_sha: revision,
      head_branch: "feat/release",
      status: "completed",
      conclusion: "success",
      pull_requests: [{ head: { sha: revision, ref: "feat/release" }, base: { repo: { full_name: "wsafight/fyrlet" } } }],
    },
    jobPage: {
      total_count: 2,
      jobs: [
        { run_id: 424500, name: "test (1.18, 27)", status: "completed", conclusion: "success" },
        { run_id: 424500, name: "test (1.20, 29)", status: "completed", conclusion: "success" },
      ],
    },
  };
  assert.equal(hostedCiRunPasses(evidence), true);
  const invalidCases = [
    ["workflow", (value) => { value.run.path = ".github/workflows/sdks.yml"; }],
    ["event", (value) => { value.run.event = "push"; }],
    ["head SHA", (value) => { value.run.head_sha = "b".repeat(40); }],
    ["PR association", (value) => { value.run.pull_requests = []; }],
    ["PR head", (value) => { value.run.pull_requests[0].head.sha = "b".repeat(40); }],
    ["base repository", (value) => { value.run.pull_requests[0].base.repo.full_name = "other/repository"; }],
    ["run result", (value) => { value.run.conclusion = "failure"; }],
    ["matrix result", (value) => { value.jobPage.jobs[1].conclusion = "failure"; }],
    ["matrix status", (value) => { value.jobPage.jobs[1].status = "queued"; }],
    ["job run", (value) => { value.jobPage.jobs[0].run_id = 1; }],
    ["pagination", (value) => { value.jobPage.total_count = 3; }],
    ["duplicate matrix job", (value) => { value.jobPage.jobs.push(value.jobPage.jobs[0]); value.jobPage.total_count = 3; }],
    ["run identifier", (value) => { value.expectedRunId = "1"; }],
  ];
  for (const [name, invalidate] of invalidCases) {
    const value = structuredClone(evidence);
    invalidate(value);
    assert.equal(hostedCiRunPasses(value), false, name);
  }
});
