# Local acceptance record

## November 8, 2026: sequential roadmap follow-up

Continued on `feat/readiness-and-performance` in CI, shared host storage, performance, reliability and release-preparation order. The final code run **passed all 15 stages**: `.local/readiness/followup-20261108-guarded/result.json`, SHA-256 source fingerprint `ff647bdd4eacfe1e87225da197cb60056df1973dfef2e9298f5b55ff46ade615` over 683 Git-tracked/non-ignored files. This is the code snapshot before adding this record; the earlier 13-stage checkpoint below retains its historical counts.

```sh
node scripts/acceptance.mjs --groups core,client,host,bench,contract,integration,restore,browser \
  --out .local/readiness/followup-20261108-guarded
node scripts/acceptance.mjs --groups package,site \
  --out .local/readiness/followup-20261108-artifacts
node scripts/release_check.mjs --out .local/readiness/followup-20261108-release-check.json
```

| Verification | Result | Evidence beside the final code report |
| --- | --- | --- |
| Elixir format/compile and tests | Passed, **776 tests**: 706 core, 35 examples, 35 packages | `core-1.log` through `core-3.log` |
| TypeScript SDK and typecheck | **304 passed**, line/branch coverage **99.27% / 95.66%** | `client-1.log`, `client-2.log` |
| React adapter and typecheck | **20 passed**, line/branch coverage **100% / 100%** | `client-3.log`, `client-4.log` |
| Host unit/startup/deployment tests | **68 passed** | `client-5.log` |
| Host tests including real PostgreSQL storage | **78 passed** (the same 68 plus 10 integration tests); loaded server module line/branch coverage **90.47% / 91.49%** | `host-1.log` |
| Benchmark/readiness tools | **37 passed** | `bench-1.log` |
| Contract export and generated types | Passed | `contract-1.log`, `contract-2.log` |
| Real HTTP/WebSocket integration | **20 passed** | `integration-1.log` |
| Isolated snapshot restore and repeated migration | Passed | `restore-1.log` |
| Browser workflow | **14 passed**, including the parent; signed local IdP | `browser-1.log` |

CI uses this frozen-source entry point with host/restore stages and always uploads its report; no new hosted run for this unpublished branch is claimed. Shared host storage now supports encrypted PostgreSQL state, atomic login consumption, cross-pool rotation/logout and restart; it requires direct/session-affine connections, not transaction pooling. Regressions cover a killed lock holder, scoped capacity, lock timeout, more issuers than pool connections, reserved logout admission and known-token revocation on persistence/activity-query failure. Invalid startup configuration is sanitized. Local database drills reject URL query/fragment redirection before connecting. An intermediate `.local/readiness/followup-20261108-verified/` run was intentionally stopped at the host stage for URL-guard hardening; it is not a complete pass. Coverage includes the startup module's failure paths, not browser execution of all static-serving code.

The six short mixed/density runs passed correctness and harness thresholds at 10 users, 1/4 devices and 20 offered writes/s, three repetitions per point. See [PERFORMANCE.md](PERFORMANCE.md) and [sanitized evidence](bench/mixed-density-2026-11-08.json). They do not establish saturation, speedup or production capacity; physical-host CPU interference remains. PostgreSQL invalidation notifications stay disabled by default. Native `promtool` again accepted all four alert rules.

The short stability wrapper passed with four clients for 30 seconds: **527 writes, 10 reconnects, 10 session renewals**, full-history checks and subscriptions/Observers/read caches returning to zero. Its 10 database samples had no sample failures; database size changed from 27,784,883 to 28,169,907 bytes. Node samples retain memory and cumulative database queue/query telemetry; Chat/Agent failover/idempotency checks passed. Report: `.local/readiness/stability-followup-20261108/result.json`, measured tooling fingerprint `b2a60f44f74e7054bf65fdf8512f09097c3ff0da1f3cf68375e25e53de13b806`. This same-host short drill explicitly leaves 24-hour stability unverified; production resource thresholds are not selected.

A separate Notify snapshot/restore preserved all 22 public-table manifests, including **11 Runs, 10 Effects, 16 idempotency records and 10 notifications**; two Notify migrations changed no facts. Only its newly created destination database was dropped and its private dump removed. Report: `.local/readiness/restore-notify-followup-20261108/result.json`. These are local simulated-provider facts, not real mail, production recovery or cross-version upgrade proof.

