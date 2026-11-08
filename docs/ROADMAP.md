# Fyrlet roadmap

English | [简体中文](zh/ROADMAP.md)

Updated November 8, 2026. This document sets priorities, dependencies and completion criteria without committing to release dates. The project has not launched; changes may replace interfaces directly, with the server, SDK, examples and documentation updated together. Milestones 1–5 are delivered locally, including React bindings, contract types, bounded retries and an OIDC login example. External IdP deployments, production operation and publication retain separate acceptance boundaries. Capabilities and verification records are maintained in [STATUS.md](STATUS.md) and [ACCEPTANCE.md](ACCEPTANCE.md).

## Direction

Improve the complete application workflow from business calls and realtime subscriptions to UI state. Help developers determine mutation outcomes, reduce duplicated component state management and connect their existing login system.

Retain Phoenix, PostgreSQL, named Operations and bounded Subscriptions. The core owns protocol and consistency rules; client state, UI adapters and login examples ship as separate modules. See [PRODUCT.md](PRODUCT.md) and [ARCHITECTURE.md](ARCHITECTURE.md) for scope and constraints.

## Milestones

P0 addresses outcomes and consistency, P1 improves application development, and P2 is evaluated against demonstrated needs. Milestone numbers organize delivery; independently verifiable work can proceed in parallel.

| Milestone | Priority | Deliverable | Dependencies |
| --- | --- | --- | --- |
| 1. Mutation outcomes and view confirmation | P0 | 1A defines operation and unknown outcomes; 1B confirms updated views | Define outcomes first; design and validate view confirmation separately |
| 2. Shared client queries and React integration | P1 | Query reuse, selectors, a separate React adapter and a working page | Can proceed independently of milestone 1 |
| 3. Complete contract types | P1 | Presence types, operation categories and explicit runtime metadata | Can proceed independently of milestones 1 and 2 |
| 4. Bounded transient-failure retries | P1 | Opt-in retries with a fixed idempotency key and explicit bounds | Requires 1A outcome rules and server idempotency guarantees; milestone 3 can supply metadata |
| 5. Login bridge and application acceptance | P1 | Login, renewal, logout, identity changes and client cleanup | The login example can start early; final acceptance combines previous milestones |

## Execution order and decision points

- Preserve the delivered 1A outcome categories, idempotency-key lifecycle and receipt recovery, and 1B's correlated authoritative refresh. A committed operation and a confirmed view remain separately observable.
- Query reuse now supports a React adapter and Inbox page with typed calls and an OIDC login bridge. Further API changes should follow actual application feedback.
- Bounded retries require 1A and endpoint idempotency guarantees, without waiting for 1B. Applications separately choose whether to wait for updated views; a committed write and a caught-up UI remain distinct results.
- Define observable behavior, resource bounds and failure handling before implementing each deliverable. Undecided work remains planned; [STATUS.md](STATUS.md) records implementation progress.

## Milestone 1: mutation outcomes and view confirmation

Progress: **1A and 1B delivered.** `mutate` exposes an outcome lifecycle and separate `views` results while `call` preserves the business return value. HTTP and Socket support read-only receipt recovery. See [MUTATIONS.md](MUTATIONS.md) for interfaces and boundaries.

A successful `call` establishes an operation outcome but does not establish that subscriptions have observed its commit. Snapshot and append predictions now retire on correlated authoritative confirmation or a display TTL; unrelated updates cannot confirm them. Network failure or client cancellation may happen after the server commits, requiring an explicit unknown outcome.

Delivered interfaces:

- **1A: operation outcomes (delivered).** An optional lifecycle distinguishes definite failure, read completion, write commit, Run/ingest acceptance and unknown results. Preserve the business-result return from `call`. Ambiguous failures retain the key; recovery only queries write/run receipts, leaves absent or expired receipts unknown and never replays business execution.
- **1B: view confirmation (delivered).** `mutation.views`, `CallOptions.confirm` and `subscription.confirm()` use a refresh requested after success, carrying a correlation identifier. The server bypasses old view caches and confirms a fresh full snapshot. Each active subscription permits at most 32 pending confirmations.
- An idempotency key and recovery path for unknown outcomes, with an explicit unconfirmed state when waiting for a view times out.
- Define new wire semantics and capability negotiation together; update server and SDK as one change without retaining an old protocol implementation.

Completion criteria:

