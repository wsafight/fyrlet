# Fyrlet TypeScript SDK

English | [简体中文](README.zh-CN.md)

The SDK provides business calls and realtime subscriptions without depending on React, browser storage or cookie authentication. The package is currently private, builds into `dist`, and can be installed locally after `npm pack`. It has not been published to npm.

The implementation lives in `sdks/typescript/` and serves JavaScript and TypeScript applications. See the [SDK overview](../README.md) for the language layout and requirements for new SDKs, the independent [React adapter](../react/README.md), and the [Suiji with OIDC](../../examples/inbox-react/README.md). React Native runtime integration also belongs to the TypeScript ecosystem. For a complete server-to-browser walkthrough, start with the [integration tutorial](../../docs/TUTORIAL.md).

## Entry points

- `@fyrlet/client`: `createClient`, `ApiError` and public types.
- `@fyrlet/client/server`: `createSessionService`, for trusted backends.
- `@fyrlet/client/example-contract`: types generated from the inbox server contract.

## Exchanging sessions on the backend

```ts
import { createSessionService } from "@fyrlet/client/server";

const sessions = createSessionService({
  endpoint: process.env.FYRLET_ENDPOINT!,
  serviceKey: process.env.FYRLET_SERVICE_KEY!,
});

const session = await sessions.issueSession({
  external_subject: authenticatedUser.id,
  issuer: "my-product",
  ttl_seconds: 600,
});
```

`authenticatedUser` must come from your application's verified login state. Return `session.token` only to that user; keep the service key on the backend. `revokeSession(session_id)` revokes one session in this project.

## Calls and retries

`createClient<Contract>({ endpoint, projectId, getToken })` uses short-lived user tokens supplied by the host application. The first authentication reads the identity and binds the Subject; switching accounts on the same client is rejected. When `getToken` receives `forceRefresh: true`, revalidate the host login and obtain a new session.

```ts
const item = await client.call("inbox.add", { text: "Hello" }, {
  idempotencyKey: stableRequestId,
  signal: controller.signal,
});
await client.call("inbox.update", {
  id: item.id,
  text: "Updated",
  expected_version: item.version,
});
```

The SDK generates an idempotency key for each call. It refreshes expired authentication at most once and reuses that key. Network retry is off by default; manually repeated calls must explicitly reuse the original key. `CONFLICT` is not retried automatically. If the host login has expired, `getToken` should throw an `ApiError` with code `UNAUTHENTICATED` to stop recovery and clear subscription data.

Calls use HTTP by default. To reuse the realtime connection, choose Socket RPC:

```ts
const client = createClient<Contract>({
  endpoint,
  projectId,
  getToken,
  operationTransport: "socket",
});
```

Socket calls share one operations channel and the same connection as subscriptions. Calls also work without subscriptions. Transactions, authorization, idempotency and error codes have the same semantics; identity verification still uses HTTP. A disconnect rejects pending calls. Reconnecting does not replay writes. Concurrent calls on one operations channel are processed serially on the server.

`ApiError` exposes `code`, `message`, `details`, `retryable`, `status` and `requestId`. HTTP requests and call waits default to a 10-second timeout, configurable with `timeoutMs`. `AbortSignal` and `close()` cancel client waits. An ambiguous failure after dispatch throws `OutcomeUnknownError` with the operation, idempotency key and original cause. Use receipt recovery before deciding whether to submit another business call.

`client.mutate(name, input, options?)` returns a handle with `idempotencyKey`, `result`, `getState()`, `onChange()` and `recover()`. It distinguishes `pending`, read `completed`, write `committed`, Run/ingest `accepted`, definite `failed` and `unknown`. `call` still returns the business result. `mutation.recover()` or `client.recover(name, originalInput, { idempotencyKey })` queries an existing write/run receipt without executing the operation. Missing or expired receipts remain unknown. See [operation outcomes and recovery](../../docs/MUTATIONS.md) for examples, persistence and confirmation boundaries.

## Opt-in bounded retries

Pass generated `operationMetadata` to `createClient`, then enable `retry` per call or mutation:

```ts
import { operationMetadata } from "@fyrlet/client/example-contract";

const client = createClient<AppContract>({ endpoint, projectId, getToken, operationMetadata });
const mutation = client.mutate("inbox.add", { text: "Hello" }, {
  retry: { maxAttempts: 3, maxElapsedMs: 15_000, baseDelayMs: 250, maxDelayMs: 5_000 },
});
await mutation.result;
```

Only explicit read/write/run metadata is eligible; signal, cancel and ingest are excluded. Defaults are shown above. Attempts must be 1–10 and the total budget 1–60,000 ms. Backoff uses exponential full jitter, with numeric or HTTP-date `Retry-After` and `details.retry_after_ms` as minimum delays. Server CORS exposes `Retry-After`. Authentication refresh uses the same frozen input and key; attempt counts refer to outer attempts, with at most one authentication refresh inside each.

