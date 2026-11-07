# Capability packages, plugins and domain packages

Extensions come in three kinds. They differ in how they are developed and who maintains them, so they cannot all be understood with the same "plugin" mental model (for the three layers see [ARCHITECTURE.md](ARCHITECTURE.md#three-layers)):

- **Capability packages / plugins**: add parts to the framework (entry points, executors, side-effect adapters) and must follow the plugin protocol.
- **Domain packages**: build a whole vehicle with the framework; they are ordinary applications that depend on Fyrlet, not plugins.
- **Optional core features**: capabilities that change identity, operation kinds or the channel protocol; only the core may define them.

Webhooks and Ops are standalone plugin packages, and HTTP and Email are standalone adapter packages; capabilities that change identity, operations or the channel protocol remain optional core features (anonymous entry point, ingest, HTTP executor, append channel).

## Capability packages

| Capability package | Provides | Core capabilities it depends on | Visible to clients |
| --- | --- | --- | --- |
| `fyrlet_anonymous` | Public read-only subscriptions, public snapshots, separate quota; generates a restricted anonymous principal through the core | Core subscriptions + capability negotiation | Yes (`anonymous_read`) |
| `fyrlet_webhook` | Signature verification, replay protection, durable deduplication and Operation/Signal conversion | Restricted integration subject + idempotency | No |
| `fyrlet_ingest` | Batch ingest; batch atomicity, per-item errors, deduplication and back-pressure | Contract + durable acceptance | Yes (`ingest`) |
| `fyrlet_effect_http` | HTTP/webhook dispatch; deduplication and query capability are declared per target service | Effect | No |
| `fyrlet_effect_email` | Email dispatch; acceptance, delivery and bounce states are distinguished according to provider semantics | Effect | No |
| `fyrlet_executor_http` | HTTP external executor (see [RUNS.md](RUNS.md#external-executor-protocol)); Oban execution belongs to the core Run module and is not a capability package | Run | No |
| `fyrlet_ops` | Bounded status snapshots, threshold alerts, project-level read-only status interface (no graphical panel) | Telemetry | No |

`fyrlet_webhooks` and `fyrlet_ops` are standalone plugin packages, and HTTP / Email are standalone adapter packages; each has its own tests. Anonymous, ingest and the HTTP executor are optional core features. The email package contains a Resend provider that implements `FyrletEffectEmail.Provider`, declaring a 24h idempotency window and queryability; "accepted by the provider" does not mean "delivered", and delivery/bounce enters through reconciliation by querying. Tests use a local HTTP provider simulation; real delivery still needs acceptance with credentials.

## Plugin API

The interface comes from the seams that the built-in capability packages used repeatedly: supervised processes, migration directories, HTTP entry points, contract entries with capabilities, and Oban queues. The `Fyrlet.Plugin` behaviour:

| Callback | Purpose |
| --- | --- |
| `name/0`, `version/0` | Required. The name is lowercase and the version is `MAJOR.MINOR.PATCH`; the name determines the HTTP prefix `/api/v1/plugins/<name>/` |
| `capabilities/0` | New capabilities `%{name => version}`; announced to clients only after loading succeeds |
| `requires/0` | Capabilities depended on (core, or plugins earlier in the order) |
| `children/1` | Supervised processes |
| `migrations/0` | Migration directory (absolute path); may only create new tables prefixed with the plugin name and must not modify or rebuild Fyrlet's tables |
| `definitions/0` | The `Fyrlet.Definition` modules it brings, which go through the same registry validation as other definitions |
| `queues/0` | Oban queues; may only be added, and core queues must not be changed |
| `call/2` | Handles `/api/v1/plugins/<name>/…`, receiving a `Plug.Conn` and the remaining path |
| `public_paths/0` | Paths reachable without credentials; none by default |

The entry point is uniformly `call/2`, contracts enter through `definitions/0`, and workers get their queues through `queues/0`; a plugin's own WebSocket channel is not provided.

Configuration:

```elixir
config :fyrlet, plugins: [MyPlugin, {OptionalPlugin, required: false}]
```

At startup, names, versions, duplicate names, capability conflicts, dependencies, migration directories and contents, and whether the definitions can be loaded are validated. **If a required plugin fails, Fyrlet does not start**; if an optional plugin fails it is isolated: its entry point returns 404, its capabilities are not announced, `mix fyrlet.plugins` reports it as degraded, and it never falls back to an unauthenticated path. Plugins are loaded in configuration order; the one loaded first is kept, and a later one with a duplicate name or a capability conflict is rejected.

## Plugin hard rules and the conformance suite

1. A plugin's official entry points must call the core managed API and execute `authorize`, `run_authorize` and the applicable data scope policy; they must not call business callbacks directly to skip checks.
2. A plugin must not modify core table structures and must not register events or error codes outside the core protocol.
3. A plugin must declare the capabilities it adds; clients discover capabilities through the contract and do not guess from "whether the plugin is installed".
4. Credential-type plugins obtain a restricted principal through the core identity API; they do not forge an Actor or replace business authorization themselves. When a plugin is missing or fails to load, the corresponding entry point is closed, and if a required dependency fails, readiness is blocked.
5. A plugin must pass the `Fyrlet.Conformance.Plugin` suite. **Checks implemented**: declaration shape, name and dependencies, migrations append-only and prefixed, declared capabilities consistent with the contract, the contract containing only `operations`/`subscriptions`, entry points failing closed on invalid credentials, and the process starting and stopping normally. Idempotency, reconnection recovery and capability negotiation downgrade are not generic checks; each plugin proves them with its own tests.
6. Plugin migration namespaces and order are deterministic, and an upgrade and revert plan is provided; while unfinished Runs or unresolved Effects exist, dropping tables as a rollback must not discard execution facts.
7. `mix fyrlet.plugins` outputs the current plugins, versions, capabilities and migration status, as the baseline for production troubleshooting.

A plugin under the same BEAM/database privileges is trusted server-side code. The conformance suite verifies the behaviour of the official paths; it is not an isolation sandbox against malicious plugins, raw SQL or arbitrary host code.

## Seam principle

Implement first, abstract later. The plugin API abstracts only the seams that are used repeatedly into interfaces:

1. At least two capability packages are implemented by **calling the core API directly, with no hooks**;
2. Record the core locations they actually touch;
3. Abstract only the repeatedly used seams into hooks.

The current interface is verified by two packages, Webhooks and Ops, whose runtime code connects only through public interfaces. When the interface freezes depends on upgrade feedback; no date is set. Seams are based on real integration cost, duplicated code and upgrade feedback, to avoid prematurely fixing hooks that have not been verified.

# Domain packages (not plugins)

A domain package is a standalone application that consumes the core and capability packages; it does not register a plugin and does not modify the core.

In one sentence: **a capability package adds parts to the framework; a domain package builds a whole vehicle with the framework.** Building a vehicle needs no approval from the framework authors: a domain package is essentially an ordinary Elixir/Phoenix application that depends on Fyrlet, with its own Ecto schemas, its own `Fyrlet.Definition` modules, its own migrations, and its own routes and UI. It does not register a plugin, does not implement hooks, and does not need to appear on any "officially supported list".

| Domain package | Scope | Framework assumption verified |
| --- | --- | --- |
| `Notify` | Event API, in-app notifications, one external channel, receipts and delivery status | Whether Run + Effect + signals can express retries and unknown outcomes |
| `Agent` | A single business task, limited tools, human approval, run snapshots | Whether the Run loop can be reused without a dynamic DSL or delta |
| `Flow` | Sequential HTTP nodes, waiting for events, run records; trigger scheduling is the application's responsibility | Whether the same Run/Effect API can be reused across domains |
| `Chat` | Web chat, login and invitations, multi-person assignment, human takeover, history, shared room subscriptions | Member authorization, shared queries and the benefit of append streams; no anonymous writable entry point is provided |

Constraints:

- A domain package does not introduce private protocols that the framework cannot express; when a new protocol is needed, go back to core review first.
- Each domain package must provide end-to-end acceptance, proving that the core capabilities it depends on hold under real business.
- A domain package may be released independently or stay in the repository, but it must not share private modules with the core.
- A domain package uses only public APIs and must not fork or copy core code; when a new public seam needs to be added, record why it is actually necessary.

## Who can develop and who maintains

The three layers differ in how they can be developed, so they cannot all be understood with the same "plugin" mental model:

| Role | What they can do | What they must follow | Maintainer | Impact of core upgrades |
| --- | --- | --- | --- | --- |
| Framework author | Core, protocol, plugin API | — | Project maintainers | — |
| Capability package author | Add parts to the core: entry points, executors, side-effect adapters | Plugin protocol, fail-closed, conformance suite | Capability package author | **High**: changes to plugin hooks break capability packages |
| Domain package author | Build a whole vehicle with the framework: domain model, tables, business definitions, UI | Depend only on public APIs and the protocol | Domain package author, fully independent | **Low**: affected only by breaking changes to the protocol and public APIs |
| Application developer | Write definitions and subscriptions in their own project | Same as above | Themselves | Low |

Key points:

1. **A domain package needs no registration and no framework review.** Anyone with a Fyrlet dependency can write, publish and privately maintain their own domain package; the framework maintainers are not responsible for developing or maintaining them.
2. **The bar for a capability package is different.** It must connect to the plugin API, pass the conformance suite and obey fail-closed; the number of such extensions should be kept deliberately small, and the core needs to keep a compatibility window for them.
3. **The framework authors' real responsibility is to state the boundary clearly**: which APIs are public, which modules are internal, and how `protocol_version` / `contract_version` / `capabilities` evolve. Without this boundary, third-party domain packages would break on every upgrade, and no ecosystem could form.
4. **The security of a domain package is the author's responsibility.** `authorize/3` and domain filtering are written in the domain package; the framework guarantees that the official managed paths run the checks at the specified points, while the business author remains responsible for the correctness of policy, unmanaged Repo calls and public projections. The conformance suite cannot prove that arbitrary business code will never leak data.
5. **A distribution and compatibility baseline must be established first.** Third parties need a clearly pinned-version source dependency, a list of public modules, a migration entry point and an SDK installation method. A minimal application outside the repository must be able to install, migrate and run (see [INSTALL.md](INSTALL.md)); the examples in the repository working is not enough to count integration as done.

There is only one dividing line between domain packages and the plugin ecosystem: **when a capability the core lacks is needed, a domain package cannot modify the core itself** — either build it as a capability package (through the plugin protocol), or go back upstream and change the core. A domain package only consumes and does not extend.

---

## Reuse verification record

The four standalone Mix applications each contain their own Ecto schemas, migrations, configuration and tests, and their web pages connect through an ordinary host Plug. Shared web assets are in `examples/support`, use the real TypeScript SDK, and do not depend on a CDN; service keys never enter the pages. Domain definitions use the public Run, Effect, Scope and Stream interfaces, and tests drive recovery and manual jobs through `Fyrlet.Testing` without calling the core Engine / Recovery directly.

Notify saves notifications with managed commits and updates the in-app list through a Resend email Effect and reconciliation by querying; Flow saves owner-private flow definitions, uses Effects for sequential HTTP nodes and signals for wait nodes, and continues after a restart; Agent saves results of limited tools and requires the owner to explicitly approve/reject; Chat saves rooms, members and messages, the public room projection shares a query, messages use append, and the full history goes through pagination separately. Eight real-server acceptance scenarios cover these loops and isolation/revocation, and the source package is unpacked outside the repository to run the Inbox and Agent installation acceptance.

The public seams added after integration are `Transaction.run/1` (notify after nested managed commits), `HTTP` (host/plugin responses), `Diagnostics` (trusted aggregated operations queries), `Testing` (host test driving) and `Runs.scope/1` (domain lists update with Run status). They arose from actual reuse needs of applications or plugins. Flow still implements no branching, loops or cross-node data passing; Chat provides no anonymous writes; Agent does not represent a model or RAG platform; each one's startup steps and boundaries are in the application README.
