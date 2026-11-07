# Fyrlet documentation

English | [简体中文](zh/README.md)

Fyrlet is a realtime application framework built on Phoenix: you define business operations, data subscriptions and access permissions on the server, and clients call the business logic and receive realtime, authorized data through a unified protocol and SDK. For the project introduction and quick start, see the [root README](../README.md).

## Understanding the product

| Document | Contents |
| --- | --- |
| [PRODUCT.md](PRODUCT.md) | Product positioning, use cases, scope and non-goals, functional requirements, consistency commitments, risks and success criteria |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Base model, optional modules, the three layers (core / capability package / domain package), authentication layering and hard rules |
| [ROADMAP.md](ROADMAP.md) | Planned milestones, priorities, dependencies, completion criteria and later evaluations |

## Integration and usage

| Document | Contents |
| --- | --- |
| [TUTORIAL.md](TUTORIAL.md) | Connect the Inbox definition, generated types, a backend session endpoint and a browser subscription |
| [INSTALL.md](INSTALL.md) | Installation steps, required configuration, environment variables, public interface list, protocol version and capabilities, automated verification coverage, packaging and example applications |
| [AUTH.md](AUTH.md) | Identity layers, integration flow, authorization and isolation, anonymous principals, execution authorization, data protection |
| [PROTOCOL.md](PROTOCOL.md) | HTTP and Socket protocol, subscriptions and ACK, deltas, capability negotiation, and the wire format of each capability |
| [SDK overview](../sdks/README.md), [TypeScript SDK](../sdks/typescript/README.md) | Multi-language SDK conventions; calls, subscriptions, optimistic writes and presence in the TypeScript SDK |
| [Example applications](../examples/README.md) | Shared preparation, login, verification and boundaries |

## Example applications

| Document | Contents |
| --- | --- |
| [Inbox](../examples/inbox/README.md) | Minimal Mix host, private inbox, Node CLI and live updates |
| [Notify](../examples/notify/README.md) | Notifications, email Effects and delivery reconciliation |
| [Flow](../examples/flow/README.md) | Sequential HTTP / wait nodes, signals and recovery |
| [Agent](../examples/agent/README.md) | Bounded tools, owner approval, rejection and cancellation |
| [Chat](../examples/chat/README.md) | Invitations, shared room state, append messages and history |

## Building your application

| Document | Contents |
| --- | --- |
| [SERVER.md](SERVER.md) | Registering definitions, queries and authorization, Observers, transactions and invalidation notifications, optional callbacks, code organization |
| [MUTATIONS.md](MUTATIONS.md) | Operation outcomes, unknown results and recovery without replay |
| [RUNS.md](RUNS.md) | Durable Runs: state machine, waits and signals, cancellation, leases, external executors, execution identity |
| [EFFECTS.md](EFFECTS.md) | External side effects and Outbox: model, adapter protocol, handling unknown outcomes |
| [STREAMS.md](STREAMS.md) | Append subscriptions: positions, joining, windows, history and reset |
| [SHARING.md](SHARING.md) | Shared subscriptions and declarative data scope |
| [PLUGINS.md](PLUGINS.md) | Capability packages, the plugin API and conformance suite, domain packages |

## Deployment and operations

| Document | Contents |
| --- | --- |
| [DATABASE.md](DATABASE.md) | Table design: conventions, the role of constraints and indexes, cleanup and retention, conventions for host tables |
| [OPERATIONS.md](OPERATIONS.md) | Operations commands, data retention and capacity, project quotas, telemetry and Prometheus metrics, two-node deployment |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Diagnose startup, origins, authentication, subscriptions, conflicts and external Effects |
| [PERFORMANCE.md](PERFORMANCE.md) | Same-resource comparison with Meteor, single-core profiling, shared rooms and append streams compared end to end |
| [OPTIMIZATIONS.md](OPTIMIZATIONS.md) | Optimization log: what was done, evidence, experiments that were reverted, and directions decided against |
| [Benchmarks](../bench/README.md), [Equal-conditions specification](../bench/FAIRNESS.md) | Benchmark tooling and fairness rules for comparisons |

## Status and verification

| Document | Contents |
| --- | --- |
| [STATUS.md](STATUS.md) | Implementation status of each capability; base and capability acceptance matrices |
| [ACCEPTANCE.md](ACCEPTANCE.md) | Verification records: environment, commands, browser and two-node evidence, and what is not yet verified |
