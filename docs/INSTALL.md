# Installation and public interface

Fyrlet is a server-side dependency: the host application adds it as a dependency and registers its own business definitions (`Fyrlet.Definition`); Fyrlet provides contracts, identity, transactional writes, idempotency and realtime subscriptions. [examples/inbox](../examples/inbox) in this repository is a standalone Mix project that uses Fyrlet only through the entry points listed in this document; its tests are the installation acceptance.

The source has not been published to Hex, and the SDK has not been published to npm. You can use a source dependency pinned to a commit, or a local distribution package (see "Packaging and installation acceptance" below):

```elixir
{:fyrlet, git: "…", ref: "<commit>"}      # Or a local dependency: path: "../fyrlet"
```

## Installation steps

1. **Dependency**: see above. Fyrlet ships its own `Fyrlet.Repo`, `FyrletWeb.Endpoint` (on a separate port) and Oban, which start with the application.
2. **Configuration**: the `config/*.exs` files inside a dependency are not loaded by the host. The host writes the "Required configuration" below in its own `config/config.exs` and calls `Fyrlet.RuntimeConfig` in `config/runtime.exs`.
3. **Business definitions**: implement `Fyrlet.Definition` and register it under `definitions`.
4. **Migrations**: put the host's migration directory in `migration_paths`, and run all Fyrlet and host migrations at once with `mix fyrlet.migrate --create`. In a release, use `bin/app eval "Fyrlet.Release.migrate()"`.
5. **SDK**: build `@fyrlet/client` from source, or install the local `.tgz`; export the contract with `mix fyrlet.contract priv/contract.json`, then generate types with `sdks/typescript/scripts/generate.mjs`. The four web applications embed the SDK at compile time, so first run `npm --prefix sdks/typescript ci` and `npm --prefix sdks/typescript run build`.

### Required configuration

`config/config.exs` (for key names and values see [examples/inbox/config/config.exs](../examples/inbox/config/config.exs)):

| Key | Meaning |
| --- | --- |
| `ecto_repos: [Fyrlet.Repo]` | Lets the `ecto.*` tasks find the repository |
| `definitions: [MyApp.Definition]` | Business definition modules |
| `migration_paths: [{:my_app, "priv/repo/migrations"}]` | Host migration directory |
| `session_ttl`, `max_subscriptions`, `max_snapshot_bytes`, `max_channel_queue`, `snapshot_ack_timeout`, `reconciliation_interval`, `max_observers`, `observer_hibernate_after`, `channel_hibernate_after`, `socket_batch_max_messages`, `socket_batch_max_bytes`, `idempotency_ttl`, `batch_session_checks`, `capabilities` | Runtime limits and switches; all must be given (the example uses the recommended defaults) |
| The `Fyrlet.Repo`, `Oban` and `FyrletWeb.Endpoint` sections | Connection pool, queues and pruner, endpoint |
| `config :logger, level: :info` (non-test environments) | Production log level. A dependency's own config files are not loaded, and a release defaults to `:debug`, which formats and writes **every SQL statement**: under the same load this measured about 26% more CPU (see "End-to-end re-measurement" in [OPTIMIZATIONS.md](OPTIMIZATIONS.md)) |

`config/runtime.exs`:

```elixir
import Config
config :fyrlet, Fyrlet.RuntimeConfig.settings(config_env())
```

The node-wide channel ceiling can be set with `FYRLET_MAX_SUBSCRIPTIONS_PER_NODE` (1–1,000,000; default 10,000). It includes ordinary subscriptions, append and Presence; see [capacity limits](OPERATIONS.md).

