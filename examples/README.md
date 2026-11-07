# Example applications

English | [简体中文](README.zh-CN.md)

Notify, Flow, Agent and Chat are four standalone Mix applications using Fyrlet's public interfaces, repository and runtime. Each owns its domain models, migrations, configuration and tests. An ordinary host Plug serves the web pages; resources in `examples/support/` embed the real TypeScript SDK at compile time without a CDN.

## Minimal inbox

Start with [Inbox](inbox/README.md) to see a small host application, business definitions, private data and live subscriptions through the Node CLI. The [integration tutorial](../docs/TUTORIAL.md) connects that host to a backend session endpoint and a browser client.

## Local startup and login

Prepare dependencies at the repository root:

```sh
bash scripts/postgres.sh start
mix deps.get
npm --prefix sdks/typescript ci
npm --prefix sdks/typescript run build
```

For Chat, run the following. Replace `chat` with `notify`, `flow` or `agent` for another web application:

```sh
cd examples/chat
mix fyrlet.migrate --create
PHX_SERVER=false mix run ../../scripts/example_session.exs alice
PHX_SERVER=true PORT=4180 mix phx.server
```

Open `http://127.0.0.1:4180/` and enter the printed `project_id` and `token`. Each application defaults to its own `<domain>_example_dev` database on local port 55432. To override it, use the same `DATABASE_URL` for migrations, session issuance and the server. Use separate ports when running applications together.

The session script works only in development. It saves service keys under the ignored `.local/examples/<domain>.json` path with mode 0600 and prints only the project, subject, user token and expiry. Tokens last 15 minutes; rerun the script after expiry. Reusing `alice` keeps the same project and subject. Passing `bob` issues a session for another user in the same project, useful for invitation and isolation checks in a second browser window. Pages retain user tokens only in memory and do not accept service keys. Production applications need their own verified login flow.

## Verification

Run `mix test` inside an application directory. From the repository root:

```sh
bash scripts/test_all.sh
DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh
(cd sdks/typescript && npx playwright install chromium webkit)
bash scripts/browser.sh
bash scripts/cluster.sh
```

The domain end-to-end script creates isolated projects in `<domain>_integration` databases, starts its own services and cleans them up. Local test providers simulate external HTTP for Notify and Flow. Browser tests add interactions, layout checks and screenshots for three viewports, using `<domain>_browser` databases and ports 4210/4211. Cluster tests use `<domain>_cluster` databases and ports 4200–4204, with 120 seconds of traffic by default. Pass an application name to narrow the scope. Real email, physical mobile devices and production capacity require separate acceptance; see the [acceptance record](../docs/ACCEPTANCE.md).

## Application boundaries

| Application | Implemented | Outside the current scope |
| --- | --- | --- |
| [Notify](notify/README.md) | Private notifications, Resend email, Runs / Effects and delivery reconciliation | Verified real delivery, multiple channels, templates and preferences |
| [Flow](flow/README.md) | Private flows, sequential HTTP / wait nodes, signals and restart recovery | Branches, loops, a canvas and passing data between nodes |
| [Agent](agent/README.md) | Two bounded text tools, approval / rejection, task records and cancellation | LLMs, RAG and arbitrary tool execution |
| [Chat](chat/README.md) | Login and invitations, assignment, human takeover, shared state, append messages and paginated history | Anonymous writes, search, attachments and a production support system |

See [installation](../docs/INSTALL.md) for public interfaces and [implementation status](../docs/STATUS.md) for verified capabilities.
