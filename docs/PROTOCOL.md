# Business and subscription protocol

The protocol version `protocol_version` is currently only `1`: it must be sent when joining a channel, and any other value returns `UNSUPPORTED_VERSION`. Optional capabilities are enabled through [capability negotiation](#capability-negotiation). The business contract version is `0.1.0`. HTTP uses JSON; sockets use the Phoenix Channels v2 transport serializer. UUIDs and UTC timestamps are strings, and integers are limited to JavaScript safe integers. The contract dialect identifier is `realtime-subset-v1`; it is not full JSON Schema.

All language SDKs use the same protocol and do not get separate server interfaces by language or package name; for the SDK directory and implementation requirements see the [SDK overview](../sdks/README.md).

## HTTP

No response is cached. Success is `{"request_id":"…","data":…}`; failure is `{"request_id":"…","error":{"code":"…","message":"…","details":{},"retryable":false}}`.

| Endpoint | Credential | Request / result |
| --- | --- | --- |
| `GET /health` | None | Liveness status; does not imply database readiness |
| `POST /api/v1/sessions` | Service key Bearer | `{external_subject, issuer?, ttl_seconds?}` → token, project_id, subject_id, session_id, expires_at |
| `DELETE /api/v1/sessions/:id` | Service key Bearer | Revokes a session of the same project |
| `DELETE /api/v1/session` | User Bearer + X-Project-Id | Revokes the caller's own session |
| `GET /api/v1/contract` | User Bearer + X-Project-Id | Exported business contract |
| `GET /api/v1/identity` | User Bearer + X-Project-Id | Current project_id / subject_id, used by the SDK to bind identity |
| `POST /api/v1/operations/:name` | User Bearer + X-Project-Id | `{"input":{…}}` → business result; writes must carry an Idempotency-Key |

The request body limit is 64 KiB. The default idempotency retention window is 24 hours, scoped to project + subject + operation + key; the same normalized input replays the original result, and a different input returns CONFLICT. Deduplication is not guaranteed after the window. Only side effects inside this database's transaction are guaranteed.

| Error code | HTTP | Meaning |
| --- | --- | --- |
| UNAUTHENTICATED | 401 | Identity missing, invalid, expired or revoked |
| FORBIDDEN | 403 | Authenticated but not permitted; a record whose existence must not be revealed is returned uniformly as `NOT_FOUND`, according to application policy |
| NOT_FOUND | 404 | The operation, or a record visible to the current user, does not exist |
| VALIDATION_FAILED | 422 (400 for invalid JSON) | Input does not match the contract |
| CONFLICT | 409 | Idempotency key input conflict or record version conflict |
| LIMIT_EXCEEDED | 429 (413 when the request body is too large) | Subscription, data volume, rate or execution resource limit exceeded; `retryable` states whether retrying later is worthwhile |
| UNSUPPORTED_VERSION | 400 | The client protocol version is not supported |
| UNSUPPORTED_CAPABILITY | 400 | A capability the call depends on is not enabled or not negotiated |
| EFFECT_UNKNOWN | 409 | The outcome of a depended-on external side effect is unknown; the external business action must not be re-sent automatically |
| EFFECT_CONFLICT | 409 | The same side effect key corresponds to different requests |
| LEASE_LOST | 409 | The executor's lease is no longer valid; this attempt should stop |
| INTERNAL_ERROR | 500 | Unexpected server failure; stack traces and database details are not exposed |

The mapping between HTTP status codes and error codes is fixed in this document; applications do not choose their own.

## Socket

Connect to `/socket`; the public parameter is `project_id`. Use the Phoenix JS `authToken` option, with `auth_token: true` enabled on the server. The user token is encoded in `Sec-WebSocket-Protocol`; authentication through query parameters is not allowed. Origin is checked according to the endpoint configuration.

### Transport frames

A single frame is still the standard Phoenix v2 JSON five-element array `[join_ref, ref, topic, event, payload]`: the two refs are strings or null, topic / event are strings, and payload is a non-null object (not an array). A multi-frame outbound server message is `{"batch":[frame1,frame2,...]}`; batch is the only outer field, holds at most 64 frames, and is dispatched in array order. The receiver accepts a single frame or a batch of 1-64 frames; an empty batch, an oversized batch or an invalid member is a protocol error.

The server only aggregates pushes already in the transport mailbox in the same round, sends itself a flush message, and does not wait on a timer to fill a batch. The default aggregation limit is 64 frames and a 256 KiB budget, and a lower frame count can be configured; a single message that reaches the byte budget is sent on its own, so the budget is not a hard per-message limit. A single frame has no extra wrapping. A batch may contain snapshots, deltas or other Phoenix frames of different topics; it is only a transport wrapper and does not imply a cross-subscription transaction, a unified database version or an atomic state update. The join / call / ACK frames sent by the client still use standard Phoenix frames, and the server is not required to accept an inbound batch; a self-written client must extend its decoder, because the native Phoenix decoder cannot interpret an outbound batch directly.

### Subscriptions

Each logical subscription uses its own topic `subscription:<client random UUID>`. Join parameters:

```json
{"protocol_version":1,"name":"inbox.recent","params":{"limit":50}}
```

A successful join returns the initial Snapshot directly; later snapshots are pushed with the `snapshot` event in the same structure:

```json
{
  "protocol_version": 1,
  "capabilities": {},
  "subscription_id": "client UUID",
  "generation": "server-generated random identifier",
  "seq": 1,
  "project_id": "project UUID",
  "subject_id": "user UUID",
  "delivery": "snapshot",
  "data": []
}
```

The client replaces the data of that subscription with the full snapshot and sends the `ack` event `{"g":generation,"s":seq}`. An ACK is a one-way notification: the ref / join_ref of the Phoenix frame may be null, the server sends no ACK receipt, and the SDK creates no Push waiting for a reply and no timeout timer. generation is the unpadded Base64URL encoding of 16 random bytes, keeping the full 128 bits of randomness; the server still checks both the generation and the awaited sequence number. Each client subscription has at most one unacknowledged update, and is closed if it is not acknowledged within the default 15 seconds; shared Observers do not share ACK, generation or seq. A slow client does not block Observer updates or other devices from receiving, and no per-client patch queue is cached; if a slow client is behind when it ACKs, the server re-authorizes and reloads in full, then sends the current full snapshot to catch it up. A timeout is not data loss: resubscribing obtains the current full result.

The `refresh` event takes parameters `{}`, replies `{accepted:true}`, and then pushes a new snapshot. `phx_leave` cancels the subscription. The `status` event carries `{"state":"closed","error":{…}}` to indicate termination, after which the channel closes. Authentication failure may also disconnect the Socket directly; on recovery the SDK uses an authenticated HTTP request to tell a network interruption from an invalid credential.

A new join must use a new generation; the client accepts only the generation confirmed by the current join and rejects events from old instances. Within the same generation only messages with a seq greater than the current one are applied, and duplicate messages can still be acknowledged. seq is not a database version or a recovery cursor.

### Delta negotiation

A join may add `"delivery":"delta-v1"`, and the server returns the delivery actually used in the initial full snapshot. A client that did not request deltas keeps receiving full snapshots. Deltas apply only to arrays in which every record has a unique string id and the client is up to date with the previous view revision; for other results, an explicit refresh, catching up after falling behind, or when the patch JSON byte count plus 96 is not smaller than the full data byte count, a full snapshot is still pushed. The internal revision of a shared Observer is not equal to the client seq and is not used as a recovery cursor on the wire.

Example of a later `delta` event:

```json
{
  "g": "server-generated random identifier",
  "b": 1,
  "s": 2,
  "p": {
    "c": [["record UUID",{"text":"Updated","version":2}]]
  }
}
```

p is a compact patch and may contain a (array of complete new records), c (array of change tuples), r (array of deleted IDs) and o (the complete ID order of the result). Each change tuple is `[id,fields]` or `[id,fields,cleared]`, where cleared is an array of field names to delete. Assigning a field null is different from deleting the field. o is carried when membership or order changes. g, b and s stand for generation, base_seq and seq respectively; the identity and subscription scope of a delta are bound by the initial snapshot of the current channel.

The client applies a delta only when b equals the current seq and s equals b + 1, and then acknowledges the new seq. An old generation is ignored, and a duplicate seq may be acknowledged again; when a sequence gap is found, the client rejoins the subscription and recovers with a full snapshot. ACK, timeout and the final view size limit apply to deltas as well.

### Business calls

The same connection can join the topic `operations` with parameters `{"protocol_version":1}`. Calls are made as call through Phoenix push/reply:

```json
{"name":"inbox.update","input":{"id":"record UUID","text":"Updated","expected_version":1},"idempotency_key":"request UUID"}
```

Success replies `{"data":…}` and failure replies `{"error":{…},"status":409}`, distinguished by the ok / error status of the Phoenix reply. Writes must carry an idempotency_key, whose scope, retention time and transaction rules are the same as for HTTP. Every call re-validates the session and business permissions; the channel is closed when the session expires. Business execution shares the connection with subscriptions, and calls are processed serially within the operations channel. Authentication, the contract and server-side session management still use HTTP.

## Convergence and resources

An Observer first subscribes to internal invalidation notifications and then performs the initial load; it maintains the normalized View serially, and invalidation messages arriving during a query are queued and trigger a follow-up refresh. Only a server contract with an explicit `"shared": true` is shared; the key is the complete Actor (project_id / subject_id / session_id / expires_at) plus the complete prepared subscription descriptor (including normalized parameters), and is node-local. Multiple devices of the same session may share; different sessions do not share even for the same user; shared is not a join parameter and does not merge the ACKs of different logical subscriptions. The session is validated and business authorization is executed before each computation, and the session is validated again after it; every attach is checked independently, and there is no authorization TTL cache even when an already encoded snapshot is reused.

A write is committed in the same transaction as the Oban job; once the outermost transaction succeeds, an invalidation notification is broadcast immediately, and the Oban job remains as the durable retry path. A write nested in a caller's transaction is notified only through the Oban job that becomes visible after commit. The Observer deduplicates the last 64 notification IDs and does not filter out-of-order notifications by ID size; multiple pending refreshes are merged and fall back to a full load. Each Observer has only one coordination timer and, by default every 30 seconds, re-authorizes and runs a full query to repair missed notifications. When an automatic refresh finds the visible data unchanged, nothing is pushed and the sequence number stays the same; an explicit refresh still returns a full snapshot as long as the requesting side can receive it.

The normalized View and its context are server-internal structures and add no protocol fields. The inbox's private candidate area holds at most 8 entries and is not sent to the client; uncertain situations such as a version gap or too few candidates cause a reload, see the server documentation for details. The server's record version check and the client's delta seq check are protections at different levels.

The defaults are 20 subscriptions per connection, 100 items per page, 256 KiB of data per snapshot, 64 KiB per inbound Socket frame, and an Observer mailbox threshold of 200 messages. The outbound batching budget is 256 KiB by default and does not guarantee a hard limit for a single message. ACK limits the backlog of business pushes per client; the gateway should still limit connection count, request rate and transfer bandwidth.

## SDK recovery semantics

After a disconnect the SDK enters recovering, keeps the previous data and marks it explicitly as not ready. The SDK obtains a token again, verifies identity, and rebuilds the connection and subscriptions; it enters ready only after the initial snapshot arrives. The data is cleared when UNAUTHENTICATED / FORBIDDEN is confirmed or the client is closed. When the account changes, the old client should be closed and a new client created; the SDK refuses to switch Subject within a client that already has an identity binding.

The TypeScript SDK installs a custom decoder that validates the structure, frame count and members of the whole single frame or batch before dispatch, and then hands them to Phoenix in order. An invalid transport frame produces a non-retryable PROTOCOL_ERROR, and the first half of an invalid batch is not treated as a valid update; one batch does not merge multiple onChange calls, and no cross-subscription atomic callback is provided.

If a running Observer exits, a retryable INTERNAL_ERROR is reported to the channel; a failure or timeout of the session-check worker likewise fails with a retryable internal error, and an unverified session is not let through. When the SDK receives a retryable status it keeps the old data, enters recovering, rebuilds the connection and subscriptions, and recovers with a full snapshot of a new generation. The default retry delay grows exponentially from 250 ms up to 30 seconds and can be overridden with retryDelayMs. When an attach call exits, the server retries internally once. The SDK recovers likewise from a retryable error returned by the first join: that subscription enters recovering and the channel rejoins by itself (an error is reported only after more than 10 consecutive failures); UNAUTHENTICATED rebuilds the connection, and a non-retryable join error fails immediately.

On HTTP 401, or when a Socket call returns an authentication failure, `getToken({forceRefresh:true})` is called at most once and the call is retried, keeping the original idempotency key. The SDK does not automatically retry business conflicts or uncertain network failures; a caller that retries a write should explicitly reuse the idempotency key. On mobile, the connection may be closed while paused, and after resuming a client is created and queries are made again.

## Capability negotiation

Optional capabilities are off by default. A client that does not declare them does not get them: **the events of a capability that was not negotiated are never sent to this connection**, and calls that depend on it return `UNSUPPORTED_CAPABILITY`.

- **Contract**: `GET /api/v1/contract` (or `mix fyrlet.contract`) exports all entries this server can provide and lists the enabled capabilities under `capabilities`. Entries that depend on a capability (`run` / `ingest` operations, `append` subscriptions, `presence` rooms) appear only when the corresponding capability is enabled; a client that wants to use them must still negotiate. The TypeScript type generator accepts only contracts with `protocol_version: 1`.
- **Socket**: send `protocol_version: 1` when joining subscriptions and the `operations` channel, optionally with `capabilities` (`{name: version}` or an array of names). The enabled capabilities are the intersection with the server, with the lower version taken; the `capabilities` in replies and snapshots is the negotiation result (an empty object if none was declared).
- **HTTP**: use the request header `X-Fyrlet-Capabilities: runs, ingest=1`. A call that requires a capability that was not negotiated gets `UNSUPPORTED_CAPABILITY` (HTTP 400).
- **Contract evolution**: adding ignorable metadata and extending the `kind` enum are different kinds of change. Field changes are classified by the reader capability they require.
- **Server definitions**: a definition that implements only the base callbacks can be registered; the other callbacks are validated by operation kind and enabled capabilities, and not every definition is required to implement `run/3`, `step/3` or a shared query.

## Run (capability `runs`)

- The `kind` of a contract operation can be `run`: it creates a durable run, must carry an `Idempotency-Key`, and immediately returns `{run_id, status, existing}`; success only means it has been accepted. The same business key returns the existing run (`existing: true`).
- `GET /api/v1/runs/:id` reads the run view; `POST /api/v1/runs/:id/signals` `{wait_id, name, payload, idempotency_key}` delivers a signal, with receipt `accepted` (stored, not yet consumed) or `consumed`; `POST /api/v1/runs/:id/cancel` accepts a cancellation and returns `status`, `cancel_deadline` and `cancellation_outcome` (`confirmed` / `fenced_timeout`). All of the above require `X-Fyrlet-Capabilities: runs`.
- The subscriptions `fyrlet.run` (parameter `run_id`) and `fyrlet.runs.recent` (parameter `limit`, containing only the caller's own runs) are complete bounded snapshots and require negotiating `runs`. The event window is the latest 50, and anything beyond is marked with `events_truncated`.
- States: `pending`, `running`, `waiting`, `completed`, `failed`, `cancelling`, `cancelled`, `expired`. Step states include `awaiting_effect`; wait node states are `waiting`, `satisfied`, `timed_out`, `cancelled`.

## Append subscriptions (capability `append`)

A contract subscription declares `mode: "append"`, `max_items` (1-500) and `capability: "append"`. Join with the separate channel `append:<subscription UUID>` (joining an append subscription through `subscription:<id>` returns `VALIDATION_FAILED`); `append` must be negotiated in `capabilities`, otherwise `UNSUPPORTED_CAPABILITY` is returned. The join parameters are `{protocol_version: 1, capabilities, name, params}`; `delivery` is not used.

- Join reply and `snapshot`: `{protocol_version: 1, subscription_id, generation, seq, cursor, mode: "append", max_items, project_id, subject_id, capabilities, data}`. `data` is the latest at most `max_items` items. A `snapshot` received after the join, if its `generation` is the same and its `seq` is higher, replaces the view and cursor as a whole (sent when the cursor is invalidated, the window is exceeded, or the client sends `refresh`).
- `append`: `{g, s, base_cursor, cursor, items}`. **It is applied only when `base_cursor` equals the cursor held by the client and `s` is exactly the current seq + 1**; the cursor then becomes `cursor`, and the oldest items beyond `max_items` are dropped; a duplicate packet whose `s` is not greater than the current seq is not applied again; if it is not contiguous, merging stops and `refresh` is sent. The cursor is an opaque string, and the client only compares it for equality.
- Client `ack`: `{g, s, c}`, a cumulative acknowledgement (`s` and everything before it have been applied, and `c` is the cursor corresponding to `s`); all three must match the server's record, otherwise it is ignored. No `append` is sent before the snapshot is acknowledged.
- The unacknowledged window is at most 200 batches or 256 KiB (`config :fyrlet, :streams`); beyond that a new snapshot is sent instead of building a backlog; if no valid acknowledgement arrives within `snapshot_ack_timeout`, the subscription is closed with `LIMIT_EXCEEDED`.
- The client `refresh` requests a new snapshot (it is not sent again while an existing snapshot is awaiting acknowledgement).
- All members see the same items; the server re-checks the session and `authorize` before every send. The data is only a window, not the complete history.

## Presence (capability `presence`)

Short-lived state such as "who is in this room" and "is typing" is not written to PostgreSQL. The contract gains an optional `presence` section, parallel to `operations` and `subscriptions`, which appears only when the `presence` capability is enabled:

```json
"presence": {
  "room.presence": {
    "input": { "type": "object", "properties": { "room": { "type": "string" } }, "required": ["room"], "additionalProperties": false },
    "meta":  { "type": "object", "properties": { "typing": { "type": "boolean", "default": false } }, "additionalProperties": false }
  }
}
```

`input` is the schema of the room parameters; `meta` is the schema of the state a member can set, and when omitted a member cannot carry any state. **Who may enter and which room it is are decided by the definition's `authorize/3` and `scope/3`**, and the same scope is the same room; the server then merges the project ID into the room, so different projects never share a room.

Join with the channel `presence:<UUID>`; `presence` must be negotiated, otherwise `UNSUPPORTED_CAPABILITY` is returned. The join parameters are `{protocol_version: 1, capabilities, name, params, meta?}`; an anonymous principal gets `FORBIDDEN`.

- Join reply: `{protocol_version: 1, name, capabilities, self, state}`. `self` is one's own `subject_id`; `state` is `{subject_id: [{ref, data, joined_at}]}`. Members are **aggregated by `subject_id`**: the same person on two devices is one key with two metas. Identity is decided by the server, and fields such as a client-submitted `subject_id` are rejected by the schema.
- `diff`: `{joins, leaves}`, both in the same shape as `state`. It is applied by `ref`: `leaves` deletes the entry with the corresponding ref (and deletes the key when no entries remain under it), and `joins` adds entries whose ref does not yet exist. Receiving the same `diff` repeatedly (including the echo when one joins) is therefore harmless.
- Client `update`: `{meta}` replaces one's own meta and replies `ok` on success; the other members receive one `leaves` (old ref) plus `joins` (new ref). Each channel is limited to `presence_updates_per_second` (default 10) per second; beyond that a retryable `LIMIT_EXCEEDED` is returned; a validation failure returns `VALIDATION_FAILED`.
- Limits: the JSON of a single meta is at most `presence_max_meta_bytes` (default 1024) bytes; each room has at most `presence_max_members` (default 500) keys, and a member already in the room that joins again is not subject to this limit (the check and the join are not atomic, so concurrent joins can slightly exceed it). Online channels consume the subscription quota (connection limit and project limit).
- **Re-check**: like subscriptions, every `reconciliation_interval` the session is re-validated and `authorize/3` is called; on failure or session expiry, `status {state: "closed", error}` is pushed and the channel is closed.
- Offline: after the channel process ends (disconnect, close, crash) the member disappears automatically, with no timeout grace period. Across nodes it is synchronized through `Phoenix.Presence` (CRDT), and `FYRLET_CLUSTER_NODES` is needed to connect the nodes.
- Privacy: all members of a room can see each other's `subject_id` and `meta`. The application maps IDs to names through its own subscriptions; if the `subject_id` itself should not be exposed, do not use presence.

## Effect receipts

`POST /api/v1/effects/:id/receipts` `{receipt_id, outcome: "succeeded" | "failed", result}`, authenticated with the **project service key** (`rtk_`), and the side effect must belong to that project. Submitting the same `receipt_id` again returns `duplicate`; a receipt that contradicts the recorded outcome is recorded but not applied, and returns `CONFLICT`.

## External executors (server capability `executors`)

`POST /api/v1/executor/claim`, `POST …/attempts/:id/heartbeat`, `GET …/attempts/:id?wait=`, `POST …/attempts/:id/result`, using an executor credential (`rtx_`). See [RUNS.md](RUNS.md#external-executor-protocol) for details.

## Webhook (plugin `FyrletWebhooks`, capability `webhooks`)

`POST /api/v1/plugins/webhooks/:source` (plugin `FyrletWebhooks`), with the header `x-fyrlet-signature: t=<unix seconds>,v1=<hex>`, where `v1 = HMAC-SHA256(secret, "<t>.<raw request body>")`. The time tolerance is 300 seconds by default; the same `event_id` is accepted only once. A source must be explicitly configured in `config :fyrlet_webhooks, sources:`, with a secret of at least 16 bytes; an unconfigured source, an empty secret, or a mismatching signature or time is always rejected (there is no fallback to an unauthenticated path).

## Bulk ingest (capability `ingest`)

The contract operation `kind: "ingest"`, through `POST /api/v1/operations/:name`, takes the input `{items: [{key, data}], atomic?}`, with at most 100 items per batch. Acceptance is durable and processing is asynchronous; the per-item results are `accepted`, `invalid`, `conflict`, `duplicate:<status>`. With `atomic: true`, any invalid item causes the whole batch to be rejected. When the pending volume exceeds the limit, a retryable `LIMIT_EXCEEDED` is returned and the request stores nothing. `GET /api/v1/ingest/batches/:id` reads the batch status.

## Anonymous read-only entry (capability `anonymous_read`)

The project must explicitly enable it in its configuration. `POST /api/v1/anonymous/sessions` `{project_id}` needs no credential and returns a short-lived session. An anonymous caller can use only the read operations and subscriptions the contract marks `"public": true`, and must negotiate `anonymous_read` to join; writes, runs, signals, cancellation and the contract endpoint are always `FORBIDDEN`. There are separate session issuance rate and active-count limits, and the subscription limit defaults to 3.

## Plugin entry

`/api/v1/plugins/<name>/…` is handled by the plugin; a plugin that is not loaded, is disabled or has failed returns 404.

## Operations status (plugin `FyrletOps`, capability `ops`)

`GET /api/v1/plugins/ops/status`, authenticated with the **project service key** (`rtk_`), returns the project's own `{status, alerts}`: Run and Effect counts by status, stalled count, oldest queue age, overdue waits, unresolved side effects, and concurrency/queue usage. A user token is rejected (401); when the capability is not enabled it returns 404. Alerts contain only the name, severity, value and threshold, and no Run or Effect IDs.
