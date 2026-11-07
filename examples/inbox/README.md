# Inbox: a minimal realtime inbox

English | [简体中文](README.zh-CN.md)

This standalone Mix host uses Fyrlet as a path dependency. `InboxExample.Inbox` defines the contract, authorization, reads, writes and subscriptions. The host owns the `Item` model and migrations. The Node CLI demonstrates live updates for one user and isolation between users.

## Start the service

Follow the [example overview](../README.md) to prepare PostgreSQL, Elixir dependencies and the SDK at the repository root, then run:

```sh
cd examples/inbox
mix fyrlet.migrate --create
mix fyrlet.project --output ../../.local/inbox-project.json "Inbox demo"
PHX_SERVER=true PORT=4180 mix phx.server
```

The default database is `inbox_example_dev` on local port 55432. If using `DATABASE_URL`, migrations, project creation and the server must use the same database. The project file contains a service key and is intended only for trusted local programs.

## Verify live updates and isolation

Open another terminal at the repository root:

```sh
FYRLET_ENDPOINT=http://127.0.0.1:4180 FYRLET_PROJECT_FILE=.local/inbox-project.json node sdks/typescript/examples/inbox.mjs
```

Enter text to call `inbox.add`; `inbox.recent` supplies the live window. Run the same command in a second terminal to see the same user's updates in both. Enter `/quit` to exit.

Use a different subject in another terminal:

```sh
FYRLET_SUBJECT=bob FYRLET_ENDPOINT=http://127.0.0.1:4180 FYRLET_PROJECT_FILE=.local/inbox-project.json node sdks/typescript/examples/inbox.mjs
```

Bob's inbox is isolated from the default user's inbox. Separately issued sessions can receive the same subject's data, but the same-session optimization of `shared: true` applies only when reusing one session. See [shared subscriptions](../../docs/SHARING.md).

## Business definitions and types

The implementation is in [`lib/inbox_example/inbox.ex`](lib/inbox_example/inbox.ex); registration and runtime limits are in [`config/config.exs`](config/config.exs). Private queries constrain SQL by the Actor's project and subject. Updates use `expected_version` for conflict checks.

The [integration tutorial](../../docs/TUTORIAL.md) covers registration, contract export, type generation, a backend session endpoint and browser integration.

## Tests and boundaries

Run `mix test` in the application directory. Tests use SQL Sandbox and manual Oban. The Node interaction is for local verification; see domain applications such as [Chat](../chat/README.md) for browser pages. The host supplies production login, TLS, gateway rate limits and backups. See [installation](../../docs/INSTALL.md) and [authentication](../../docs/AUTH.md).