Artifact/install/site verification for the documentation snapshot is recorded separately in `.local/readiness/followup-20261108-artifacts/result.json`; release preflight is `.local/readiness/followup-20261108-release-check.json`. Consult those reports independently of the code run above. Packaging records source fingerprints, revision, clean/dirty state and checksums. Release preflight never publishes; this branch is uncommitted/unpublished, with no maintainer-approved license/release policy or exact-revision hosted CI. External IdP/production shared-host deployment, multi-host faults, 24-hour execution, physical devices and real mail remain separate gates in the [release checklist](RELEASE_CHECKLIST.md).

## November 8, 2026: readiness and performance follow-up

Branch `feat/readiness-and-performance`, based on main revision `7f97e40005b901fa11fd16ca4020210af94f6862`. The frozen-source run below **passed all 13 stages**. Its report is `.local/readiness/2026-11-08-final-pass/result.json`, with per-stage logs alongside it; SHA-256 source fingerprint `c445871cd7a55269c35d8de7dab968563a65acb31b9dcaa846fa63626c910394` covers 670 Git-tracked/non-ignored files. This verification precedes only the acceptance-record update; artifact checks use a separate report for the updated documentation.

```sh
node scripts/acceptance.mjs --groups core,client,bench,contract,integration,browser \
  --out .local/readiness/2026-11-08-final-pass
node scripts/acceptance.mjs --groups package,site \
  --out .local/readiness/2026-11-08-artifacts
```

| Verification | Result | Evidence in the frozen-source report directory |
| --- | --- | --- |
| Elixir format and compile | Passed, warnings treated as errors | `core-1.log`, `core-2.log` |
| Core, examples and packages | **776 passed**: core 706, examples 35, packages 35 | `core-3.log` |
| TypeScript SDK | **304 passed**, typecheck passed; line/branch coverage **99.27% / 95.66%** | `client-1.log`, `client-2.log` |
| React adapter | **20 passed**, typecheck passed; line/branch coverage **100% / 100%** | `client-3.log`, `client-4.log` |
| OIDC host and deployment checker | **60 passed**; line/branch coverage **98.24% / 97.67%** over loaded server modules | `client-5.log` |
| Benchmark and acceptance tooling | **30 passed** | `bench-1.log` |
| Contract export and generated types | Passed | `contract-1.log`, `contract-2.log` |
| Real HTTP/WebSocket integration | **20 passed** | `integration-1.log` |
| Real browser workflow | **14 passed**, including the parent test; local signed test IdP, not an external provider | `browser-1.log` |

Additional checks: the session-batch tests passed all 9 cases with the previously problematic seed `926877`; notification/mode tests passed 18 cases; real integration with `FYRLET_POSTGRES_INVALIDATION=true` passed 20 tests. Local logs are `/tmp/fyrlet-session-final.log`, `/tmp/fyrlet-notify-final.log` and `/tmp/fyrlet-pg-integration.log`. Native `promtool` 3.1.0 validated all **4 alert rules** (`/tmp/fyrlet-promtool-native.log`); the official archive was checked against its release SHA-256 list. The initial Docker image pull failed in this environment, so this does not establish that the hosted container validation passed. Reusing existing scan and ABBA labels failed before execution, with the evidence checksums unchanged.

Upstream main CI run `42451376341` failed two shared-worker telemetry assertions. Tests now isolate workers/emitting processes, bound queue waits and verify bypass queries in the calling process. The earlier PR run `42450925475` succeeded, but neither that run nor this local pass is a hosted result for this branch. CI now also runs tooling tests, validates alert rules and permits manual dispatch; **a new hosted run remains pending**. Intermediate local attempts stopped by the source-fingerprint guard, including `.local/readiness/2026-11-08-verified/result.json`, are failed attempts, not complete acceptance evidence.

Performance evidence is in [PERFORMANCE.md](PERFORMANCE.md) and [the sanitized JSON](bench/readiness-performance-2026-11-08.json): the six 100/s and 500/s baseline points passed their SLO with 100% delivery coverage and no OOM, but do not establish maximum capacity. The eight same-image PostgreSQL-notification ABBA runs all passed correctness; only 3/4 default and 2/4 notification runs passed the load/latency SLO. Physical-host CPU interference and large variance mean **no speedup is demonstrated**; the option stays off by default. A final 10-user, single-generator notification-mode smoke also passed (`/tmp/fyrlet-smoke.log`).

