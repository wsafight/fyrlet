# Local acceptance record

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