Transient reads and definitely rejected calls can be retried. After an uncertain write/run dispatch, further attempts only query the original receipt; an absent, expired or cleaned receipt remains unknown and never triggers business replay. This may leave a never-received write unknown; applications decide how to reconcile it. Permission, validation, conflict and protocol failures do not trigger further attempts. Cancellation, total timeout, authentication failure and client closure stop waiting and future attempts. An earlier unknown result stays unknown if recovery fails. `mutation.getState()` exposes `pending.retry` with attempt, phase (`call`/`recover`) and optional next retry time. View confirmation runs separately after success. There is no persistent retry queue.

## Subscription states

```ts
const recent = client.subscribe("inbox.recent", { limit: 20 });
const stop = recent.onChange(({ status, data, error }) => {
  renderInbox({ status, data, error });
});
await recent.refresh();
stop();
recent.unsubscribe();
client.close();
```

`onChange` immediately emits the current state and then reports state updates. `connecting` is the initial connection; `ready` means the subscription has received its current snapshot. `recovering` retains the previous data while recovering; `error` and `closed` clear data. `generation` and `seq` reject stale subscriptions and messages.

`refresh()` returns `Promise<void>` and only confirms that the server accepted the refresh request. Observe subsequent state updates to receive data. The SDK acknowledges snapshots, rebuilds disconnected subscriptions and returns to `ready` after the new initial snapshot. Business and permission errors terminate the affected subscription. `reconnect()` explicitly retries subscriptions that are still retained.

The SDK requests `delta-v1` by default. Once confirmed by the server, field deltas are applied locally and `onChange` still receives a complete business view. Initial joins, explicit refreshes and rejoins receive full snapshots. A sequence gap triggers reconnection. Subscription data is recursively frozen; later deltas do not mutate previously delivered views. Make a copy before editing locally, or set `delta: false` to use full snapshots.

Server-side Observer sharing is determined by the server contract. `"shared": true`, as in `inbox.recent`, keys sharing by the complete Actor and normalized subscription descriptor, so it shares only between devices on the same node using the same session. Different sessions remain isolated. Public results shared across users require `"sharing": "identical"`, member checks and a public query projection, as in Chat room state. Sharing never skips session, authorization or membership checks, and does not cache authorization decisions. Each client's `generation`, `seq` and ACK are independent. Slow clients catch up through a newly authorized full snapshot without blocking other clients or replaying historical deltas.

If a running Observer exits or a session-check worker fails or times out with a retryable internal status, the SDK enters `recovering`, retains previous data, refreshes the token, verifies identity and rebuilds the connection and subscriptions. It returns to `ready` only after a full snapshot with a new generation. Recovery backs off from 250 ms to at most 30 seconds unless `retryDelayMs` overrides it. Unconfirmed writes are not replayed. Terminal authentication and business permission errors clear data. The server retries an exited attach call once internally. Retryable initial join errors recover on the affected subscription through Phoenix rejoin backoff; they do not interrupt other subscriptions. More than 10 consecutive failures produce an error. `UNAUTHENTICATED` rebuilds the whole connection; non-retryable join errors fail immediately.

ACK is a one-way notification without a ref, response wait or reply timer. The SDK and server use the compact delta format in the [protocol](../../docs/PROTOCOL.md), without a legacy compatibility branch. Field-only changes reuse the immutable view's ID index and copy only the result array and changed records. Additions, removals and reordering still validate complete membership; a `WeakMap` releases indexes with their views.

`unsubscribe()` ends one subscription. In HTTP mode, ending the last subscription releases the connection. Socket mode retains it for later calls; use `close()` to release it. `close()` releases all subscriptions, timers and requests and permanently closes the client. Close the old client before creating one for a different account.

## Runs and append subscriptions

Declare the capability before using these APIs. Otherwise calls reject, and subscription methods throw synchronously, with `UNSUPPORTED_CAPABILITY`.

```ts
const flowClient = createClient({
  endpoint: flowEndpoint, projectId: flowProjectId, getToken: getFlowToken, capabilities: ["runs"],
});

const { run_id } = await flowClient.startRun("flow.start", {
  flow_id: "demo",
  nodes: [{ type: "wait", name: "approval", signal: "approve", timeout_seconds: 600 }],
});
const view = flowClient.subscribeRun(run_id);
view.onChange((state) => render(state.data));

await flowClient.signalRun(run_id, { wait_id, name: "napprove", payload: {} });
const cancel = await flowClient.cancelRun(run_id);
await flowClient.getRun(run_id);

const chatClient = createClient({
  endpoint: chatEndpoint, projectId: chatProjectId, getToken: getChatToken, capabilities: ["append"],
});
const feed = chatClient.subscribeAppend("chat.messages", { room_id });
feed.getState().cursor;
```