`FYRLET_POSTGRES_INVALIDATION=true CLUSTER_SOAK_SECONDS=300 CLUSTER_CLIENTS=20 CLUSTER_BASE_PORT=4240 bash scripts/cluster.sh` passed Chat and Agent checks. Chat recorded 5,070 writes, 101 reconnects and 102 refreshes, full-history checks without gaps/duplicates, p50 32.12 ms and p95 36.43 ms (including 25 ms polling). Both nodes' subscriptions, observers and reader caches returned to zero. Agent checked cross-node Run idempotency, ownership and failover. Reports are `.local/cluster/chat.json` and `.local/cluster/agent.json`. This is same-host two-node evidence, **not multi-host or 24-hour acceptance**.

At this earlier checkpoint, external preflight remained unverified: OIDC lacked `PUBLIC_ORIGIN`, `FYRLET_ENDPOINT`, `FYRLET_PROJECT_ID`, `FYRLET_SERVICE_KEY`, `OIDC_PROVIDERS`; real mail lacked `RESEND_API_KEY`, `MAIL_FROM`, `MAIL_TO`. Reports are `.local/readiness/oidc-preflight.json` and `.local/readiness/mail-preflight.log`. No real login, mail send or registry publication occurred. Multi-instance host storage had not yet been implemented and the checker rejected `HOST_INSTANCES != 1`; the later section above supersedes that storage limitation. Physical devices, external IdP lifecycle, multi-host faults, long-duration stability, production restore/upgrade and production SLO thresholds remain separate gates in [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).

The artifact-group report records source-archive/npm builds, external-consumer installation smoke and documentation-site build/link checks separately. These are local checks, not Hex/npm publication or a production release.

## November 8, 2026: expanded roadmap regression tests

This pass adds **108 executable tests** plus compile-time contract assertions on `feat/react-contract-auth-retry`. No production implementation changed in this pass. Counts below include all SDK, React and host unit tests and the browser parent test; the earlier implementation record retains its original counts.

| Suite | Previous → current | Unit line / branch coverage | Command / evidence |
| --- | --- | --- | --- |
| TypeScript SDK | 253 → **304 passed** (+51) | **99.27% / 95.66%** | `npm --prefix sdks/typescript run test:coverage`; `.local/roadmap-sdk-coverage.log` |
| React adapter | 7 → **20 passed** (+13) | **100% / 100%** | `npm --prefix sdks/react run test:coverage`; `.local/roadmap-react-coverage.log` |
| OIDC host bridge | 16 → **56 passed** (+40) | **100% / 98.26%** | `npm --prefix examples/inbox-react run test:coverage`; `.local/roadmap-auth-coverage.log` |
| Real browser workflow | 10 → **14 passed** (+4) | Not measured by the unit coverage reports | `bash scripts/react.sh`; `.local/roadmap-browser-tests.log` |

SDK regressions cover retry defaults and invalid budgets, accepted Run recovery, transient versus permanent errors, independent concurrent keys and cancellation, authentication failure during another call's backoff, abort/close during receipt lookup, HTTP-date and numeric retry delays, selector lifecycle and metadata, deterministic generation, all operation kinds and nested schema/default semantics. Compile-time assertions cover operation-kind filtering, typed Run inputs/results, required Presence parameters/meta, legacy compatibility and projected React data with an unprojected subscription handle.

React regressions cover direct use without a Provider, missing-provider errors, client/name/mode changes, stale private deliveries, selector changes, equal parameters, independent listener release, 120 successive parameter switches, SSR with a populated client, malformed and oversized JSON, idempotent release and shared consumers at capacity. OIDC regressions exercise callback ambiguity, state expiry, signature/claim failures, discovery and configuration rejection, confidential-client authentication, wrong-project credentials, failed issuance and rotation, concurrent refreshes, bounded pending/host capacity, expiry, revocation concurrency/backoff and shutdown racing token issuance. Fake-clock identity tests mint their signed `iat` against that same clock.

The new browser scenarios verify production asset/source boundaries, permanent-error rollback, manual recovery after automatic recovery is exhausted, and logout during retry backoff. They use real PostgreSQL and Fyrlet with a signed local test IdP. Unknown predictions keep their documented display TTL; manual recovery must still produce one business write and one final displayed row. No screenshots are captured.

Node coverage is measured over the loaded SDK/React `dist/**/*.js` modules and host `server/*.mjs` modules in unit tests; it does not measure browser bundles, Elixir or production identity deployments. CI runs the three coverage commands and the browser suite; remote CI execution is still pending.

