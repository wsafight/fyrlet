# Chat: collaborative conversations

English | [简体中文](README.zh-CN.md)

A standalone web chat application with `Room`, `Member` and `Message` models and migrations. Signed-in users create conversations and join conversations in the same project using random invitation codes. Rooms allow at most 50 members. Messages, assignment, human takeover, close and leave all check project and membership authorization.

## Startup

Prepare the SDK using the [shared startup steps](../README.md), then run inside `examples/chat`:

```sh
mix fyrlet.migrate --create
PHX_SERVER=false mix run ../../scripts/example_session.exs alice
PHX_SERVER=true PORT=4180 mix phx.server
```

## Invitations and conversation flow

Open `http://127.0.0.1:4180/` and enter the project and user session. Create a conversation and copy its invitation code. Run `PHX_SERVER=false mix run ../../scripts/example_session.exs bob`, sign in as Bob in another window and enter that code. Exchange messages, refresh members to update assignment candidates, or take over as the current user. Closing disables sending. Leaving revokes that user's room and message subscriptions and clears the detail view.

## Data and history

`chat.room` is a shared public projection authorized for each member and excludes invitation codes. `chat.messages` uses append subscriptions with a live window of the latest 100 messages. `chat.history` paginates the persistent message table by cursor, independently of append retention. The page shows at most 500 messages. `chat.rooms` lists only joined conversations; members obtain invitation codes through `chat.get`.

## Verification and boundaries

`mix test` runs 2 domain tests. From the root, run `DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh chat` for real sharing / append, invitations, project isolation, history, takeover and revocation on leave. `bash scripts/shared_bench.sh` compares ordinary and shared snapshots, and full messages against append, in a separate database on ports 4185/4186. See [performance](../../docs/PERFORMANCE.md#shared-rooms-and-append-streams-compared-end-to-end-2026-11-07) for results and limitations. Comparison operations `chat.room.private`, `chat.messages.snapshot` and `chat.rename` enforce the same membership authorization.

Anonymous writes, search, attachments, notifications and a complete customer-support console are outside the current scope. The source package can be installed independently; it has not been published as a registry product.
