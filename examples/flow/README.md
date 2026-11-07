# Flow: sequential workflows

English | [简体中文](README.zh-CN.md)

A standalone workflow application with a private `Flow` model, migrations and a Chinese-language web page. `flow.save` persists definitions and `flow.saved` lists the current user's flows. `flow.start` creates a Run; an active flow rejects another start and can run again after completion.

## Startup

Prepare dependencies using the [shared startup steps](../README.md), then run inside `examples/flow`:

```sh
mix fyrlet.migrate --create
PHX_SERVER=false mix run ../../scripts/example_session.exs alice
PHX_SERVER=true PORT=4180 mix phx.server
```

## Demo flow

Open `http://127.0.0.1:4180/` and connect with a project and user session. The default flow waits for approval. Save and run it, inspect the Run, then send `ngo` to continue. Node and signal names are lowercased, unsupported characters become `-`, and an `n` prefix is added: an input signal named `go` becomes protocol signal `ngo`. Converted names are at most 63 characters long.

## Nodes and boundaries

Node JSON supports `http` and `wait`, with 1–20 nodes per flow. HTTP nodes require a URL; `body` is a string containing a JSON object. Invalid JSON is rejected before save or start, without creating a Run. Before calling external targets, configure `config :fyrlet_effect_http, allowed_hosts: ["api.example.com"]`. Plain HTTP requires explicit `allow_http: true`; tests configure local targets themselves. Wait nodes accept `signal`, `timeout_seconds` and `continue_on_timeout`.

## Verification

`mix test` runs 5 tests covering HTTP / wait / HTTP, timeouts, rejection, cancellation and invalid input. Run `DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh flow` at the root to verify updates, real service restart and continuation after a signal. Core Effects retain unknown external outcomes. Branches, loops, passing data between nodes, scheduled triggers and a canvas are outside the current implementation.