SDK and React typechecks and **20 real HTTP/WebSocket integration tests** also passed (`INTEGRATION_PORT=4203 bash scripts/integration.sh`; `.local/roadmap-integration-tests.log`). The documentation site and local artifacts are rebuilt with this expanded test record.

## November 8, 2026: React, contract types, login bridge and bounded retries

The `feat/react-contract-auth-retry` branch completes roadmap milestones 2–5 locally: an independent React adapter and Inbox page, generated Presence and operation-kind types, a host OIDC login bridge, and optional bounded retries. The reliability record below is an earlier pass with its original counts.

| Verification | Result | Command / evidence |
| --- | --- | --- |
| Elixir core, examples and packages | **764 passed**: core 694, examples 35, packages 35 | `bash scripts/test_all.sh`; `.local/roadmap-server-tests.log` |
| TypeScript SDK | **253 passed**, typecheck passed | `npm --prefix sdks/typescript test`, `npm --prefix sdks/typescript run typecheck`; `.local/roadmap-sdk-tests.log` |
| React adapter | **7 passed**, typecheck passed | `npm --prefix sdks/react test`, `npm --prefix sdks/react run typecheck`; `.local/roadmap-react-tests.log` |
| OIDC host bridge | **16 passed** | `npm --prefix examples/inbox-react test`; `.local/roadmap-auth-tests.log` |
| Real HTTP / WebSocket integration | **20 passed**, including lost-response retry recovery without replay | `INTEGRATION_PORT=4203 bash scripts/integration.sh`; `.local/roadmap-integration-tests.log` |
| Browser workflow | **10 passed**: one parent and nine scenarios against PostgreSQL, Fyrlet and a signed test OIDC provider | `bash scripts/react.sh`; `.local/roadmap-browser-tests.log` |
| CORS | **10 passed**, including exposure of `Retry-After` | `mix test test/fyrlet_web/cors_test.exs`; `.local/roadmap-cors-tests.log` |
| Elixir quality and contract agreement | Formatting, compilation without warnings, and fresh Inbox contract comparison passed | `mix format --check-formatted`, `mix compile --warnings-as-errors`, `node scripts/check_contract.mjs .local/roadmap-contract.json` |
| Production example and documentation | Production app build, site build and link checks passed | `npm --prefix examples/inbox-react run build`, `npm --prefix site run build`, `npm --prefix site run check`; `.local/roadmap-web-build.log`, `.local/roadmap-site-build.log`, `.local/roadmap-site-check.log` |
| Distribution | Three local artifacts built; packed core and React imports passed in an external consumer | `bash scripts/package.sh`, `bash scripts/install_smoke.sh`; `.local/roadmap-package.log`, `.local/roadmap-install.log`, `.local/releases/manifest.json` |

React checks cover shared consumers and final-reference cleanup, canonical parameters, client and mode isolation, Strict Mode, abandoned renders, selectors, bounded query storage and deterministic SSR/hydration. Browser scenarios cover login, shared subscriptions, optimistic writes and authoritative confirmation, a discarded response after commit, header-only retry delays, two tabs, parameter changes, reconnects, token refresh, logout, user/issuer isolation and host revocation. The browser workflow checks the narrow layout without capturing screenshots.

Retries remain disabled by default and require explicit operation metadata. All attempts keep the same serialized input and idempotency key. An uncertain write or Run only recovers its receipt; a missing or expired receipt remains unknown and cannot replay the business operation. Tests cover bounded attempts and total time, cancellation, authentication failure and `Retry-After`; write outcomes remain separate from view confirmation.

The [Inbox setup guide](../examples/inbox-react/README.md) explains how to configure a real provider. Local OIDC checks use a signed test provider and exercise PKCE, state, nonce, issuer/audience checks and server-owned sessions; they do not establish compatibility with a production identity deployment. The host stores bounded sessions in one process and clears login state on logout, expiry or host invalidation. External IdP revocation still depends on host invalidation or expiry. Remote CI, physical devices, multi-host deployment, 24-hour stability and registry publication remain outside this acceptance record.

## November 8, 2026: reliability and subscription completion

The `fix/reliability-and-subscription-improvements` branch completes operation-level 403 isolation, listener error isolation, correlated authoritative view confirmation, optional client query reuse, bounded retention work with continuation and metrics, database readiness and the core CI workflow. React integration, production capacity and remote CI execution are outside this local pass. The dated record below preserves earlier counts and statuses.

