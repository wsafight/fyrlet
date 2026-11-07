# Agent: bounded tools with approval

English | [简体中文](README.zh-CN.md)

A standalone approval application with a `Task` model, migrations and a Chinese-language web page. `agent.start` executes prepare → approval → finish. Tool results and task records use managed commits; the owner must explicitly approve or reject, and a timeout fails the Run. `agent.tasks` lists the user's own tasks live, including cancellations and failures.

## Startup

Prepare dependencies using the [shared startup steps](../README.md), then run inside `examples/agent`:

```sh
mix fyrlet.migrate --create
PHX_SERVER=false mix run ../../scripts/example_session.exs alice
PHX_SERVER=true PORT=4180 mix phx.server
```

## Demo

Open `http://127.0.0.1:4180/` and enter the project and user session. Enter text, choose `word_count` (whitespace-separated word and character counts) or `excerpt` (the first 160 characters), then create a task and approve or reject it in the detail view. You can also cancel while waiting. Other users cannot view, approve or cancel the task. Approval signals require an explicit boolean decision.

## Verification and boundaries

`mix test` runs 2 domain tests. From the root, run `DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh agent` to verify the bounded tool allowlist, owner approval and persisted rejection results. Installation acceptance outside the repository also runs these tests. The application verifies durable Runs and human intervention; LLMs, model-call Effects, RAG and arbitrary tool execution are not implemented.