- 1A verifies cancellation before and after dispatch, fixed input and keys during authentication refresh, lost committed responses, receipt expiry, normalized-input conflicts and authorization isolation. Recovery failures and prediction expiry cannot turn an unknown result into a definite failure.
- The view-confirmation guarantees below are implemented; TTL expiry remains a display fallback and never confirms a view.
- Delayed older queries, unrelated updates, cached old snapshots and refresh accepted replies cannot retire predictions early.
- Cover updates before responses, successive writes, independent confirmation for several subscriptions, unchanged results, filtering and deletion.
- Cover lost responses after commit, idempotent retries, reconnects, revoked permissions, delta and append fallbacks.
- Confirmation refers to an authoritative view read after commit. Filters and pagination still govern membership, and subscriptions update independently.

Correlation identifiers match requests and responses. Channel `seq`, Observer revision and Oban job IDs are not database commit order. Replica reads or commit watermarks require a separate consistency design and cost measurement.

## Milestone 2: shared client queries and React integration

Progress: **delivered.** The core provides `selectSubscription`; the independent [React package](../sdks/react/README.md) provides a Provider, `useQuery` and deterministic empty SSR state. The [Suiji page](../examples/inbox-react/README.md) exercises the complete workflow. Core sharing and the React store default to at most 100 active queries, limit canonical JSON parameters to 64 KiB and immediately clean up the final reference.

Delivered:

- **Delivered:** an optional reference-counted query store within one client, keyed by identity context, query name, structurally defined parameters and delivery mode.
- Pure selectors and a separate React adapter using `useSyncExternalStore`. Keep the core SDK independent of UI frameworks.
- An Inbox or Chat React page demonstrating shared queries, parameter changes, optimistic updates and connection state.
- Defined SSR initial state and request isolation, using a deterministic empty initial state.

Completion criteria:

- Two components share one active subscription; releasing one preserves the other, and the final release cleans up.
- Query storage has explicit count and memory bounds. Retaining unreferenced cache entries requires capacity, expiry and eviction rules.
- Different parameters, identities and modes remain separate, with explicit JSON parameter equality rules.
- Strict Mode, parameter changes and reconnects do not leak resources. Unchanged snapshots retain stable references, and hydration begins with consistent state.
- Logout, authentication failure and client closure clear private state.

The first implementation reuses identical query results and manages Presence handles separately. Equal IDs in different queries may have different authorization or field projections; entity merging remains a later evaluation.

## Milestone 3: complete contract types

Progress: **delivered.** Generated contracts include operation/subscription inputs and outputs, Presence names, parameters and meta, operation kinds, and an explicit `operationMetadata` constant. `startRun` restricts names by kind. Every contract must explicitly declare `kind` for each operation and a `presence` section (empty when unused); pre-release contracts without those fields are rejected at compile time.

Delivered:

- Generated Presence room names, parameters and meta types, plus operation kinds.
- Explicit runtime metadata where needed for capability checks and retry policy. Treat TypeScript types and runtime policy separately.
- Update hand-written contracts, generated contracts and call sites to the same final API.

Runtime metadata can help classify operations; server transactions and idempotency guarantees still determine whether retrying is safe.

Completion criteria: invalid names, meta and inputs fail type checking; missing operation kinds or Presence declarations fail type checking; valid examples build; generated artifacts match server exports; undeclared capabilities remain unavailable.

## Milestone 4: bounded transient-failure retries

Progress: **delivered.** `CallOptions.retry` is disabled by default and requires explicit operation metadata. Read/write/run calls are eligible; signal, cancel and ingest are excluded. Bounds are at most 10 attempts and 60 seconds total, defaulting to 3 attempts / 15 seconds. Reads and definitely rejected calls can be attempted again. Once a write or Run becomes uncertain, subsequent attempts only look up its receipt; missing or expired receipts remain unknown, preventing replay beyond retention. `pending.retry` exposes progress; view confirmation remains separate.

Delivered:

- A fixed idempotency key, attempt and total-time limits, backoff with jitter and server retry-after handling.
- A defined set of eligible managed calls, with signals, ingest and other entry points reviewed independently.
- Observable cancellation, timeout and unknown outcomes.

Completion criteria: a lost response after commit does not duplicate a write; authentication refresh and network retry share a key; replay does not exceed server idempotency retention; permission, validation, CONFLICT and protocol errors are not blindly retried; cancellation and deadlines prevent further attempts.

Interruption or timeout does not cancel a server transaction. External effects retain their own deduplication and reconciliation rules. Initial retries remain within the current client lifecycle and identity context.

## Milestone 5: login bridge and application acceptance

Provide an example where the host backend derives Fyrlet sessions from its verified login context, covering browser login, renewal and logout. Existing identity systems continue to own passwords, recovery and OAuth authorization services.