| Verification | Result | Command / evidence |
| --- | --- | --- |
| Elixir core, examples and packages | **764 passed**: core 694, examples 35, packages 35 | `bash scripts/test_all.sh`; `.local/all-tests.log` |
| TypeScript SDK | **232 passed**, typecheck passed | `npm --prefix sdks/typescript test`, `npm --prefix sdks/typescript run typecheck`; `.local/sdk-review-tests.log` |
| Real HTTP / WebSocket integration | **19 passed**, including shared client queries and committed/unchanged view confirmation | `INTEGRATION_PORT=4197 bash scripts/integration.sh`; `.local/integration-review.log` |
| Elixir quality checks | Formatting and compilation without warnings passed | `mix format --check-formatted`, `mix compile --warnings-as-errors` |
| Contract agreement | Fresh Inbox export matches the checked-in contract and generated SDK types | `node scripts/check_contract.mjs .local/ci/contract.json` after export |
| Documentation site | 62 pages built; 3080 internal links and 27 repository targets checked, no broken links | `npm --prefix site run build`, `npm --prefix site run check` |

Confirmation regression tests cover unrelated and stale snapshots, deltas, concurrent writes, independent subscriptions, unchanged/empty append snapshots, timeout, cancellation, reconnection, permission revocation, unsupported servers and malformed confirmation lists. Unsubscribing before the operation response produces an unconfirmed view while preserving the committed result. Duplicate confirmation IDs cannot disturb another waiter. Server tests exercise private and shared queries, warm-cache bypass and append reset before an old ACK. Cleanup tests verify shared row/time budgets, continuation, stream floors and retention protections; readiness tests verify both successful queries and sanitized HTTP 503 failures.

The CI workflow runs the suites, typecheck, contract comparison and integration on Elixir 1.18 / OTP 27 and Elixir 1.20 / OTP 29 with PostgreSQL 17 and Node 24. Only the local environment recorded below has been executed in this pass; no GitHub-hosted result is claimed. Existing databases need `mix fyrlet.migrate` for the session-expiry index. Cleanup duration is checked between statements and does not interrupt running SQL; row accounting excludes foreign-key cascades. No new throughput, multi-host or long-duration performance claim is made.

## November 7, 2026: earlier verification

This round continued the development and verification that can be run on this machine; the official Hex/npm release and the licence decision are deferred as requested. Real email credentials and a recipient have not been provided, and physical mobile devices, multi-host production environments and 24-hour stability are still pending verification and are not counted as passed results.

### Verifications that passed

Roadmap 1A on the same date passed **687 Elixir tests** (core 617, examples 35, packages 35), **132 SDK unit tests**, SDK type checking and **18 real-server integration scenarios**. Relative to the preceding pass, this adds 16 Elixir, 29 SDK unit and 3 integration tests. Verification covers completed/committed/accepted outcomes, definite versus unknown failures, cancellation before and after dispatch, stalled response bodies, listener cleanup, receipt expiry, normalized input, authorization and identity isolation. Real HTTP and Socket tests deliberately discard a reply after the database commit, recover the original receipt and verify exactly one business record with no replay. Commands: `bash scripts/test_all.sh`, `npm --prefix sdks/typescript test`, `npm --prefix sdks/typescript run typecheck`, `INTEGRATION_PORT=4197 bash scripts/integration.sh`. The [outcome guide](MUTATIONS.md) defines the recovery boundaries; authoritative subscription confirmation (1B) remains pending.

