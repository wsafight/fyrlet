# Fyrlet SDKs

English | [简体中文](README.zh-CN.md)

`sdks/` contains client SDKs organized by language. Each SDK builds and tests independently. The initial formal release scope is the Fyrlet core, [TypeScript SDK](typescript/README.md) (`@fyrlet/client`) and [React adapter](react/README.md) (`@fyrlet/react`). The [Python](python/README.md) (`fyrlet`), [Go](go/README.md) (`github.com/wsafight/fyrlet/sdks/go`), [Swift](swift/README.md) (`Fyrlet`), [.NET](dotnet/README.md) (`Fyrlet`), [Rust](rust/README.md) (`fyrlet`), [Java](java/README.md) (`com.fyrlet:fyrlet`) and [Kotlin](kotlin/README.md) (`com.fyrlet:fyrlet-kotlin`) SDKs remain **experimental**: they continue their build/integration checks but are not part of the initial publication or its compatibility promise. They cover session exchange, operations with idempotency and recovery, and recoverable subscriptions; Runs, append, presence, optimistic writes and Socket RPC are TypeScript-only for now. No package has been published yet, and registry ownership/scope availability remains an external release gate.

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
  react/         independent React adapter, hooks and lifecycle/SSR tests
  python/        pyproject.toml, src/, tests/, examples/
  go/            go.mod, *.go, examples/
  swift/         Package.swift, Sources/, Tests/, Examples/
  dotnet/        Fyrlet.sln, src/, tests/, examples/
  rust/          Cargo.toml, src/, tests/, examples/
  java/          pom.xml, src/, examples/
  kotlin/        pom.xml, src/, examples/
```

Add directories such as `dart/` or `flutter/` when an implementation actually begins. There are no empty SDKs or promised delivery order. Each language controls its dependencies, version and package manager. The server stays at the repository root.

The independent [React adapter](react/README.md) builds on the TypeScript core and ships separately as `@fyrlet/react`. The [Suiji](../examples/inbox-react/README.md) exercises its hooks with OIDC login. React Native also reuses the core, adding lifecycle, network recovery and token storage integration. Flutter, native iOS and native Android SDKs belong in their corresponding language directories.

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

React integration, typed Presence contracts, optional retries and the OIDC Inbox example are implemented locally. Further browser/runtime work, including React Native lifecycle verification, follows actual application needs. Other languages are driven by actual usage rather than maintaining several unverified clients at once.
