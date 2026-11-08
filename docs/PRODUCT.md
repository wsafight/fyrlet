# Fyrlet product documentation

Fyrlet is a realtime application framework built on Phoenix. This document describes the product positioning, scope, functional requirements and commitments. For the documentation index, see [README.md](README.md); for the current implementation status and acceptance matrices, see [STATUS.md](STATUS.md).

## Product positioning

Build a realtime application framework on Phoenix that lets developers define business operations, data subscriptions and access permissions on the server, and then expose them to web, mobile or other clients through a unified protocol.

It borrows the development experience of Meteor, which connects business calls, data subscriptions and client state management. The server runs on Phoenix / Elixir, clients use the data protocol through an SDK, and each client builds its own UI.

The product is first used for the author's own applications: a server framework that can be integrated into a Phoenix project, plus several reference applications, with actual reuse deciding the abstractions and extensions.

One-sentence goal: **define the business once, let multiple clients call it through the same contract, and give them correct visible data after data changes, connection interruptions and recovery.**

The base model is **Operation + Subscription**: one authorized query, one complete snapshot, one transactional write, one business result. Products that need long-running work, external side effects, continuously appended output, multi-user groups or public entry points use **optional** official modules (Run, Effect, append subscriptions, shared subscriptions, presence, plugins); see [ARCHITECTURE.md](ARCHITECTURE.md).

## Foundational decisions

| Item | Decision |
| --- | --- |
| Primary users | The author first, then developers building applications with Phoenix |
| Deliverables | Server framework, TypeScript SDK, contract type generation, reference applications and end-to-end verification |
| Server foundation | Phoenix, Ecto, PostgreSQL, Phoenix Channels / PubSub |
| Durable notification | Oban jobs in the same PostgreSQL database as the business data |
| Call entry point | An HTTP business call interface, and isomorphic calls over the Socket |
| Subscription entry point | An application-level subscription protocol on Phoenix Channels |
| Synchronization | Bounded query snapshots, refresh triggered by change notifications, snapshot re-fetched on reconnect; optional field-level deltas and append subscriptions |
| SDK direction | A TypeScript SDK is provided today; the protocol stays implementable in other languages |
| Deployment | Self-hosted; one business runtime supports data and identity isolation for multiple projects; single node, with an optional two-node setup on one machine |
| Product form | A reusable application framework that can also serve as the server for trusted business logic; an admin console and commercial hosting are out of scope |

**Record-level patch-style delta synchronization, offline writes and resumable transfer are not promised.** The first goal is to make subscriptions over a bounded range refresh correctly; field-level deltas (`delta-v1`) and append subscriptions are transport optimizations with explicit applicability conditions and do not change the fact that the snapshot is the authoritative state. An automatic WebSocket reconnect must not be equated with business data having been recovered.

## Problems to solve

Building a multi-client realtime application usually means handling the following work over and over:

1. Define call interfaces, input validation and a unified error format for the business logic.
2. Wire authentication and data permissions into every operation and subscription.
3. Notify the relevant clients after data is committed and recompute the data visible to them.
4. Handle the race between the initial read and later updates, and data recovery after a disconnect.
5. Handle client retries without creating duplicate business data.
6. Keep input, output and protocol semantics consistent across different clients.

The framework takes care of these repeated mechanisms. Application developers own the business rules, the domain model, permission policies and the UI.

## Users and use cases

### Primary users

- The author: uses the framework to build personal tools and checks whether it reduces repeated development work for a second application.
- Phoenix application developers: want unified call and subscription capabilities through explicit business declarations.
- Client developers: use the server through the TypeScript SDK or the public protocol, and care about business data and connection state.

### Core usage flow

1. The developer integrates the framework into an existing Phoenix application.
2. They register business operations, query subscriptions and the corresponding permissions.
3. The client authenticates, then calls operations or opens subscriptions.
4. The server validates input and permissions, runs the business logic and returns a structured result.
5. After the business change is committed, the relevant subscriptions refresh their visible data.
6. After a disconnect, the client reconnects, is re-authorized and fetches the latest snapshot.