The table below preserves the earlier runs on 2026-11-07. Subsequent architecture, subscription-footprint and code-quality passes on the same date completed core 601, examples 35 (including Inbox 18), independent packages 35, SDK unit 103, SDK type check and real-server integration 15 (`INTEGRATION_PORT=4197 bash scripts/integration.sh`). The latest pass added nine Channel lifecycle and three SDK handle/control-message regressions. Coverage includes transaction cleanup and deduplication, definition validation, request cancellation and refresh deadlines, channel isolation, optimistic write ordering, embedded private views, snapshot/delta delivery, ACK recovery, authorization revocation, snapshot budgets, cross-Channel node quotas and timer cleanup. Inbox checks 360 mixed mutation steps against both an independent window model and fresh snapshots. The shared query-count tests also passed 11 consecutive runs after synchronizing the initial acknowledgements. Footprint and Tracker measurements are in [OPTIMIZATIONS.md](OPTIMIZATIONS.md#13-private-subscription-process-and-cache-footprint-2026-11-07); code reduction and the Presence ownership fix are in section 14. Other acceptance results remain as recorded below. Capability-level implementation status and the acceptance matrix are in [STATUS.md](STATUS.md).

The first full code-quality run reported two `SessionChecksTest` failures from additional batch telemetry events (599/601 passed). The SessionChecks/lifecycle subset then passed all 17 tests, the full suite passed all 601 with the original seed `926877` under `--trace`, and the final `bash scripts/test_all.sh` passed all 671 Elixir tests. The initial event-count interference remains recorded; its source was not established.

| Verification | Result | Entry point / evidence |
| --- | --- | --- |
| Elixir core, applications and standalone packages | 550 tests: core 495, applications 20, packages 35 | `bash scripts/test_all.sh` |
| TypeScript SDK | Unit 44, type check, real server 13 | `npm --prefix sdks/typescript test`, `npm --prefix sdks/typescript run typecheck`, `bash scripts/integration.sh` |
| Four-domain HTTP / WebSocket | 8 business and resource scenarios | `DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh` |
| Browser interaction and layout | Four applications × three viewports, 12 flows | `bash scripts/browser.sh`, [raw report](bench/browser-2026-11-07.json) |
| Two nodes on one machine | Chat 2 scenarios, Agent 1 scenario; includes 120 seconds of traffic | `bash scripts/cluster.sh`, [raw report](bench/cluster-2026-11-07.json) |
| Shared / append performance recheck | Shared view construction and data encoding reduced by 96%; append application payload reduced by 98.45% | [PERFORMANCE.md](PERFORMANCE.md#shared-rooms-and-append-streams-compared-end-to-end-2026-11-07) |
| Local distribution and installation outside the repository | Source package, SDK tgz, SHA256; Inbox / Agent tests outside the repository and an npm consumer | `bash scripts/package.sh`, `bash scripts/install_smoke.sh` |

The environment is macOS 26.6.2, Elixir 1.20.5 / OTP 29, Node 24.5.0 and a local PostgreSQL. Each script creates a new independent project and uses an independent test database; the scripts start and clean up the services and browsers. The raw reports contain no service keys or user tokens.

## Verification scripts

```sh
mix format --check-formatted
mix compile --warnings-as-errors
bash scripts/test_all.sh
npm --prefix sdks/typescript test
npm --prefix sdks/typescript run typecheck
(cd examples/inbox && mix fyrlet.contract ../../.local/ci/contract.json)
node scripts/check_contract.mjs .local/ci/contract.json
bash scripts/integration.sh
DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh
bash scripts/package.sh
bash scripts/install_smoke.sh
```

The SDK integration script uses the independent `fyrlet_integration` database and port 4100 by default (`INTEGRATION_PORT` overrides it), and verifies 19 real HTTP / WebSocket scenarios covering multiple devices, concurrent idempotency, isolation, revocation, restart, Run, append, shared client queries, view confirmation and mixed channels. The domain script uses ports 4180/4181 by default, which can be changed as in the example above, and runs the 8 business and web resource scenarios of the four applications in turn. Every script starts and stops its own services; credentials and logs are in `.local/integration/`. The distribution packages and SHA256 manifest are in `.local/releases/` and have not been published to any external registry. Verification of browsers, two nodes and real email is described in the sections below.

## Browser coverage

Prepare the repository dependencies and the database first, then install the browsers:

```sh
npm --prefix sdks/typescript ci
(cd sdks/typescript && npx playwright install chromium webkit)
bash scripts/browser.sh
bash scripts/browser.sh chat
```

The default service / simulated provider ports are 4210/4211 and can be overridden with `BROWSER_PORT` / `BROWSER_PROVIDER_PORT`. The database is `<domain>_browser`. Screenshots and a per-application JSON are written to `.local/browser/`, with login forms masked; 12 screenshots were checked in this round.

| Mode | Engine | Viewport |
| --- | --- | --- |
| Desktop | Chromium 153.0.8010.12 | 1280 × 900 |
| Android emulation (Pixel 5) | Same Chromium | 393 × 727, mobile touch profile |
| iPhone emulation (iPhone 13) | WebKit 26.6 | 390 × 664, mobile touch profile |

Coverage includes login, clearing of token input, no persistent storage, Notify submission through to simulated delivery confirmation, Flow signals and rejection of invalid JSON, Agent approve/reject/cancel, and Chat two-user invitation/history/human takeover/close/leave and plain-text injection protection. Each flow asserts no page JavaScript exceptions and no horizontal page overflow, and long English titles additionally cover wrapping in narrow columns.

This round of browser verification fixed two real problems: same-origin module requests were blocked by CORS; long titles widened desktop columns or mobile pages. CORS now allows same-origin sources by full scheme/host/port, while other origins are still constrained by the allowlist; invalid origins and a different port have regression tests.

The mobile profiles are browser emulation and cannot replace verification on physical Android/iPhone devices for the keyboard, system fonts, background suspension and network switching. The screenshots were used for manual layout inspection in this round, and no pixel-diff baseline has been established yet.

## Two nodes, failover and sustained traffic

```sh
bash scripts/cluster.sh
CLUSTER_SOAK_SECONDS=600 CLUSTER_CLIENTS=20 bash scripts/cluster.sh chat
```

By default it uses ports 4200–4204, two named BEAM nodes, the same random cookie, a shared PostgreSQL and a local HTTP/WebSocket forwarding proxy. The database is `<domain>_cluster`, and `CLUSTER_BASE_PORT` and `CLUSTER_DATABASE_URL` can override it. `CLUSTER_SOAK_SECONDS` supports 5–86400 seconds and `CLUSTER_CLIENTS` supports 2–50; a long run issues new sessions for the same subject during rotating reconnection and pagination, and does not depend on extending the 15-minute session limit.

The Chat verification covers cross-node shared and append notifications, concurrent writes with the same idempotency key committing only once, cross-node revocation clearing immediately, reconnecting to the other node through the proxy after SIGKILL, continued writing, and re-entry of the original node. The Agent verification covers idempotency of starting the same Run on two nodes, owner signal isolation, and a durable wait that can be approved to completion after a node exits with the task persisted only once. This proxy is used to test switching the target of a new connection; a production load balancer still needs separate configuration and verification.

The measured sustained traffic was 12 clients, 120 seconds, 2056 durable messages, 41 reconnections and 41 session renewals. The full history was checked item by item with no gaps or duplicates, and the realtime window of every client did not exceed 100 entries. The p50 from write to all clients seeing the data was 32.01ms and the p95 was 35.85ms, including 25ms of status polling. Resources were sampled about every 10 seconds during the run; the sampled peak of the read caches on the two nodes was 29/34 entries. After the connections were closed, subscriptions, Observers and read caches on both nodes returned to zero.

The test also fixed a revocation delay in shared subscriptions: an ordinary invalidation notification now re-checks all members even when the projected content has not changed, so a member who lost permission is closed and cleared immediately and the other members receive no redundant snapshot; the regression test uses an ordinary invalidation rather than a special member-change signal.

Results from two local processes sharing a database are not proof of multi-host production capacity, network partition recovery or 24-hour stability. For production deployment steps see [OPERATIONS.md](OPERATIONS.md#optional-two-node-deployment).

## Real email acceptance entry point

```sh
bash scripts/mail_live.sh --check
bash scripts/mail_live.sh
```

`RESEND_API_KEY`, a Resend-verified `MAIL_FROM` and your own `MAIL_TO` must be set explicitly in the environment. `--check` only checks the configuration and sends nothing; a normal run sends one email to `MAIL_TO`. The tool uses the real Notify application and Resend, and does not start the simulated provider; it verifies that the same idempotency key returns the same Run, and waits for the provider lookup to confirm delivered, for the in-app record, and for the Run to complete.

The default port is 4212, the database `notify_live` and the wait 180 seconds; `MAIL_SMOKE_PORT`, `MAIL_SMOKE_DATABASE_URL` and `MAIL_SMOKE_TIMEOUT_SECONDS` (30–600 seconds) can override them. The report is at `.local/mail-live/result.json`; it contains the Run ID and contains no keys or addresses. A failure or timeout is marked `unverified` and returns a failure; inspect the original Run before deciding whether to send again. Provider confirmation does not equal the user personally seeing it in the inbox; the inbox and the spam folder must also be checked manually.

The pre-check in this round confirmed that these three variables were missing, and no real email was sent. Real successful delivery, bounces and real provider outages are still not verified; neither the local protocol simulation nor delivered in the browser substitutes for them.