The Run example connects to a Flow host; the append example connects to a Chat host. Use each host's endpoint, project and token provider. Obtain `wait_id` from the waiting Run and `room_id` from a conversation you have joined. Flow normalizes signal `approve` to `napprove`.

- Starting a Run means acceptance, not completion. Observe its bounded `fyrlet.run` snapshot for status, steps, effects and truncated events. `startRun` automatically supplies an idempotency key; an accepted signal has not necessarily been consumed.
- `cancelRun` can return `confirmed` or `fenced_timeout`. The latter fences future advancement; it does not prove external work stopped. Inspect `effects` for the actual state of in-flight side effects.
- Append data is the latest `max_items` window, not complete history. Batches merge only when `base_cursor` matches the local cursor and sequence numbers are continuous. Otherwise the SDK refreshes from a server snapshot. Duplicate batches are not applied twice; reconnects restart from a snapshot. Treat cursors as opaque values and compare only for equality.
- Run and append types, including `RunView` and `StartedRun`, are exported from the package. The built-in `fyrlet.run` subscription is not part of the generated business contract.

## Optimistic writes (`CallOptions.optimistic`)

Overlay a local prediction on a subscription while a write is pending:

```ts
const items = client.subscribe("inbox.recent", {});
await client.call("inbox.add", { text }, {
  optimistic: [{
    subscription: items,
    update: (current) => [...current.filter((item) => item.id !== draft.id), draft],
  }],
});
items.getState().data;
items.getState().pending;
```

The update replaces by ID instead of blindly appending, because `current` may already contain the server's change. `data` includes predictions; `pending` counts predictions not yet replaced by server data.

- A definite failure immediately rolls back its prediction and throws the original error.
- After success, snapshot and append predictions remain until a correlated, freshly queried server snapshot confirms the view, or `optimisticTtlMs` expires (5000 ms by default). Unrelated snapshots and deltas do not retire them. An unknown outcome retains predictions until TTL expiry; expiry does not resolve the operation or confirm its view.
- Predictions are reapplied when server data arrives during the write. `update` must be idempotent and return a new value; mutating frozen data throws. A prediction that throws is discarded and reported to `onListenerError` without affecting the call.
- Only active subscriptions created by the same client are accepted. Invalid subscriptions cause a `TypeError` before sending the request. Subscriptions without data are skipped.
- Internal state remains the server's truth; overlays are derived only for `getState()` and listeners.

Predictions do not survive page reloads and do not provide an offline queue. A disconnected call can be failed or unknown depending on whether dispatch began. Append predictions must respect their window semantics. Presence predictions only affect the local roster, do not publish meta and retain their roster-update/TTL retirement behavior.

## View confirmation

`call` and `mutation.result` return the business result. Use `mutation.views` to separately wait for the subscriptions to catch up:

```ts
const mutation = client.mutate("inbox.add", { text }, { confirm: [items] });
const saved = await mutation.result;
const views = await mutation.views;
if (views.some((view) => view.status === "unconfirmed")) {
  await items.confirm();
}
```

Snapshot and append subscriptions targeted by optimistic updates are confirmed automatically after success; `CallOptions.confirm` adds explicit targets. Each result contains `subscription`, `status` (`confirmed` or `unconfirmed`) and an optional `error`. `subscription.confirm({ signal })` requests a fresh authoritative snapshot directly. Confirmation requires a matching correlation identifier, the current identity and generation, and a newer sequence. An accepted refresh reply, unrelated data or a delta cannot confirm a view. Even unchanged or empty results receive a new full snapshot.

The SDK negotiates `view_confirmation=1` automatically on snapshot and append channels. Each active subscription permits at most 32 pending confirmations. Timeouts, cancellation, reconnection, unsubscribe, permission failures and unsupported capabilities leave a view unconfirmed without changing a committed outcome or replaying the operation. Unknown outcomes do not start confirmation; after receipt recovery, request it explicitly. TTL expiry is a display fallback only. Filters and windows still apply, and subscriptions confirm independently. See [MUTATIONS.md](../../docs/MUTATIONS.md) for consistency boundaries.

## Shared client queries

Set `shareSubscriptions: true` when creating a client to reuse identical snapshot and append queries. `maxSharedSubscriptions` bounds active shared entries (default 100). Query keys include the project, name, mode and canonical JSON parameters within that client's identity context. Object key order is ignored; array order is preserved. Parameters are copied and frozen, with a 64 KiB encoded limit; undefined values, non-finite numbers, cycles and custom objects are rejected.