### First reference application: personal inbox

Users can save and view text, links and short code snippets on different devices.

- Add an inbox entry.
- View the current user's most recent entries.
- Edit text, archive or delete entries.
- See the updated list on another device.
- Get the correct current list after recovering from a disconnect.
- Fetch older entries through a history pagination query.

The reference application supports multiple accounts to verify data isolation between users. Each user's inbox is independent.

Images, file uploads, web page capture, full-text search and AI organization are left out of the reference application for now, so that the example business does not hide correctness problems in the framework itself.

### Applicable product categories

| Product category | Core capabilities relied on | Notes |
| --- | --- | --- |
| Notifications and message delivery (Novu-like) | Durable Run + Effect + receipt | Verified by `examples/notify`, with one external channel |
| Long-running tasks / agent runs (Trigger.dev, Dify-like) | Run + wait and resume + run snapshot | Verified by `examples/agent`, with a finite number of steps and human approval |
| Workflow execution (n8n-like) | Run + wait node + run records | Verified by `examples/flow`, sequential flows; no branches or loops |
| Realtime collaboration / customer support conversations (Chatwoot-like) | Shared subscription + append subscription + anonymous entry point | Verified by `examples/chat` |
| Monitoring and status pages (Uptime Kuma-like) | Public read-only entry point | Business scheduling is owned by the application |
| Observability and evaluation (Langfuse-like) | Batch ingestion entry point | Aggregate analytics is outside this framework |

Not promised: a connector ecosystem, a visual canvas, a complete business UI, or aggregate analytics storage. These are the responsibility of capability packages, domain packages or external systems.

### Reference projects and capability mapping

The table below shows what Fyrlet and the application each take on:

| Reference project | What Fyrlet can take on | What the application or external systems take on |
| --- | --- | --- |
| Chatwoot | `Chat`: conversation state, agent collaboration, realtime message subscriptions, shared subscriptions | Channel integration, assignment rules, search and the support UI |
| Novu | `Notify`: notification Runs, Effect dispatch, retries, receipts and queryable state | Channel adapters, templates, user preferences and provider delivery semantics |
| Uptime Kuma | A monitoring application: writing probe results, alert Effects, public status subscriptions | Probe scheduling, protocol checks, alert rules and historical statistics |
| n8n | `Flow`: sequential nodes, waiting for signals, execution records and recovery | The flow canvas, connectors, flow versions and the execution environment for user code |
| Trigger.dev | The Run module: task acceptance, queueing, concurrency limits, retries, cancellation and recovery; the external executor protocol | Language SDKs, the runtime for user code and process-level checkpointing |
| Dify | `Agent`: finite tool steps, model-call Effects, human approval and run snapshots; append subscriptions for high-frequency output | Document parsing, RAG, model and tool adapters, agent business logic |
| Langfuse | An observability/evaluation application: run timelines, asynchronous evaluation Runs, batch ingestion | Instrumentation SDKs, large-scale trace storage, aggregate queries and the analytics UI |

