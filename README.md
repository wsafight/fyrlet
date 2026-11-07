# Fyrlet

English | [简体中文](README.zh-CN.md)

A realtime application framework built on Phoenix. Define named business operations and subscriptions in Elixir; clients use typed calls and live views. Writes commit business changes, idempotency records and invalidation notifications in one transaction. Subscriptions are authorized per user and recover automatically after disconnects.

- **Contract-driven**: one contract validates data, exports to JSON and generates TypeScript types.
- **Project and user isolation**: service keys exchange for short-lived user tokens; sessions and permissions are checked again before every push.
- **Reliable writes**: transactions, idempotency keys and durable invalidation notifications through Oban.
- **Live subscriptions**: full snapshots with ACK, optional field-level deltas and recovery to the current snapshot after disconnects.
- **Optional capabilities**: durable Runs and Effects, append subscriptions, shared subscriptions, presence, plugins, project quotas and Prometheus metrics.

Status: single-node operation, the Node SDK, four domain applications and two nodes on one machine have been verified. **Not yet published to Hex or npm**; production capacity has not been verified (see the [acceptance record](docs/ACCEPTANCE.md)).

Documentation: [Tutorial](docs/TUTORIAL.md) · [Index](docs/README.md) · [Installation](docs/INSTALL.md) · [Server development](docs/SERVER.md) · [Protocol](docs/PROTOCOL.md) · [TypeScript SDK](sdks/typescript/README.md) · [Product](docs/PRODUCT.md) · [Operations](docs/OPERATIONS.md) · [Example applications](examples/README.md) · [Troubleshooting](docs/TROUBLESHOOTING.md)

The SDK and example guides are available in English and [Simplified Chinese](docs/zh/README.md). Their original READMEs remain the Chinese sources. Benchmark READMEs are currently in Chinese.

## Quick start

Requires Elixir ≥ 1.18, Erlang/OTP, PostgreSQL ≥ 14 and Node ≥ 22 (verified with Elixir 1.20.5 / OTP 29, PostgreSQL 17 and Node 24).

```sh
bash scripts/postgres.sh start
mix deps.get
npm --prefix sdks/typescript ci && npm --prefix sdks/typescript run build
cd examples/inbox
mix fyrlet.migrate --create
mix fyrlet.project --output ../../.local/project.json "My App"
PHX_SERVER=true PORT=4000 mix phx.server
```

This starts the configured Inbox host at `http://127.0.0.1:4000`; local PostgreSQL uses port 55432. The root library has no business definitions registered by default. Run the Node example from the repository root in another terminal and enter text to save inbox records. Open a second instance to see live updates across clients:

```sh
node sdks/typescript/examples/inbox.mjs                     # Interactive; /quit to exit
node sdks/typescript/examples/inbox.mjs "Save the first record"  # Run once
```

The example reads server credentials from the ignored `.local/project.json` file and exchanges them for short-lived sessions. It is intended for trusted Node environments; browsers receive only user tokens issued by your backend. Set `DATABASE_URL` to use an existing PostgreSQL instance; `.env.example` is a configuration reference. Startup instructions for domain applications, including browser chat, are in [examples/](examples/README.md).

## Client usage

```ts
import { createClient } from "@fyrlet/client";
import type { AppContract } from "@fyrlet/client/example-contract";

const client = createClient<AppContract>({
  endpoint: "http://localhost:4000",
  projectId: "project UUID",
  getToken: async ({ forceRefresh }) => fetchSessionTokenFromYourBackend(forceRefresh),
});

const recent = client.subscribe("inbox.recent", { limit: 50 });
recent.onChange((state) => console.log(state.status, state.data));
await client.call("inbox.add", { text: "Hello Phoenix" });
client.close();
```

Implement `getToken` through your backend: obtain the user identity from an authenticated session, then exchange credentials for a Fyrlet session through the SDK's server entry point. The [integration tutorial](docs/TUTORIAL.md) includes the session handler and browser refresh implementation. See the [SDK documentation](sdks/typescript/README.md) for subscription states, reconnects, optimistic writes and presence.

## Extending the server

Implement the `contract` / `authorize` / `execute` / `scope` callbacks of `Fyrlet.Definition`, then register the module under `definitions` in `config/config.exs`. Input and output contracts are the single source of validation rules and types. Private queries must constrain the Actor's project and subject at the SQL level.

```sh
mix fyrlet.contract priv/contract.json && npm --prefix sdks/typescript run generate   # Export the contract and generate types
```

See [server development](docs/SERVER.md) for details and the [documentation index](docs/README.md) for optional capabilities such as shared subscriptions, append subscriptions and durable Runs.

## Repository layout

`lib/`: server · `sdks/typescript/`: TypeScript SDK (see [sdks/](sdks/README.md) for other languages) · `examples/`: Inbox, Notify, Flow, Agent and Chat · `packages/`: Webhooks / Ops plugins and HTTP / email adapters · `docs/`: documentation · `bench/` and `scripts/`: benchmarks and verification scripts

## Verification and benchmarks

```sh
mix format --check-formatted && mix compile --warnings-as-errors
bash scripts/test_all.sh                    # Elixir core, applications and standalone packages
npm --prefix sdks/typescript test           # SDK unit tests
bash scripts/integration.sh                 # Real HTTP / WebSocket scenarios
```

Other verification scripts are listed in the [acceptance record](docs/ACCEPTANCE.md). See [bench/](bench/README.md) for the benchmark methodology and [performance comparison](docs/PERFORMANCE.md) for results. Local results do not establish production capacity.

## Runtime boundaries

- PostgreSQL is the source of truth. There are no offline writes or atomic views across subscriptions. See the [protocol](docs/PROTOCOL.md#convergence-and-resources) for default limits. External side effects are outside the database idempotency guarantee; use Runs and Effects when needed.
- See [installation](docs/INSTALL.md) for production configuration (`DATABASE_URL`, `SECRET_KEY_BASE`, `ALLOWED_ORIGINS`, `CORS_ORIGINS`). Deployments must provide TLS, gateway rate limits, backups and a management console.
- Physical mobile devices, multi-host production deployments, 24-hour stability and real email delivery have not yet been verified.
