# Troubleshooting

English | [简体中文](zh/TROUBLESHOOTING.md)

Start with the failing layer: host startup, backend session exchange, browser HTTP, Socket subscription or external Effect. Capture the error code and request ID before retrying. The [protocol](PROTOCOL.md#http) defines error semantics; the [integration tutorial](TUTORIAL.md) provides a small reference setup.

## Host startup and database

| Symptom | Check | Action |
| --- | --- | --- |
| The service starts but `inbox.add` is `NOT_FOUND` | The root configuration has no business definitions by default | Start `examples/inbox`, or register your own definition in the host's `definitions` |
| Connection refused or database missing | PostgreSQL port, `DATABASE_URL`, database name and host application directory | Start local PostgreSQL with `bash scripts/postgres.sh start` from the root; run `mix fyrlet.migrate --create` from the intended host |
| Tables or columns are missing | Whether migration and runtime use the same database and `migration_paths` | Apply the host's migrations; see [installation](INSTALL.md#installation-steps) |
| Project output already exists | `mix fyrlet.project` deliberately refuses to overwrite credentials | Reuse the file only for its original database, or create a new project with another output path |
| A valid-looking service key is rejected after changing databases | Credentials identify a project in a different database | Issue a project in the intended database and configure the backend with its matching project and key |

The core migration was consolidated before release. Older development databases may need rebuilding, as described in [installation](INSTALL.md). Preserve data you need before changing a database. Production migration and backup policies belong to the host deployment.

## Browser connection and origins

Check the actual scheme, host and port in the browser's Network panel. `localhost` and `127.0.0.1` are distinct origins, as are different ports. The SDK `endpoint` is the Fyrlet service; `/api/fyrlet/session` is your host's authenticated backend route. Do not point the SDK at the Astro documentation site.

For a browser application at `http://localhost:5173`, start the Inbox host with:

```sh
ALLOWED_ORIGINS=http://localhost:5173 CORS_ORIGINS=http://localhost:5173 PHX_SERVER=true PORT=4000 mix phx.server
```

`CORS_ORIGINS` controls cross-origin HTTP access. `ALLOWED_ORIGINS` controls the Socket origin check. Configure both when the browser uses a separate origin. An HTTPS page needs an HTTPS service and a gateway that forwards WebSocket upgrades. See [runtime configuration](INSTALL.md#required-configuration).

## Authentication and authorization

- A 401 from the host's session route means its login must be restored. The browser's `getToken` should throw `ApiError` with `UNAUTHENTICATED`, which terminates automatic recovery and clears private data.
- A 401 from Fyrlet can mean an expired, revoked or mismatched token. Verify the endpoint, project, token expiry and backend service key. A service key begins with `rtk_` and belongs on the backend; a user session token begins with `rts_`.
- `FORBIDDEN` means identity was accepted but the operation or subscription was not authorized. Check the definition's authorization and project, subject and membership constraints. Applications can return `NOT_FOUND` to conceal inaccessible records.
- Account switching requires `close()` on the old client followed by a new client. Reusing one client for another Subject is rejected.

See [authentication](AUTH.md) and [backend session exchange](../sdks/typescript/README.md#exchanging-sessions-on-the-backend). Never include tokens or service keys in a bug report.

## A subscription is empty or keeps recovering

An empty `ready` view can be correct: the current subject may have no rows, records may be archived, or query parameters may filter them out. Check the normalized input and the SQL scope before investigating transport recovery. `inbox.recent` belongs to the authenticated subject, not every user in the project.

`connecting` is the initial join. `recovering` retains the previous view while restoring a subscription. Inspect the error code and server logs if it persists. A retryable initial join error is retried on that subscription; more than 10 consecutive join failures produce an error. Authentication failure can rebuild the entire connection. See [subscription states](../sdks/typescript/README.md#subscription-states).

If a successful write never updates the view, check that it commits through Fyrlet's managed transaction and returns the correct invalidation scope, and that the subscription is still active. `refresh()` confirms acceptance of a refresh request, not that fresh data has arrived; observe `onChange`. Shared subscriptions still recheck membership and authorization. Reconnects restore a full snapshot rather than replaying historical deltas.

## Writes, conflicts and limits

| Error or symptom | Meaning | Response |
| --- | --- | --- |
| Timeout, abort or `NETWORK_ERROR` | The client does not know whether the server committed | Retry only with the original idempotency key and identical input, within the retention window |
| `CONFLICT` | A reused key has different input, or `expected_version` is stale | Inspect the conflict, refresh the record and let the user resolve it; do not retry blindly |
| `VALIDATION_FAILED` | The input does not satisfy the server contract | Inspect `details`, fix the input and regenerate client types if the contract changed |
| `LIMIT_EXCEEDED` | A request, rate, snapshot, observer or subscription limit was reached | Inspect `details` and `retryable`; reduce the payload or window, release unused subscriptions, or adjust the appropriate host limit |

Idempotency retention is finite and does not cover external side effects. Optimistic UI is a local prediction: failure rolls it back, and a push computed before a commit can briefly hide it. It is not an offline write queue. See [SDK usage](../sdks/typescript/README.md) and [capacity](OPERATIONS.md#data-retention-and-capacity).

## Optional capabilities and generated types

`UNSUPPORTED_CAPABILITY` means a required capability is absent from the server configuration, client declaration or negotiated intersection. Check `capabilities` on both sides and the definition's operation kind. Run, append and presence calls require their corresponding capabilities. See [capability negotiation](PROTOCOL.md#capability-negotiation).

After changing a contract, export it from the configured host, rerun the generator and rebuild the consuming application. Generated business types do not currently cover the `presence` section. `fyrlet.run` is built in rather than generated. An unknown operation can also indicate that the server is running a different host or definition than the contract used for generation.

## Runs and external Effects

An accepted Run or signal has not necessarily finished or been consumed. Observe the Run view and inspect waits, steps and Effects. A `fenced_timeout` cancellation prevents future advancement but does not prove external work stopped. See [Runs](RUNS.md).

`EFFECT_UNKNOWN` or an `unknown` email result requires reconciliation with the provider. Do not resend automatically. `accepted` means submission, while `delivered` means the provider reported delivery. For Flow, check the HTTP adapter's `allowed_hosts`; plain HTTP requires explicit `allow_http: true`. See [Effects](EFFECTS.md), [Notify](../examples/notify/README.md) and [Flow](../examples/flow/README.md).

## Collect useful evidence

Record the host application, server and SDK revisions, operation or subscription name, sanitized input, error `code`, `details`, `retryable`, `status` and `requestId`, and whether the issue is repeatable after a clean reconnect. Include relevant server logs and browser request timing, with credentials and private data removed.

Narrow the reproduction to one subject, operation or subscription. Start from the [Inbox example](../examples/inbox/README.md), then run the relevant checks in the [acceptance record](ACCEPTANCE.md). Keep benchmark measurements separate from functional reproduction; production capacity and physical mobile behavior remain outside local acceptance.