Notify, Flow, Agent and Chat are implemented as standalone applications with models, migrations, web pages and end-to-end verification (see [PLUGINS.md](PLUGINS.md#domain-packages-not-plugins)). Agent contains only deterministic text tools and approval, and Chat contains only login and invitation-based conversations; the full feature sets of projects such as Dify and Chatwoot are not a delivery checklist.

## Scope

### Capability overview

| Capability | Scope |
| --- | --- |
| Business declarations | Named operations and named subscriptions, with explicit input, output, authorization and execution logic |
| Input and output contracts | One contract used for runtime validation, export and TypeScript type generation |
| Authentication | Project service keys, short-lived user tokens exchanged by a trusted backend, revocation and expiry handling |
| Project isolation | Project / Subject identity boundary, query filtering, composite foreign keys and authorization-bypass tests |
| TypeScript SDK | Business calls, subscription state, disconnect recovery, token refresh, resource closing and a server-side authentication helper entry point |
| Permissions | Operation authorization, subscription authorization, data scope filtering, validity period and revocation handling |
| Business calls | HTTP calls, structured results, unified errors, request identifiers |
| Write reliability | Transactional commit, idempotent handling, durable change notification |
| Realtime subscriptions | Parameterized bounded queries, initial snapshot, invalidation refresh, unsubscribe; optional field-level deltas, append subscriptions, shared subscriptions, presence |
| Recovery | Re-authorization and re-read after reconnect, manual refresh, periodic re-check as a safety net |
| Durable tasks (optional) | Run, waits and signals, cancellation, leases and recovery, external executors; Effect and Outbox |
| Observability | Correlated logs, telemetry and Prometheus metrics for requests, operations, subscriptions and background jobs |
| Extension | Capability packages / plugins, domain packages, project quotas |
| Reference applications | The personal inbox, plus four domain applications: Notify, Flow, Agent and Chat |
| Developer documentation | Integration tutorial, protocol description, error description, testing and startup instructions |

### Non-goals

- Dart, Swift and Kotlin SDKs, and standalone React / React Native UI bindings (only the TypeScript SDK exists today).
- A general-purpose realtime database protocol for arbitrary tables and arbitrary client queries.
- Arbitrary JSON Patch-style delta synchronization, incremental pagination merge, CRDTs, multi-user rich text, offline writes and automatic conflict merging; a general-purpose IM system.
- A multi-application tenant console, billing, commercial hosting, an application marketplace.
- Custom multi-node state sharding, multi-node room uniqueness and cross-region deployment. A two-node setup on one machine has been verified; larger deployments need single-node capacity evidence and a separate design.
- An online execution environment for arbitrary server code submitted by users, and executing arbitrary user-submitted Elixir code in-process.
- A visual low-code editor, a flow canvas and natural-language project generation.
- A connector ecosystem in the core, third-party channel SDKs, provider protocol adapters (these belong to capability packages or applications).
- Aggregate analytics storage (ClickHouse-like) and a query engine.
- Dynamic DAGs, parallel branches, sub-workflows, general compensation orchestration and in-flight code migration.

### Not yet provided

Actual Hex / npm publication and verified registry ownership (Apache-2.0 is selected); cross-node global quotas; an admin UI; an OIDC verifier; a key rotation interface; a verified capacity baseline.

## Core concepts

| Concept | Definition |
| --- | --- |
| Actor | The server-verified identity of a caller and its authorization context |
| Operation | A named business call with input, output and permission requirements, distinguishing reads from writes |
| Subscription | A server-side query definition with a name and parameters, whose output is a bounded, authorized data set |
| Snapshot | The complete visible result of one subscription query, which the client uses to replace the data of that subscription |
| Scope | The routing range of a change notification, for example one user's inbox; it does not replace permission checks |
| Invalidation | An internal notification that data may have changed, triggering the relevant subscriptions to query again |
| Contract | A serializable description of operations, subscriptions, data types and the error format |
| Subscription generation | The identifier of one subscription instance, used to isolate messages from before and after a reconnect or re-subscription |
| Run / Step | A durable run that can be resumed across requests and processes, and its work nodes or wait nodes; see [RUNS.md](RUNS.md) |
| Effect | The intent and dispatch record of an external side effect; uncertain outcomes are kept as they are; see [EFFECTS.md](EFFECTS.md) |
| Capability | An optional server capability that the client negotiates at connection time; see [PROTOCOL.md](PROTOCOL.md#capability-negotiation) |

## Server functional requirements

### FR-01: Business registration and contract

- Developers can explicitly register operations and subscriptions; names are unique and stable within the application.
- An operation declares its name, read/write type, input, output, authorization and execution logic.
- A subscription declares its name, parameters, output, authorization, query logic, the Scopes it depends on and a result limit.
- Input and output cover strings, booleans, JavaScript safe integers, lists, closed objects, nullable values and string enums.
- UUIDs, timestamps, high-precision decimals and integers beyond the JavaScript safe integer range use explicit string encoding rules, so the contract is not tied to any one client language.
- The contract can be exported in a machine-readable format and identifies the framework protocol version and the business contract version.
- At startup, name conflicts, missing implementations and invalid declarations are checked, and errors that point to the cause are reported.
- TypeScript types are generated from the contract exported by the server; applications are not required to use Ash. Application business data is persisted through Ecto.

### FR-02: Authentication and authorization

- Platform developer identity, project service keys and end-user sessions are distinguished; the last two layers are implemented today, and platform login is out of scope.
- Projects and service keys are created through development commands; a service key is stored only in the trusted backend and never reaches a browser or mobile client.
- The customer's business backend first authenticates its own user, then exchanges a short-lived user token using the service key and a trusted external user identifier.
- An external identity is mapped to an internal Subject by `(project_id, issuer, external_subject)`; clients cannot choose the Subject themselves.
- The default user token lifetime is 10 minutes, configurable to 60–900 seconds at issue time; only token hashes are stored, and single-session revocation is supported.
- Revoking a project key prevents new sessions from being issued; existing sessions are revoked individually or left to expire; a key has no interface for arbitrary user business reads or writes.
- Identity comes from the server's verification result; a user ID in request parameters is not accepted as proof of identity.
- Permissions are checked on every HTTP call, subscription establishment, re-subscription and before every snapshot is delivered.
- Subscription queries must restrict the data scope at the database read stage; reading other users' data first and relying on client-side filtering is forbidden.
- A Scope hit can only trigger a query; it cannot grant permission to read data.
- After a token expires, the server stops accepting new operations and ends the related connections.
- When an application revokes permissions it should send a permission change notification; a periodic re-check is provided as a safety net, with a default interval of 30 seconds, configurable.
- After a permission re-check fails, pushing stops and a subscription-closed reason is sent, and the SDK clears that subscription's cache. See [Authentication design](AUTH.md).

### FR-03: Business calls

- Registered Operations are called over HTTP.
- The call order is: parse the request, authenticate, validate input, authorize, execute the business logic, validate output, return the result.
- Every call carries or generates a `request_id`, and the correlation identifier is kept in errors and logs.
- Business rejections, field validation failures and server exceptions return different error types.
- Unhandled exceptions are converted into internal error responses, without exposing stack traces or database details to the caller.
- Read operations produce no business writes or change notifications.
- A write operation is successful when the database transaction commits; entering a job queue must not be treated as the write being complete.
- Output validation of a write result completes before the transaction commits; if validation fails, the transaction is rolled back, and a result with a structural error but a business change that did succeed must not be returned.

### FR-04: Idempotency and write notification

- Write operations that need retry protection require the client to supply an `idempotency_key`.
- The idempotency scope includes at least the Actor, the operation name and the idempotency key, and a digest of the normalized input is recorded.
- Within the same scope, the same key with the same input returns the original successful result; the same key with different input returns a conflict.
- Concurrent submissions are guaranteed by database unique constraints and the transaction to produce that business write at most once.
- Atomic business results for single writes are supported; requests whose transaction failed can be executed again.
- Idempotent success results are kept for 24 hours by default, configurable by the application; duplicate submissions after the retention period are outside the deduplication guarantee.
- The business data, the idempotent success record and the change notification job are committed in the same transaction.
- Oban jobs carry the durable change notification; after a job runs, it publishes an invalidation notification to the relevant Scopes.
- Duplicate notifications are allowed to occur; subscription refresh must be safe to repeat.
- Writes that produce side effects on external services are outside the request idempotency guarantee; when external side effects are needed, use Run and Effect, see [EFFECTS.md](EFFECTS.md).

### FR-05: Realtime subscriptions

- Clients subscribe to registered names and parameters over Phoenix Channels.
- The server assigns the subscription an identifier and a generation, and returns the authorized initial snapshot.
- Only collections with explicit limits on item count and response body size are supported; exceeding a limit returns a structured error.
- The examples subscribe in realtime to the most recent page only; history pagination is done through read operations.
- After receiving a relevant invalidation notification, the subscription re-authorizes, queries and sends a complete snapshot.
- Consecutive invalidation notifications for the same subscription may be merged to avoid pointless repeated queries.
- Unless the permission context and query semantics are proven to be exactly identical, query results or caches are not reused across Actors.
- Private subscriptions do not broadcast business content; results are sent only to authorized connections.
- Clients can cancel a subscription; after a connection closes, the related processes, listeners and timers are released.
- Snapshots require client acknowledgement; each subscription keeps at most one snapshot awaiting acknowledgement, and notifications arriving in the meantime are merged into a pending-refresh flag. If the acknowledgement times out, the subscription is closed.

### FR-06: Races and data recovery

- There must be no unrecoverable update gap between the initial query and the listener being established.
- If a change occurs during a query, a follow-up refresh must be scheduled; the notification must not be dropped permanently.
- At most one query runs at a time for a given subscription; changes arriving during a query are merged into a pending-refresh flag and handled after the current query finishes.
- A given subscription instance uses an increasing send sequence number; an old query result cannot overwrite a newer one.
- A new connection or re-subscription creates a new generation; the client must not apply data left over from an old instance.
- On reconnect, the client re-authenticates, re-establishes subscriptions and reads snapshots, without depending on in-memory state from before the disconnect.
- An explicit refresh is provided, and a periodic re-check finds missed notifications; by default it runs every 30 seconds, configurable.
- Provided the database, job execution and connections are all healthy again, a missed notification should be repaired within one re-check period plus query processing time.
- During a snapshot refresh the previous valid data is kept, but a status field shows that recovery is in progress; it must not be presented as fully synchronized.

### FR-07: Resource control and back-pressure

- Limits are set on subscriptions per connection, result item count, HTTP request body, Socket frame, snapshot size, database statement time and snapshot acknowledgement timeout.
- A slow client does not accumulate an unbounded number of historical snapshots; refresh requests that have not yet been sent can be merged.
- When a connection's send budget is exceeded, an explicit reason is returned and the client is required to reconnect to get the current snapshot.
- The basic limits above are implemented, and per-project request rate and subscription count quotas are provided (counted per node, see [OPERATIONS.md](OPERATIONS.md#project-quotas-fyrletquota)); request rate and global connection quotas for public-facing traffic are supplied by the deployment gateway, and no tenant billing limits are provided.
- The failure of one subscription or operation should not drop all other users' connections.

### FR-08: Observability and developer experience

- Structured logs contain the request ID, the operation or subscription name, duration, error type and an identity identifier that is safe to log.
- Tokens, full bodies and sensitive parameters are not logged by default.
- Active connections, active subscriptions, query counts, snapshot bytes, operation duration, notification latency and job failure counts are recorded.
- "Connection established", "subscription recovering", "subscription ready" and "subscription invalidated" are clearly distinguished.
- A minimal verification page or script is provided that can establish a connection, call operations, and view snapshots and errors.
- The verification script uses the TypeScript SDK directly and covers real HTTP and WebSocket flows.

## Reference business contract

| Name | Type | Input summary | Output summary | Permission |
| --- | --- | --- | --- | --- |
| `inbox.add` | Write | Body, content type | New entry | Can only create for the current user |
| `inbox.update` | Write | Entry ID, body, expected version | Updated entry | Entry owner only |
| `inbox.archive` | Write | Entry ID, expected version | Updated entry | Entry owner only |
| `inbox.delete` | Write | Entry ID, expected version | Deletion result | Entry owner only |
| `inbox.history` | Read | Pagination cursor, count | History entries and next-page cursor | Entries visible to the current user |
| `inbox.recent` | Subscription | Count, whether to include archived | Snapshot of recent entries | Entries visible to the current user |

An entry contains at least a stable ID, owner ID, content type, body, archived status, entry version, creation time and update time.

Lists use a deterministic order, with the stable ID deciding the order when timestamps are equal. Updates, archiving and deletion detect concurrent conflicts through the expected version; after a conflict, the client refreshes and the user decides the next action.

## Protocol requirements

For application-level semantics and the wire format, see [PROTOCOL.md](PROTOCOL.md): the HTTP entry point, the mapping between error codes and status codes, subscription events, ACK and generation / seq rules, delta negotiation, and capability negotiation. The Phoenix transport protocol version, the framework protocol version and the application business contract version are managed separately.

## Consistency and reliability commitments

### Source of truth

PostgreSQL is the source of truth for business data, idempotent success results and pending change notifications. The memory of connection processes and subscription processes is used for scheduling and caching and is not responsible for permanent storage.

### Success semantics

- A successful write means the business transaction has been committed.
- A successful notification publish does not mean all clients have received or displayed the data.
- Receiving a snapshot means that authorized query has completed; it does not mean the data will not change in the future.
- Eventual convergence is provided under healthy operating conditions; it is not promised that all clients see the same database version at the same time.
- No atomically consistent view across multiple subscriptions is provided.

### Failure recovery

- Failure before commit: the transaction is rolled back, and no success result or corresponding change may be published.
- Failure after commit but before notification: the durable job continues after recovery.
- Duplicate notifications: repeated refreshes are allowed, but business writes must not be produced twice.
- Missed notifications: current data is recovered through explicit refresh, reconnect reads and the periodic re-check.
- Service restart: business facts are recovered from the database, and clients re-establish subscriptions.
- Final job failure: the error is recorded and operator retry is supported; the job must not be silently treated as complete.

## TypeScript SDK and mobile boundary

The product name is Fyrlet. SDKs are organized by language under `sdks/<language>/`; the current implementation is in `sdks/typescript/`, with the local package name `@fyrlet/client`. All languages share the protocol and the business contract, and each follows the API conventions of its own language; framework adapters such as React are built on top of the SDK of the language they belong to. Other languages will be added according to actual application needs; for the directory and acceptance conventions, see the [SDK overview](../sdks/README.md).

1. `createClient<Contract>`, `call`, `subscribe`, `reconnect` and `close` are provided, along with session exchange and revocation as a standalone server-side entry point.
2. `getToken({forceRefresh})` is implemented by the host application; the SDK does not store passwords, project service keys or permanent browser tokens. An HTTP 401 triggers at most one refresh, reusing the original idempotency key.
3. Subscriptions expose the connecting / recovering / ready / error / closed states. During recovery the old data is kept and marked not ready; when authentication or permissions become invalid, the data is cleared.
4. The SDK manages snapshot acknowledgement, generation, increasing sequence numbers and re-subscription; after closing, it releases connections, timers and listeners and no longer reconnects automatically.
5. Input and output types for calls and subscriptions are generated from the server contract; the SDK core does not depend on React, DOM state or browser storage.
6. Injecting fetch, WebSocket and a random ID generator is supported, to ease Node and React Native adaptation. Real mobile devices and background lifecycle are not yet verified, so full support must not be claimed.
7. The protocol can be implemented by non-TypeScript clients. Timestamps and UUIDs are strings, numbers are limited to safe integers, and errors carry stable machine codes.

Mobile push, background wake-up and offline writes are out of scope for now. The server does not require clients to keep a long-lived connection permanently.

## Performance goals and verification

Establish a reproducible baseline first, and do not write expected advantages as verified conclusions. For measured results and methods, see [PERFORMANCE.md](PERFORMANCE.md) and [OPTIMIZATIONS.md](OPTIMIZATIONS.md).

### What must be collected

- Connection count, active subscription count, CPU and memory under fixed resources.
- p50, p95 and p99 latency from operation submission to the client applying the snapshot.
- Database query count and bytes sent triggered by each business change.
- Resource changes under concurrent changes to the same Scope, private subscriptions and slow clients.
- Disconnect recovery time, periodic re-check repair time, and resource release after unsubscribing.
- The size of each record and each snapshot, and the single-user and multi-user distributions.

### Load test scenarios

| Scenario | Focus |
| --- | --- |
| Many idle connections | Base connection and heartbeat cost |
| A few users writing frequently | Notification merging, query volume and latency |
| Multiple devices subscribing to the same user's data | Repeated reads and serialization cost |
| Many users with private subscriptions | Overall overhead under permission isolation |
| Slow clients and mass reconnects | Back-pressure, recovery and database pressure |

Record the hardware, runtime versions, database configuration, data set, query range, limits and persistence requirements. Capacity limits and latency SLOs are determined from measurements after implementation; the number of idle connections is not used to represent full business throughput.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Run grows too fast | Maintenance cost; recovery correctness is hard to verify | Optional module, sequential plans, single-execution policy, domain loops first |
| Outbox misread as external deduplication | Business consequences such as duplicate notifications or duplicate charges | Stable business keys, provider capability and validity period declarations; unknown outcomes pause by default |
| Lease expires but the old execution is still running | Duplicate execution or old results overwriting new ones | Increasing epochs and conditional commits; external effects are deduplicated separately by the receiver |
| Cancellation confused with compensation | The UI shows stopped but the external effect still happens | Graded cancellation results, auditing of late results, explicit compensation |
| Wrong append position or history boundary | Lost records, duplicate merges, wrong completeness claims | Base position checks, consistent snapshots, window rules and history truncation declarations |
| Shared subscription scope becomes an authorization-bypass entry point | Private fields leak | Private by default, a separate public projection, complete cache keys, per-member checks |
| A query helper mistaken for database isolation | Authorization bypass on unmanaged paths | State the scope of the guarantee explicitly; strong isolation needs a separate database permission and RLS design |
| Plugin combination and load failures | Cannot recover, or an entry point degrades to allowing access | Dependency readiness checks, entry points closed, a conformance suite running continuously |
| Premature plugin API abstraction | A wrong long-term protocol | Implement first, abstract later (see [PLUGINS.md](PLUGINS.md#seam-principle)) |
| Domain packages driving specialization of the core | The core gets tied to a single product | Domain packages are released independently; the core accepts only general semantics |

---

## Success criteria

- **Usable**: an application outside the repository can install it; a real run-type business completes "start, observe, wait/intervene, cancel, recover"; uncertain external outcomes can be kept and handled accurately; clients that have not declared a capability are unaffected.
- **Reusable**: at least two real domain applications share the public core and capability interfaces, without forking or copying core code. A single demo application running end to end cannot replace this verification.
- **Benefit demonstrable**: shared subscriptions report query and serialization savings, and append subscriptions report bytes and refresh fallback; authorization, slow-client, recovery and history-boundary acceptance is kept alongside. Record the integration steps, business code size, upgrade cost and operational handling cost, so that judgement is not based on feature count alone.
- **Can be turned off**: after an optional capability is turned off, the behavior of applications that do not use it is unchanged; existing jobs must have a drain or pause policy. Connection count, single-request latency, or unverified advantages over other frameworks cannot replace the facts above.

## Open questions

- **Type generation extensions**: the explicit contract is currently the only source of types; an Ash adapter and generators for other languages will be evaluated according to actual needs.
- **Sync layer upgrade**: whether to introduce Phoenix.Sync / Electric depends on correctness tests and the performance baseline.
- **Offline capability**: first define the client cache, expiry and permission revocation semantics, then discuss offline writes and conflict handling.
- **Distributed deployment**: a two-node setup on one machine has been verified; multi-host deployment, network partition recovery and global quotas need separate verification and design.
- **Release and compatibility**: Apache-2.0 and the initial core + TypeScript + React scope are selected; before actual publication, verify registry ownership and decide publication approval, the deprecation period and the supported server / SDK compatibility matrix.
- **Plugin API freeze**: based on actual seams and upgrade feedback, with no date set (see [PLUGINS.md](PLUGINS.md#seam-principle)).

Whether the product holds up depends first on whether the author can use it to complete the first application reliably, and in the second application reduce the repeated authentication, call, subscription and recovery code.
