# Release and deployment checks

English | [简体中文](zh/RELEASE_CHECKLIST.md)

Updated November 8, 2026. Local delivery, external acceptance and publication are separate decisions. Passing locally never establishes production capacity or a completed release.

## Repeatable local acceptance

```sh
node scripts/acceptance.mjs
node scripts/acceptance.mjs --groups core,client,host,bench,contract,integration,restore,browser
node scripts/acceptance.mjs --groups package,site
```

Install dependencies, start local PostgreSQL and install browser binaries first. The runner executes existing checks sequentially, stops on failure and keeps a timestamped report and per-stage logs under `.local/readiness/`. Directories are private and logs are 0600; existing reports are never overwritten. Fingerprints cover Git-tracked and non-ignored untracked files, including React, host code and tests, and are checked between stages. Each stage times out after 30 minutes. Reports retain external checks as not run. No package publication or real mail sending occurs. The package group builds archives and tests them in an external consumer directory only.

Core CI also tests benchmark/acceptance tooling and supports manual dispatch. Upstream main run `42451376341`, revision `7f97e40005b901fa11fd16ca4020210af94f6862`, failed on November 8, 2026: two session-batch assertions observed unrelated background telemetry. This branch isolates worker measurements and checks direct queries in the test process. The fix needs a new hosted run; the earlier successful PR run `42450925475` does not establish that main passed.

## External identity preflight

```sh
node --env-file-if-exists=examples/inbox-react/.env examples/inbox-react/server/check.mjs
```

Load the React host deployment environment first. The checker requires explicit HTTPS origins, project/service configuration, secure OIDC discovery and a 200 readiness response. It prints check names, not configuration values or error details. It only fetches discovery and readiness: no service credentials are sent and no sessions are issued or revoked. Success is not a login acceptance result.

`HOST_INSTANCES` defaults to 1. Multiple hosts require `HOST_STORE_DATABASE_URL` and a shared 32-byte base64url `HOST_STORE_KEY`; run `npm --prefix examples/inbox-react run migrate:store` before starting. The optional encrypted PostgreSQL store provides atomic one-time state consumption, scope capacity, expiry, serialized renewal, logout/issuance race handling and restart recovery. It requires direct/session-affine connections, not transaction pooling; see the [host example](../examples/inbox-react/README.md). Local pool/process-death tests are not external IdP or production deployment acceptance. Verify real login, renewal, logout, account/issuer changes, restarts and key recovery across deployed instances. IdP-side revocation still needs an explicit invalidation policy or bounded expiry.

## Local recovery, long-run and release tools

```sh
bash scripts/host_store.sh
node scripts/restore_smoke.mjs
node scripts/stability.mjs --seconds 30 --clients 4 --sample-ms 5000
node scripts/stability.mjs --seconds 86400 --clients 20
node scripts/release_check.mjs
```

The `host` and `restore` acceptance groups are also used in CI; restore follows integration. Restore only accepts an isolated loopback `*_integration`, `*_react` or `*_cluster` database, exports a consistent read-only snapshot, compares all public table counts/content fingerprints, repeats the selected application's migration twice (`--app inbox|notify|flow|agent|chat`, default `inbox`), and drops only its own newly generated destination. Both drill URLs reject query strings/fragments, including `?host=...` redirection. Its private dump is deleted; this is not production recovery or cross-version upgrade proof. CI uses PostgreSQL 17 Docker client tools (`RESTORE_DOCKER=1`); local use needs `pg_dump`/`pg_restore` compatible with the server and the host example's installed Node dependencies.

The stability wrapper uses the default local Chat/Agent cluster databases and ports 4250–4254 unless changed with `--base-port`. It preserves unique reports, checks source fingerprints, samples database growth, sessions/idempotency/jobs, pending age, unresolved effects and lock waiters, and retains node memory/cleanup/pool-queue telemetry in cluster samples. It rejects `CLUSTER_DATABASE_URL` overrides. A short drill never sets the 24-hour check to passed; no production resource SLO is implied. Multi-host faults still require another environment.

Release preflight never publishes. It checks clean committed sources, current-source artifact checksums, consistent server/SDK versions, maintainer policy/license and optionally an exact-revision CI run (`--ci-run RUN_ID`). No license or policy is selected automatically. Provide `deploy/release-policy.json` (or `--policy FILE`) only after maintainer approval: `maintainerApproved: true`, a root `licenseFile` named `LICENSE` or `LICENSE.<suffix>`, and nonempty strings `license`, `compatibility`, `deprecation`, `registries`. The file's existence is not legal or production approval. External acceptance still needs manual review. Build packages again after committing: package manifests record the full source fingerprint, revision and clean/dirty state.

## Upgrade and recovery

1. Fix exact server, SDK and host artifacts together; retain checksums, exported contracts, prior configuration and previous artifacts.
2. Back up the database and restore it into isolation. Verify startup and retained Run/Effect facts before changing production.
3. Run `mix fyrlet.migrate` or the release migration entry point on the restored database. Verify the contract, HTTP/Socket integration and host login lifecycle. Repeating the migration should be a no-op.
4. Gate traffic on `/ready`; observe pool waits, backlog age, reconciliation and unknown mutations. Verify a business write and confirmed view.
5. Roll back an application only to an artifact already tested against the migrated schema. Never reverse migrations or remove Run, Effect, receipt or idempotency facts to force startup. If incompatible, stop new writes and recover forward or restore a documented backup recovery point, including external-effect reconciliation.

This procedure is not evidence of a completed production restore or upgrade. No supported-version matrix or compatibility promise has been declared; define it for the intended release before publication.

## External acceptance still required

| Area | Evidence |
| --- | --- |
| Hosted CI | Passing jobs at the exact release revision for both Elixir/OTP combinations |
| Identity | Real IdP lifecycle and isolation; shared-store acceptance for multiple hosts |
| Load and faults | Stated topology/load/SLO, rate scans, mixed operations, multi-host faults and recovery correctness |
| Stability | Completed long-duration run with table growth, memory, pool, backlog and cleanup samples; short tests do not establish 24-hour stability |
| Devices and mail | Physical-device and real delivery/bounce/outage checks when included in the release scope |
| Distribution | Maintainer decisions on licensing, registries, versions and deprecation; Hex/npm publication remains deferred |

Performance tooling: [bench/fair/README.md](../bench/fair/README.md). Runtime limits and alerts: [OPERATIONS.md](OPERATIONS.md). Record actual results, failures and unverified boundaries in [ACCEPTANCE.md](ACCEPTANCE.md).
