# Data scope and shared subscriptions

By default each Actor queries independently, is authorized independently and receives its own snapshot. This document describes two independent optional mechanisms:

- **Shared subscription scope**: when the result seen by the members is byte-for-byte identical, the identical query and serialization are merged.
- **Declarative data scope**: a managed query builder reduces missed filters.

There is also a narrower kind of sharing: a subscription declared with `"shared": true` in the contract shares one Observer only among **multiple devices of the same session**, see [SERVER.md](SERVER.md#observers-and-sharing-boundaries). It is mutually exclusive with `sharing: "identical"` below.

## Shared subscription scope

Current state: each Actor queries, generates and receives snapshots independently. The goal of the sharing optimization is to merge identical queries and body serialization; per-member authorization and network sending remain.

Shared subscriptions are **explicitly declared**, and only for scenarios where "the members' results are identical":

```elixir
# Subscription declaration in the contract ("identical" and "shared" are mutually exclusive)
"room.recent" => %{"sharing" => "identical", "input" => ..., "output" => ...}

# The definition must implement:
def shared_query(name, %{project_id: _, scope: _}, params)  # does not receive the Actor
def membership(name, actor, params)                          # :member | :not_member
def policy_version(name)                                     # optional: increment when the authorization policy changes
```

The cache key is project, definition module, subscription name, normalized parameters, Scope, projection version (`definition_version/1`) and authorization policy version (`policy_version/1`). The shared Observer holds no Actor. Each member re-runs the session re-check, `authorize/3` and `membership/3` **on joining**, **before every data send**, **on periodic reconciliation**, and when a `:membership_changed` message is received; a member that fails is terminated immediately with `FORBIDDEN`, and a cache hit grants no read permission. After a membership change, sending `:membership_changed` to the corresponding Observer triggers an immediate re-check; otherwise it is found at the latest on the next reconciliation or the next send. The telemetry event `fyrlet.scope.shared` reports the member count. `sharing: "masked"` is not provided.

The default is `sharing: :private`. When `:identical` is enabled, the separate `shared_query/3` public projection path must be used, rather than caching one member's private query result:

- The query receives only the subscription name, normalized parameters and the trusted Scope context, not an individual Actor; for the same shared key the result is byte-for-byte identical for all recipients;
- Membership is given by the `membership/3` callback: `:member | :not_member`;
- The result contains no member-private fields; the public field allowlist and project filtering are provided explicitly by the domain definition;
- Sharing is a trusted business declaration, not an automatic proof by the framework that arbitrary business logic is equivalent. Consistency tests cover member differences and over-privilege counterexamples.

Here a public projection means a result visible in common to the members within the Scope; anonymous access is still decided by the separate entry point and authorization policy.

How it works:

1. The cache key contains at least project, subscription name, normalized parameters, Scope, data version, projection version and authorization policy version; concurrent queries with the same key are merged, and cache capacity and lifetime are bounded.
2. Before sending, the session re-check, `authorize` and `membership/3` are run for each member; a member that fails has its subscription terminated. A shared hit grants no read permission and does not skip the periodic re-check.
3. Changes in members, permissions or data all trigger invalidation; the periodic check compensates for missed notifications. The race between member removal and a cache hit must have an acceptance case.

`sharing: :masked`, which would trim the shared body per member, is not provided. Use a private subscription when members differ. Capacity conclusions report database queries, serializations, membership checks and network bytes separately; it is not claimed that the number of sends grows with the Scope rather than with the member count.

## Declarative data scope

This capability is first delivered as a managed data access tool to reduce missed filters; it does not promise to constrain arbitrary Repo/SQL calls inside the process. A new optional policy callback:

```elixir
@callback data_scope(action :: :read | :write, actor, input) ::
            {:ok, keyword()} | :unsupported
```

Used together with the query builder provided by the framework:

```elixir
Fyrlet.Scope.apply(query, actor, module, action, input)
```

Guarantee boundaries:

1. A managed path must inject a project constraint that cannot be overridden by input, plus the subject or member constraint declared by the policy. When the policy returns `:unsupported`, the managed operation is rejected and must not fall back to an unfiltered query.
2. Managed reads, updates, deletes and inserts have separately defined constraints; the project ownership field is written from the trusted context. Only verifiable query shapes are supported; unsupported joins, raw SQL or query fragments are explicitly rejected.
3. Paths that use `Repo` directly are not constrained, and the business is still responsible for database filtering. A helper that merely calls `Scope.apply` cannot be described as enforcing isolation on all database access.
4. When database-level tenant isolation is needed, design RLS, database roles and connection context separately; until those mechanisms are delivered, the promise that "no query can exceed its authority" is not used.