Environment variables: `DATABASE_URL`, `POOL_SIZE`, `PORT`, `PHX_SERVER`, `CORS_ORIGINS`. Numeric variables must be integers within range (`POOL_SIZE` 1–10000, `PORT` 1–65535); otherwise startup fails and names the variable. Each entry of `ALLOWED_ORIGINS` and `CORS_ORIGINS` has leading and trailing spaces removed; under `:prod`, `SECRET_KEY_BASE` and `ALLOWED_ORIGINS` are required. When the web pages and the API share an origin, that origin is allowed automatically; other origins still need explicit `CORS_ORIGINS` configuration. Optional project quota defaults: `FYRLET_PROJECT_READS_PER_SECOND`, `FYRLET_PROJECT_WRITES_PER_SECOND`, `FYRLET_PROJECT_MAX_SUBSCRIPTIONS` (see [OPERATIONS.md](OPERATIONS.md#project-quotas-fyrletquota)). Optional default retention period for ingested data: `FYRLET_INGEST_RETENTION_SECONDS` (a number of seconds, at least 60, or `forever`; see [DATABASE.md](DATABASE.md#per-project-retention)). Optional `FYRLET_METRICS_TOKEN` (enables `GET /metrics`, see [OPERATIONS.md](OPERATIONS.md#prometheus-metrics-fyrletmetrics)). Optional `FYRLET_CLUSTER_NODES` is a comma-separated list of `name@host`, at most 32; once configured, Erlang named nodes must be enabled with the same cookie. For deployment and tuning see [OPERATIONS.md](OPERATIONS.md).

### Shared repository constraints

Fyrlet and the host share one `Fyrlet.Repo`. This is deliberate: business writes, idempotency records and invalidation notification jobs must commit in the same transaction. The host's business tables therefore live in this repository too, and it is recommended that they carry the same composite foreign key as Fyrlet's own tables, `(subject_id, project_id) → subjects(id, project_id)`, so that a record's subject belongs to the same project (the example migration shows how). Having the host use its own `Repo` is currently not supported. For the table structure and the conventions for host tables see [DATABASE.md](DATABASE.md).

To combine host writes and managed Run calls in one transaction, use `Fyrlet.Transaction.run/1` as the outermost boundary. Nested calls join the outer transaction; Run notifications and run telemetry are emitted after the outer transaction commits and are discarded on rollback. Do not wrap it in another plain `Repo.transaction/1`. The callback's return value is the result as is, and `Repo.rollback(reason)` returns `{:error, reason}`.

### Host web routes

Configure `config :fyrlet, host_router: MyApp.Web`, where the module implements the Plug `init/1` and `call/2`. A request reaches the host router only when no core or plugin route matches; if it is not configured, 404 is returned. The host handles authorization and caching of web pages and static assets itself; the shared host router of the four web applications is in `examples/support` and is not a plugin. Plugins are still loaded through the `plugins` configuration.

## Public interface

The host may depend on the following modules and tasks; breaking changes to them are announced with the protocol or contract version. Modules not listed are internal implementation and may change at any time.

| Public | Description |
| --- | --- |
| `Fyrlet.Definition` | Business definition callbacks: `contract/0`, `authorize/3`, `execute/3`, `scope/3`, and optionally `change/4`, `load_subscription/3`, `update_subscription/5` |
| `Fyrlet.Schema` | Contract schema construction and validation (`object/2`, `validate/2`) |
| `Fyrlet.Error`, `Fyrlet.Actor` | Error and caller structures |
| `Fyrlet.Subscriptions.View` | The view structure received and returned by `update_subscription/5` |
| `Fyrlet.Auth` | Projects and service keys, issuing/revoking sessions, authentication |
| `Fyrlet.Runtime` | `call/4`, `prepare_subscription/3`, `view/4`, `snapshot/2` (in-server calls and tests) |
| `Fyrlet.Registry` | `export/1`, `validate!/0` |
| `Fyrlet.Runs`, `Fyrlet.Runs.Privacy` | Runs: `operation/2`, `start_output/0`, `get/2`, `signal/3`, `cancel/2`, `revoke_grant/2`, integration signal `signal_from_integration/3`; `scope/1` returns the subscription scope invalidated by changes to that subject's Runs; purge with `purge_subject/2` |
| `Fyrlet.Effects`, `Fyrlet.Effects.Adapter` | Side effects: `receipt/4`, `resolve/5`, the adapter behaviour (the HTTP and email adapters are standalone packages under `packages/`) |
| `Fyrlet.Features.Executors`, `Fyrlet.Runs.Executor` | External executor credentials and protocol |
| `Fyrlet.Scope` | Managed data access |
| `Fyrlet.Features.Ingest`, `Fyrlet.Features.Anonymous` | Ingest, anonymous read-only entry point |
| `Fyrlet.Features.Stream` | In-transaction `append/3`, window reads, `reset/2`, `prune/2`; a subscription selects a stream with `stream/3` |
| `FyrletWebhooks` | Plugin entry point of the standalone `fyrlet_webhooks` package and the `sign/3` signing helper |
| `Fyrlet.Transaction` | The `run/1` transaction boundary that combines managed calls with host writes |
| `Fyrlet.HTTP` | JSON response helpers `result/2`, `success/2`, `error/2,3` for hosts and plugins |
| `Fyrlet.Diagnostics` | Trusted server-side aggregation: `runs/3`, `effects/3`, `limits/1`, `plugins/1`; `cluster/0` returns this node and the configured/connected nodes. The project is chosen by the authenticated context; `:all` is for deployment operations only |
| `Fyrlet.Testing` | Test helpers: create projects/users, `snapshot/3`, `step/1`, `recover/0`, `drive/2`, `effects/1`, `wait_step/1`, lease/wait fault simulation; used with the Ecto Sandbox and manual Oban |
| `Fyrlet.Vault`, `Fyrlet.EncryptedMap` | Optional encryption at rest |
| `Fyrlet.Plugin`, `Fyrlet.Conformance.Plugin` | Plugin interface and conformance suite |
| `Fyrlet.Capabilities` | Capability declaration and negotiation |
| `Fyrlet.Repo` | The repository shared with Fyrlet |
| `Fyrlet.RuntimeConfig`, `Fyrlet.Migrator`, `Fyrlet.Release` | Configuration, migration and release helpers |
| `mix fyrlet.migrate` / `fyrlet.contract` / `fyrlet.prune` / `fyrlet.project` / `fyrlet.revoke` / `fyrlet.runs` / `fyrlet.effects` / `fyrlet.plugins` / `fyrlet.ops` | Operations tasks; `fyrlet.ops` is provided by the standalone Ops package |
| HTTP `/api/v1/*`, WebSocket `/socket` | Wire protocol, see [PROTOCOL.md](PROTOCOL.md) |

Internal (do not depend on them directly): `Fyrlet.Subscriptions.Observer`, `Fyrlet.Subscriptions.SessionChecks`, `Fyrlet.Subscriptions.Tracker`, `Fyrlet.Subscriptions.Delta`, `Fyrlet.Subscriptions.RecordIndex`, `Fyrlet.InvalidationWorker`, `Fyrlet.PruneWorker`, `Fyrlet.Runs.Engine` / `Store` / `Recovery` / `Dynamic` / `Plan` / `Resolver` / `Worker`, `Fyrlet.Effects.Worker`, `FyrletWeb.*`.

## Protocol version and capabilities

| Dimension | Rule |
| --- | --- |
| Protocol version | `protocol_version` is currently only `1` and must be supplied when joining the channel; any other value returns `UNSUPPORTED_VERSION` |
| Contract | Exports every entry the server can provide and lists the enabled capabilities; entries that depend on a capability appear only when that capability is enabled |
| Capabilities | A connection may declare `capabilities` when joining (`{name: version}` or an array of names); what is enabled is the intersection with the server, with the lower version taken; a subscription that uses a dependent capability without declaring it gets `UNSUPPORTED_CAPABILITY` (HTTP 400) |
| Definitions | A definition that implements only the base callbacks can be registered; the other callbacks are required only for operations that declare the corresponding kind |
| Database | Migrations are append-only; a revert must not discard in-progress execution facts |

### Automated verification coverage

| Content | Verification |
| --- | --- |
| The type generator reads the checked-in contract and rejects other protocol versions | `sdks/typescript/test/unit.test.mjs` (reads `priv/contract.json`) |
| SDK business calls and subscriptions | 9 real HTTP / WebSocket scenarios in `scripts/integration.sh` |
| SDK Run / append paths | 4 real-server scenarios in the same script, including signals, restart recovery, isolation and windows |
| A connection that has not negotiated a capability receives no capability events; one that has negotiated gets the negotiation result | `test/fyrlet_web/capability_channel_test.exs` |
| Negotiation rules, contract export, enablement validation of `run` operations | `test/fyrlet/capabilities_test.exs` |
| Installing, migrating and running an application outside the repository | `scripts/install_smoke.sh` unpacks outside the repository, runs the Inbox / Agent tests, and installs the SDK `.tgz` in a separate npm consumer |
| Real business loops of the four web applications | 8 HTTP / WebSocket scenarios in `scripts/domains.sh` (including static assets and the browser SDK without a CDN) |
| Browser interaction and layout of the four applications | `scripts/browser.sh`: desktop, Android Chromium emulation and iPhone WebKit emulation, 12 flows in total, with screenshots saved and horizontal overflow checked |
| Same-machine two-node notification and recovery | `scripts/cluster.sh`: shared/append, idempotency, cross-node revocation, failover, approval recovery and 120 seconds of sustained traffic; the report includes session renewal and resource cleanup |

## Packaging and installation acceptance

```sh
bash scripts/package.sh
bash scripts/install_smoke.sh
```

Packaging first runs the SDK type check and unit tests, then produces `.local/releases/fyrlet-source-0.1.0.tar.gz`, `fyrlet-client-0.1.0.tgz` and a `manifest.json` with sizes and SHA256. The source package contains the core, domain applications, capability packages, documentation and verification scripts, and excludes dependencies, build caches and local credentials. Installation acceptance unpacks into a separate temporary directory, reuses the already downloaded Elixir dependencies and TypeScript toolchain, and then runs the host tests; the npm consumer actually installs its dependencies from the `.tgz`. This verifies the distributed contents and path dependencies; it is not the same as an offline installation or a registry release.

After unpacking the source package into a fixed directory, the host uses `{:fyrlet, path: "/path/to/fyrlet"}`; the SDK uses `npm install /path/to/fyrlet/fyrlet-client-0.1.0.tgz`. `private: true` is kept; the Hex/npm release and the licence decision still have to be made by the maintainers.

## Example applications

| Directory | Contents | Verification |
| --- | --- | --- |
| `examples/inbox` | Reference business: a personal inbox with a delta window | `cd examples/inbox && mix test` (also the installation acceptance) |
| [`examples/notify`](../examples/notify/README.md) | Notification model, in-app list, Resend email provider, Run status and web page | `cd examples/notify && mix test` |
| [`examples/flow`](../examples/flow/README.md) | Private flow storage, sequential HTTP / wait nodes, run records and web page | `cd examples/flow && mix test` |
| [`examples/agent`](../examples/agent/README.md) | Limited text tools, human approval, task model and web page; no LLM is connected | `cd examples/agent && mix test` |
| [`examples/chat`](../examples/chat/README.md) | Login sessions, member invitations, assignment, human takeover, history, shared and append web chat | `cd examples/chat && mix test` |

They all reference the main library as a path dependency and use their own configuration and database. An application that uses Runs adds `capabilities: %{"runs" => 1}` to `config :fyrlet`; one that uses presence (room members and "typing") adds `"presence" => 1` and declares a `presence` section in the definition's contract (see "Presence" in [PROTOCOL.md](PROTOCOL.md)); one that uses side effects registers the adapter `effect_adapters: %{"http" => FyrletEffectHTTP}` (depending on `{:fyrlet_effect_http, path: "…/packages/fyrlet_effect_http"}`) and configures `config :fyrlet_effect_http, allowed_hosts: […]` (the allowed hosts) and `config :fyrlet, :effect_secrets`.

For how to start the four applications, log in through the browser and what their functional boundaries are, see their own READMEs. Sending real email requires `RESEND_API_KEY` and a verified `MAIL_FROM`; this repository verifies the protocol with a local provider simulation, and there is no external real-delivery acceptance. All domain definitions and tests call through the public entry points, and plugin runtime code connects to the core through public interfaces such as `Transaction`, `HTTP` and `Diagnostics`.

For the reproduction steps, evidence and remaining environment requirements for the browser, two-node and real-email checks see [ACCEPTANCE.md](ACCEPTANCE.md). The real-email tool `scripts/mail_live.sh --check` only checks the configuration; a normal run additionally requires `MAIL_TO`, sends one acceptance email to that address and waits for the provider to confirm delivery.

**Migration note:** the project has not been released, and the core migrations have been merged into one (`priv/repo/migrations/20261106000000_create_fyrlet.exs`, including Oban's tables). If your development database ran earlier migrations, recreate that database.