Each subscribe call returns an independent handle and listener registrations. Unsubscribing one handle leaves the others active; the last release leaves the channel and removes the entry immediately. No unreferenced cache is retained. Presence handles remain separate. Authentication failures and identity changes clear private state. This option reuses queries within one client; server-side Observer sharing continues to follow the application contract. The independent [React adapter](../react/README.md) adds hooks and deterministic empty SSR state. `selectSubscription(source, selector, isEqual?)` provides pure projections while retaining equal selected values; `queryKey(params)` exposes the same canonical JSON parameter key.

## Presence

Presence tracks transient state such as room membership and typing without writing it to the database. Declare `capabilities: ["presence"]` first:

```ts
const room = client.subscribePresence("room.presence", { room: "r1" }, { typing: false });
room.onChange((state) => {
  console.log(Object.keys(state.data ?? {}));
});
await room.update({ typing: true });
room.self();
room.unsubscribe();
```

`state.data` maps each subject ID to `{ ref, data, joined_at }` entries; two devices for the same user produce two entries. `update()` replaces this connection's metadata. `self()` returns your subject ID after joining, and `unsubscribe()` leaves the room.

- Room names, parameters and meta are generated from the contract's `presence` section in the [protocol](../../docs/PROTOCOL.md). `subscribePresence` and `update` infer these types, including roster meta; invalid names and inputs are rejected during typechecking. Legacy contracts without a presence section keep the string-based API. Optional `kind` fields preserve legacy operation contracts; generated kinds also restrict `startRun` names. Runtime retry policy requires the separately exported `operationMetadata` value.
- Membership updates by `ref`; repeated diffs are harmless. Reconnecting rejoins with the most recently updated metadata and replaces the roster.
- Updates are rate-limited. Excessive updates return retryable `LIMIT_EXCEEDED`, invalid metadata returns `VALIDATION_FAILED`, and an unready room returns `NOT_READY`.
- Anonymous sessions cannot join. Members can see one another's subject IDs and metadata.

## Socket decoder and batching

The SDK installs a Phoenix decoder accepting either a standard `[join_ref, ref, topic, event, payload]` frame or an object whose only field is `batch`: `{"batch":[...]}`. Refs are strings or null; topics and events are strings; payloads are non-null objects, not arrays. Batches contain 1–64 frames. The whole batch is validated before dispatch. Empty or oversized batches, invalid members and malformed JSON produce a non-retryable `PROTOCOL_ERROR` and clear subscription data; invalid batches are never partially applied.

The server batches only pushes already present in the current transport mailbox and does not wait to fill a batch. A single frame keeps the standard array format. Multiple frames can span topics, with a maximum of 64 frames and a default 256 KiB budget; an oversized single message is sent separately. Batching does not provide transactions across subscriptions or combine `onChange` notifications. This SDK handles decoding; a native Phoenix client needs a compatible decoder. Joins, calls and ACKs are still sent as standard single frames.

## Runtime integration

`ClientOptions` accepts injected `fetch`, `WebSocket`, `createId`, `retryDelayMs` and `onListenerError`. The default ID generator uses `crypto.randomUUID`; runtimes without it must supply a secure random UUID generator.

Node has passed real integration tests. Browser and React Native clients do not import the server entry point. React Native applications must also handle foreground/background transitions, network restoration and secure token storage; physical-device behavior has not been verified. There is no mobile push or offline writing.

## Contracts and verification

```sh
(cd examples/inbox && mix fyrlet.contract ../../priv/contract.json)
npm --prefix sdks/typescript run generate
npm --prefix sdks/typescript run build
npm --prefix sdks/typescript test
npm --prefix sdks/typescript run test:coverage
npm --prefix sdks/typescript run typecheck
bash scripts/integration.sh
DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh
```

Run these commands from the repository root. The generator supports the current restricted contract dialect and rejects unsupported schemas. Input fields with defaults become optional; output fields follow `required`. Generated types provide compile-time checks, while the server validates all input and output at runtime.

Unit tests cover mutation outcomes, receipt recovery, cancellation, authentication races, channel isolation, malformed deltas, correlated view confirmation, shared query lifetimes, listener failures, optimistic ordering and backend session services. `test:coverage` uses Node's built-in coverage tooling. Real-server tests cover HTTP/Socket outcomes, confirmation, query reuse, Run idempotency, isolation, restart recovery, append windows and revocation. Four domain applications add end-to-end scenarios. See the [acceptance record](../../docs/ACCEPTANCE.md) for current counts, commands and boundaries.

`bash scripts/package.sh` produces `.local/releases/fyrlet-client-0.1.0.tgz`; another project can install it with `npm install /absolute/path/fyrlet-client-0.1.0.tgz`. `bash scripts/install_smoke.sh` installs the package into a consumer outside the repository and imports both the main and server entry points. See [installation](../../docs/INSTALL.md) for distribution and version boundaries.
