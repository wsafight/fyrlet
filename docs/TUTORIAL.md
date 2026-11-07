# Connect your first realtime application

English | [简体中文](zh/TUTORIAL.md)

This walkthrough uses the existing Inbox host to connect a business definition, generated types, your backend's session endpoint and a browser subscription. The browser examples assume your existing web application runs at `http://localhost:5173`. Your host application supplies login and a POST route; the session handler below uses standard `Response` objects and can be adapted to its router.

## 1. Prepare and start the host

Use Elixir ≥ 1.18, Erlang/OTP, PostgreSQL ≥ 14 and Node ≥ 22.23.4. From the repository root:

```sh
bash scripts/postgres.sh start
mix deps.get
npm --prefix sdks/typescript ci
npm --prefix sdks/typescript run build
cd examples/inbox
mix fyrlet.migrate --create
mix fyrlet.project --output ../../.local/project.json "My App"
ALLOWED_ORIGINS=http://localhost:5173 CORS_ORIGINS=http://localhost:5173 PHX_SERVER=true PORT=4000 mix phx.server
```

The host uses `inbox_example_dev` on local port 55432. Apply the same `DATABASE_URL` to migration, project creation and startup when overriding it. The project command writes `project_id` and a backend-only `service_key` to `.local/project.json` at the repository root. It refuses to overwrite an existing file; reuse the existing credentials if they belong to this database, or choose a new output path for a new project.

The root Fyrlet application has no business definitions registered by default. Starting `examples/inbox` loads the reference definition and its migration. For a first check, open another terminal at the repository root and run `node sdks/typescript/examples/inbox.mjs`. Enter text and observe the live window before integrating a browser.

## 2. Define and register the business

The complete definition is [`InboxExample.Inbox`](../examples/inbox/lib/inbox_example/inbox.ex). Its `contract` declares `inbox.add`, `inbox.update` and the `inbox.recent` subscription. `authorize` controls admission, `execute` implements operations and `scope` identifies the data affected by changes. The example's SQL queries constrain both project and subject; returning `:ok` from `authorize` alone does not provide row isolation.

The host already registers the definition in [`examples/inbox/config/config.exs`](../examples/inbox/config/config.exs):

```elixir
config :fyrlet,
  definitions: [InboxExample.Inbox],
  migration_paths: [{:inbox_example, "priv/repo/migrations"}]
```

Keep the remaining configuration in that file. For your own host, implement the same callbacks with your models and replace the registered module. A dependency's configuration is not loaded into the host automatically. See [server development](SERVER.md) and [required configuration](INSTALL.md#required-configuration).

## 3. Export the contract and generate types

In another terminal, export from the configured host:

```sh
cd examples/inbox
mix fyrlet.contract ../../.local/tutorial-contract.json
```

From the repository root, generate a standalone TypeScript contract:

```sh
node sdks/typescript/scripts/generate.mjs .local/tutorial-contract.json .local/tutorial-contract.ts
```

Use that generated file as your web application's `src/contract.ts`, or change the generator's destination to that path. The module exports `AppContract`. Regenerate after changing the server contract. From your web application and backend package directories, install the already built SDK using `npm install /absolute/path/to/fyrlet/sdks/typescript`; see [installation](INSTALL.md) for packaged distribution.

## 4. Add a backend session endpoint

Set `FYRLET_ENDPOINT=http://127.0.0.1:4000` and load `FYRLET_SERVICE_KEY` from the project file's `service_key` into your backend environment. Connect a POST `/api/fyrlet/session` route to the following handler **after your application's authentication middleware**. Pass the verified user from that middleware; do not take the user ID from the request body. A signed-out request passes `null`.

```ts
import { createSessionService } from "@fyrlet/client/server";

const sessions = createSessionService({
  endpoint: process.env.FYRLET_ENDPOINT!,
  serviceKey: process.env.FYRLET_SERVICE_KEY!,
});

export async function issueSessionResponse(user: { id: string } | null): Promise<Response> {
  if (!user) {
    return Response.json({ error: "UNAUTHENTICATED" }, {
      status: 401,
      headers: { "cache-control": "no-store" },
    });
  }
  const session = await sessions.issueSession({
    external_subject: user.id,
    issuer: "my-product",
    ttl_seconds: 600,
  });
  return Response.json({
    token: session.token,
    project_id: session.project_id,
    expires_at: session.expires_at,
  }, { headers: { "cache-control": "no-store" } });
}
```

