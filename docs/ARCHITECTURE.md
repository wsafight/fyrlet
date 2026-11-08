# Architecture and extension principles

## Base model

The central abstraction of Fyrlet is:

> **One authorized query → one complete snapshot → one transactional write → one business result.**

The base model consists of **Operation** (one request, one transaction, one result) and **Subscription** (authorized query, complete snapshot, ACK). Multi-device products that need realtime capabilities (customer support conversations, notification delivery, monitoring, workflows, Agent runs) often also involve long-running work, external side effects, continuously appended output, multi-person groups and public entry points. These are expressed through **optional** modules rather than by changing the base model:

- **Run + Effect**: durable tasks that must recover across requests and processes, and external side effects with explicit delivery semantics, see [RUNS.md](RUNS.md) and [EFFECTS.md](EFFECTS.md).
- **Append subscriptions**: continuously appended ordered records, see [STREAMS.md](STREAMS.md).
- **Shared subscriptions and managed data access**: see [SHARING.md](SHARING.md).
- **Anonymous entry, batch ingestion, webhooks, external executors and so on**: see [PLUGINS.md](PLUGINS.md).

Ordinary reads, writes and subscriptions do not need to create a Run. Every optional capability becomes visible to a client only through [capability negotiation](PROTOCOL.md#capability-negotiation).

## Three layers

| Layer | Content | Can be a plugin | Criterion |
| --- | --- | --- | --- |
| **Core** | Contract, identity, authorization enforcement points, transactional writes, idempotency, snapshot subscriptions; the protocol and state invariants of the official optional Run/Effect modules | The core guarantees cannot be replaced; optional modules are enabled by capability | Defines "what is guaranteed", and does not require every application to enable every module |
| **Capability package** | Anonymous/webhook/ingest entry points, side effect adapters, execution strategies, quota and observability integrations | **Yes** | Adds entry points or execution methods through public interfaces without weakening declared guarantees |
| **Domain package (starter kit)** | Chat, notifications, workflows, Agent runs | Not a plugin, a standalone application | Only consumes the framework (definition + migration + UI) and does not extend it |

The protocol is defined by the core, which is not the same as the implementation having to live in the core. Run/Effect can be organized independently and loaded on demand, but once enabled they must obey the same state machine, authorization and compatibility rules.

## Code and test boundaries

`lib/fyrlet` contains framework logic, `lib/fyrlet_web` contains HTTP and Channel entry points, `packages` contains extensions, `examples` contains domain applications, and `sdks` contains clients. Internal modules are separated by responsibility. Before launch, interfaces may be replaced with coordinated changes to the server, SDK and examples.

`Fyrlet.Definition` remains the application behaviour and documents optional callbacks by feature. `Fyrlet.Definition.Validation` owns startup contract and feature validation; `Fyrlet.Registry` owns indexing, lookup and export. Shared subscriptions and Runs both read definition versions through `Fyrlet.Definition.current_version/2`, so shared subscriptions do not depend on the Run implementation resolver.

`Fyrlet.Transaction` and `Fyrlet.AfterCommit` own the common transaction boundary. Invalidations raised through `AfterCommit` persist a job within the transaction; the write path of Operations does so only with `durable_invalidation: true` (see [OPERATIONS.md](OPERATIONS.md)). Immediate broadcasts and telemetry are released after the outermost managed transaction commits. Rollbacks clear pending work. `Fyrlet.Runs.Notify` builds Run notification scopes and delegates to the core, so common transaction handling does not depend on Runs.

In the TypeScript SDK, `client.ts` owns identity, connections, reference-counted query handles and channel lifecycles; `query.ts` canonicalizes shared-query parameters; `requests.ts` owns request deadlines, cancellation and one authentication refresh; `subscription.ts` owns snapshot, delta, append, Presence, predictions and correlated view confirmation. Subscription state handling returns requests for ACKs, refreshes or reconnection, and the client performs the network operations.

`FyrletWeb.ChannelSupport` owns shared Channel mechanics: identifier validation, error envelopes, anonymous capability checks, quota claims, timer scheduling and cleanup, and snapshot serialization. Each Channel keeps its authorization order, event handling and backpressure policy. The SDK shares the acknowledged push path for refresh and Presence updates; Presence extends its registered subscription handle so ownership checks and optimistic updates use the same handle.

`Fyrlet.Subscriptions.Observation` maintains the subscription state machine. A private subscription embeds it in its Channel process; explicitly shared subscriptions host the same state machine in an Observer process. Private channels keep the normalized View for incremental updates and discard serialized snapshot bodies after delivery. Shared Observers cache encoded bodies for reuse across members. Each view retains authorization checks, revision, reconciliation and notification deduplication; each Channel retains its generation, sequence and ACK deadline.

The root `mix test` uses dedicated definitions, records and migrations under `test/support` without compiling example sources. Inbox archive, pagination and incremental window tests run under `examples/inbox/test` and are maintained separately. `scripts/test_all.sh` runs the framework, example and extension suites in sequence. Run SDK checks separately with `npm --prefix sdks/typescript test` and `npm --prefix sdks/typescript run typecheck`.

## Authentication boundaries

"Authentication" is not a module that can be placed as a whole. Putting it entirely in the core or entirely in capability packages would both be wrong, so it is split into four parts:

| Component | Belongs to | Reason |
| --- | --- | --- |
| **Identity and session**: user Actor, short-lived token, and the restricted principal types needed by new entry points | Core | Uniform construction, verification and revocation |
| **Authorization enforcement points**: before an operation, before a snapshot is sent, periodic re-check, managed queries and background execution entry points | Core | All official paths must perform the checks, and access is denied when a policy is missing |
| **Business authorization rules**: `authorize/3`, `run_authorize/4`, `data_scope/3`, execution authorization policy | Application (definition) | The core calls them at the specified times; the business is responsible for the correctness of policy and domain filtering |
| **Credential schemes of new entry points**: anonymous identity, webhook signatures, executor credentials, external IdP | Capability package | After verifying the credential, obtains a principal restricted in project and permissions through the core identity API |

Key constraints:

1. **Credential adaptation and business authorization are separate.** A plugin verifies credentials and calls the core identity API; it must not construct a trusted Actor directly from the subject/project fields in a request, and it cannot replace business authorization.
2. **Credential plugins must fail closed.** When missing, misconfigured or failing to load, their entry points are unavailable and must not fall back to an unauthenticated path. A failing required plugin should block readiness; a failing optional plugin may isolate its entry point and report a degraded state.
3. **Background execution does not reuse an expired user token.** The permissions of the initiator, the executing principal and the viewer are handled separately, see [RUNS.md](RUNS.md#execution-identity-and-code-version).

## Hard rules

1. **Plugins only add.** They may add entry points, execution methods and adapters; they must not replace snapshot authority or bypass the official authorization path. Reuse of private query results across Actors is forbidden by default; the only sharing exception is the [explicitly declared public result projection](SHARING.md#shared-subscription-scope).
2. **Client-visible semantics are defined only by the core.** New events, new states and new error codes are brought into the protocol by the core and exposed through capability negotiation; plugins must not extend the client protocol on their own.
3. **Domain packages are not plugins.** Domain models, table structures and UI belong to the application, and are released and tested independently.
4. **Implement first, abstract later.** The plugin API is not frozen until the seams have been validated by at least two real implementations (see [PLUGINS.md](PLUGINS.md#seam-principle)).
5. **Optional capabilities are off by default.** All new capabilities are optional and can be turned off; a client that has not declared a capability never receives any event related to it.
6. **Guarantees must be scoped.** State commits, task execution, external side effects and history retention each declare their own guarantees; query helpers or consistency tests are not described as a security sandbox for arbitrary business code.

## Architecture overview

```text
┌─────────────────────────── Client (SDK / custom) ───────────────────────────┐
│  call / subscribe(snapshot) / subscribe(delta) / startRun / signal / cancel │
└───────────────────────────────────┬────────────────────────────────────────┘
                                    │  capability negotiation (contract.capabilities)
┌───────────────────────────────────▼────────────────────────────────────────┐
│ Core and official optional modules                                          │
│  Contract/validation · identity/session · authorization points · writes    │
│  Optional: Run / Effect · delta channel · shared scope; managed data access │
└───────┬──────────────────────────┬──────────────────────────┬──────────────┘
        │                          │                          │
┌───────▼─────────┐      ┌─────────▼──────────┐     ┌─────────▼─────────┐
│ Capability pkgs │      │ Executors          │     │ Domain packages   │
│ Anonymous/Webhook│     │ Oban / built-in    │     │ Chat / notify /   │
│ Ingest/adapters │      │ External worker    │     │ workflow / Agent  │
└─────────────────┘      └────────────────────┘     └───────────────────┘
```