Progress: **local example and optional PostgreSQL host storage delivered.** Suiji uses OIDC authorization code, PKCE and signed ID tokens, covering renewal, logout, revocation, account changes, cross-tab cleanup and issuer isolation. Shared storage adds encrypted state, atomic login-state consumption, serialized refresh, cross-instance logout and restart recovery. Tests use real local PostgreSQL and a signed test IdP; external provider and production multi-instance acceptance remain pending.

Completion criteria:

- Cover login, renewal, logout, revocation and account switching.
- Browsers cannot choose trusted subjects or read service keys. External IdP configuration and identity mapping are verified.
- Equal external usernames from different issuers remain distinct.
- Logout clears subscriptions, predictions and query stores, and prevents further attempts belonging to the previous identity.
- Exercise view confirmation, shared queries, typed calls and optional retries together in a working page.

## Later evaluations

### Current readiness and performance work

Local follow-up now includes a grouped acceptance runner, HTTPS/OIDC deployment preflight, Prometheus pool/backlog alerts, protected benchmark evidence and repeated rate scans. Optional transactional PostgreSQL invalidations are implemented behind `FYRLET_POSTGRES_INVALIDATION`; the default delivery path is unchanged and disconnected-listener recovery still uses reconciliation. Commands, upgrade steps and external gates are in [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).

Rate scans now also vary user/fanout density and support mixed add/update/archive/restore/delete, paginated history and explicit view confirmation. Keep source fingerprints, resource limits, correctness assertions and at least three repetitions per point; short runs do not establish capacity. Multiplexing still requires evidence that remaining Channel memory is a bottleneck; no VM/GC/NIF rewrite is justified. CI uses the frozen-source acceptance runner; restore and long-run sampling tools are available. External IdP/production shared-store deployment, a new hosted CI run, multi-host faults, 24-hour operation and actual registry publication remain separate gates. Apache-2.0 and the initial core + TypeScript + React release scope are selected.

| Direction | Trigger | Questions to resolve first |
| --- | --- | --- |
| Multiplex subscription channel | Process memory remains a measured bottleneck after private state is embedded | Independent per-view authorization, ACK, expiry and quotas; compare against the current Channel baseline before adopting a new wire format |
| Entity and projection caching | At least two real applications repeatedly need cross-view coordination | Explicit entities, versions, field permissions, deletion and reference counting; absence from a list is not global deletion |
| Offline caches and persistent write queues | A specific offline use case | Expiry, revocation, account changes, conflicts, idempotency retention and storage cleanup |
| Production deployment improvements | Defined topology, load and recovery targets | Database readiness and pool/backlog alert rules are delivered; production thresholds, mixed workloads, multi-host faults and long-duration stability remain unverified |
| Global project quotas | Strict cross-node tenant limits become a requirement | Distributed accounting, consistency cost and limits during failures |

Password accounts, a complete client query engine, frontend build tools and mobile packaging are outside the near-term schedule. Introduce abstractions based on application needs and verification results.

## Before a release

Choose checks for the actual release scope without requiring completion of the entire roadmap. Build on existing local packaging, installation acceptance and telemetry, adding evidence for the behavior affected by each change.

| Check | Completion criteria |
| --- | --- |
| Protocol and SDK agreement | Update wire formats and call sites together; verify capability negotiation, unsupported versions and error handling |
| Installation and upgrades | An application outside the repository can install distribution packages, migrate and run; define upgrade paths from supported versions and recovery after failures |
| Operational visibility | Distinguish process liveness from database readiness; observe pool waits, job backlogs, subscription recovery and unconfirmed calls |
| Load and failure recovery | State connections, subscriptions, room members, write rates and data sizes before testing mixed workloads, reconnects and failures; retain resource samples and correctness assertions |
| Distribution and maintenance | Apache-2.0, aligned core/TypeScript/React versions and the initial release scope are selected; before actual publication, maintainers verify registry ownership and approve publication and the compatibility/deprecation policy |

## Delivery and verification

Ship each milestone independently with public interfaces, boundaries, relevant tests and at least one runnable example. Protocol or generated-contract changes update the server, SDK and both documentation languages together, while verifying existing usage.

Reuse current tests, telemetry and benchmarks. Verify new reliability guarantees through failures and races. State workload, topology and measurement scope for performance claims, following [PERFORMANCE.md](PERFORMANCE.md). Update [STATUS.md](STATUS.md) on completion and record evidence in [ACCEPTANCE.md](ACCEPTANCE.md).

Next, iterate on delivered APIs from application feedback and collect the remote CI, external IdP, production load and multi-host failure evidence required by the chosen release scope. P2 evaluations retain their individual triggers.