Use your router's normal error handling if Fyrlet cannot issue a session. For cookie-based login, apply the host's CSRF protection and same-origin checks to this POST route. Keep the service key on the backend. Revalidate login for every exchange, including refreshes; the browser must receive only the corresponding user's token. Session revocation is covered in the [SDK guide](../sdks/typescript/README.md#exchanging-sessions-on-the-backend).

## 5. Implement browser token refresh

In a browser module such as `src/fyrlet.ts`, replace `project UUID` with the project's `project_id`. The backend session route must be reachable at the web application's own origin; a development proxy can forward `/api/fyrlet/session` to your backend.

```ts
import { ApiError, createClient } from "@fyrlet/client";
import type { AppContract } from "./contract";

const projectId = "project UUID";
let session: { token: string; project_id: string; expires_at: string } | undefined;

async function getToken({ forceRefresh }: { forceRefresh: boolean }): Promise<string> {
  if (!forceRefresh && session && Date.parse(session.expires_at) > Date.now() + 30_000) {
    return session.token;
  }
  const response = await fetch("/api/fyrlet/session", {
    method: "POST",
    credentials: "same-origin",
    headers: { accept: "application/json" },
  });
  if (response.status === 401) {
    session = undefined;
    throw new ApiError({ code: "UNAUTHENTICATED", message: "Sign in again" }, 401);
  }
  if (!response.ok) {
    throw new ApiError({
      code: "SESSION_ERROR",
      message: "Could not issue a session",
      retryable: response.status >= 500,
    }, response.status);
  }
  const next = await response.json();
  if (!next || typeof next !== "object" || next.project_id !== projectId ||
      typeof next.token !== "string" || !next.token ||
      typeof next.expires_at !== "string" || !Number.isFinite(Date.parse(next.expires_at))) {
    throw new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid session response" });
  }
  session = next;
  return next.token;
}

export const client = createClient<AppContract>({
  endpoint: "http://127.0.0.1:4000",
  projectId,
  getToken,
});
```

Your host's CSRF protection may require an additional header from its own CSRF-token mechanism. The backend must still validate the login when `forceRefresh` is true. A host login failure must become `UNAUTHENTICATED`, rather than an endlessly retryable network error. If your web origin differs from `http://localhost:5173`, change both `ALLOWED_ORIGINS` and `CORS_ORIGINS` when starting Fyrlet, using the exact scheme, host and port.

## 6. Subscribe and write

Add this markup to the web page before loading its application module:

```html
<form id="inbox-form">
  <label>Message <input name="text" required /></label>
  <button type="submit">Add</button>
</form>
<pre id="inbox" aria-live="polite"></pre>
```

In `src/main.ts`, connect the form to the generated contract:

```ts
import { client } from "./fyrlet";

const output = document.querySelector<HTMLPreElement>("#inbox")!;
const form = document.querySelector<HTMLFormElement>("#inbox-form")!;
const recent = client.subscribe("inbox.recent", { limit: 20 });
recent.onChange((state) => {
  output.textContent = JSON.stringify({
    status: state.status,
    items: state.data,
    error: state.error?.code,
  }, null, 2);
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const text = String(new FormData(form).get("text") ?? "").trim();
  if (!text) return;
  const idempotencyKey = crypto.randomUUID();
  try {
    await client.call("inbox.add", { text }, { idempotencyKey });
    form.reset();
  } catch (error) {
    output.textContent = error instanceof Error ? error.message : String(error);
  }
});

window.addEventListener("pagehide", () => client.close(), { once: true });
```

Expect `connecting` followed by `ready`. A successful write appears through the subscription. Open a second signed-in window for the same host user to observe updates in both. Sign in as another user to verify isolation. Switching accounts requires closing the old client and creating a new one. In a framework, tie subscription and client cleanup to the owning component or application lifecycle, and recreate them when a page is restored after being closed.

## 7. Verify failures before extending

- Stop and restart the Fyrlet service: subscriptions should recover to a new full snapshot without replaying unconfirmed writes.
- Sign out of the host: the next token exchange should return 401, terminate recovery and clear private data.
- Retry an uncertain write only with its original idempotency key and identical input. `CONFLICT` requires resolving the version or key conflict.
- Regenerate types after changing the contract; enable optional capabilities on the host and client before calling their APIs.

See [troubleshooting](TROUBLESHOOTING.md) for diagnosis, [SDK usage](../sdks/typescript/README.md) for lifecycle details and [example applications](../examples/README.md) for larger domains. Production setup still needs the host's login, TLS, gateway controls and backups; this walkthrough does not establish production capacity.
