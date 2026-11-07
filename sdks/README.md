# Fyrlet SDKs

English | [简体中文](README.zh-CN.md)

`sdks/` contains client SDKs organized by language. Each SDK builds, tests and releases independently. Only the [TypeScript SDK](typescript/README.md) is currently implemented, with local package name `@fyrlet/client`. The package has not been published, and availability of the npm scope has not been confirmed.

## Directory conventions

```text
sdks/
  README.md
  typescript/
    src/
    scripts/
    examples/
    test/
    package.json
```

Add directories such as `dart/`, `swift/`, `kotlin/` or `python/` when an implementation actually begins. There are no empty SDKs or promised delivery order. Each language controls its dependencies, version and package manager. The server stays at the repository root.

React adapters build on the TypeScript core and may use `typescript/packages/` if independent releases are needed. React Native also reuses that core, adding lifecycle, network recovery and token storage integration. Flutter, native iOS and native Android SDKs belong in their corresponding language directories.

## Shared conventions

All SDKs follow the [business and subscription protocol](../docs/PROTOCOL.md) and consume the same [business contract](../priv/contract.json):

- HTTP operations, identity verification, session exchange and revocation use the same server interfaces. Service keys belong only on trusted backends; clients use short-lived user tokens.
- Realtime subscriptions follow Phoenix Channels and the Fyrlet protocol, including full snapshots, ACK, generation, sequence, resubscription and terminal errors.
- Writes share idempotency, conflict and retry semantics. An unknown commit result must not be reported as a definite failure.
- SDKs bind a project and user. Account changes, revocation and terminal errors must release resources and clear private data.
- APIs follow each language's conventions while preserving semantics. Business types are generated or mapped from the contract rather than maintained as separate definitions.

The protocol, business contract and SDK package have separate versions. `protocol_version` and the contract dialect determine protocol compatibility. Package versions can evolve independently; released SDKs must document their supported compatibility range.

## Acceptance for a new SDK

A new SDK needs installation instructions, examples, unit tests and integration tests against a real Fyrlet service. At minimum, verify operations and errors, idempotent retries, authorization isolation, snapshot ACK, reconnects, token refresh and revocation, stale-message rejection, unsubscribe and resource release after close.

Before implementing a second language, the plan is to extract reusable protocol input/output fixtures and acceptance scenarios from the current tests. Each language runs its own tests without requiring one shared framework.

## Near-term order

Improve browser verification and contract generation in the TypeScript core first. Add React integration, shared-subscription integration and React Native lifecycle verification according to real application needs. Other languages are driven by actual usage rather than maintaining several unverified clients at once.
