# Suiji (随记): React notes with OIDC login

English | [简体中文](README.zh-CN.md)

Suiji (随记) is a place to keep notes, ideas and tasks. This application combines the existing Inbox Mix host, the independent React adapter and a Node host backend. It demonstrates shared queries, selectors, parameter changes, optimistic writes, separate commit/view confirmation, opt-in retries and a verified login bridge. Passwords and account management belong to your OpenID Connect provider.

## Start

Prepare PostgreSQL and the Mix dependencies as described in the [Inbox host](../inbox/README.md), then run from the repository root:

```sh
npm --prefix sdks/typescript ci
npm --prefix sdks/typescript run build
npm --prefix sdks/react ci
npm --prefix sdks/react run build
npm --prefix examples/inbox-react ci
cd examples/inbox
mix fyrlet.migrate --create
mix fyrlet.project --output ../../.local/inbox-react-project.json "Suiji"
PHX_SERVER=true PORT=4180 mix phx.server
```

In another terminal, copy `examples/inbox-react/.env.example` to `.env` in the same directory. Set `FYRLET_PROJECT_ID` and `FYRLET_SERVICE_KEY` from the ignored project file; both stay on the backend. Set the provider's exact issuer, client ID and client secret. Public PKCE clients omit `clientSecret`. Register `http://127.0.0.1:5173/auth/callback` as the provider's redirect URI. The provider must support S256 PKCE and either `client_secret_basic` or `none` token-endpoint authentication.

```sh
npm --prefix examples/inbox-react run dev
```

Open `http://127.0.0.1:5173`. The API host allows this origin by default. For another origin, update `PUBLIC_ORIGIN`, the IdP redirect URI and the API host's `CORS_ORIGINS` / `ALLOWED_ORIGINS` together. Build with `npm --prefix examples/inbox-react run build` and serve the build with `npm --prefix examples/inbox-react start`.

`ALLOW_INSECURE_OIDC=1` permits HTTP only on loopback for development. Use HTTPS origins and endpoints and unset it behind a production TLS gateway. `OIDC_PROVIDERS` accepts up to eight configured providers; identity is the verified pair of issuer and subject. Equal subjects at different issuers are independent users.

## Login and cleanup

The backend discovers only configured issuers and validates discovery issuer, endpoints and PKCE support. Login checks one-time state bound to an HttpOnly cookie, PKCE, the signed ID token, issuer, audience, authorized party, nonce and expiry. The browser cannot supply a trusted subject. Host cookies are HttpOnly and SameSite=Lax, with Secure on HTTPS. Session exchange, logout and revocation require the exact same Origin; the session endpoint accepts no identity body.

`POST /api/fyrlet/session` revalidates the host login, coalesces concurrent exchanges and returns only a short-lived Fyrlet token. `x-fyrlet-refresh: 1` rotates it and revokes the previous token. `POST /auth/logout` or `/auth/revoke` closes the host session and revokes its Fyrlet session. Logout racing issuance revokes a late token before returning it. Account switching closes the previous host session. Browser clients and token fetches close on logout; BroadcastChannel propagates logout to other tabs, and focus revalidates identity revisions.

This sample keeps at most 1000 pending logins and 1000 host sessions in one process. Pending logins expire after five minutes; host login lasts at most one hour or the ID token's expiry, whichever comes first. Expired sessions are invalidated locally, with at most eight background revocations and ten seconds between retries. Restarting this process requires signing in again. A multi-instance host needs its own shared session store. External IdP revocation takes effect when the host invalidates its session or it expires; no continuous IdP introspection is claimed. Failed remote logout is reported as unconfirmed, while local private state is cleared.

## Verify

```sh
npm --prefix sdks/react test
npm --prefix examples/inbox-react test
npm --prefix examples/inbox-react run test:coverage
(cd examples/inbox-react && npx playwright install chromium)
bash scripts/react.sh
```

The last command creates an isolated PostgreSQL project, runs the real API and production web build, and uses a signed local test IdP. It verifies shared queries, post-commit response loss without duplicate writes, view confirmation, two tabs, parameter changes, API restart, renewal, logout, revocation, user/issuer isolation and desktop/mobile layout. The mock provider is test-only. Production IdP credentials, physical devices, multi-host deployments and public package publication are not part of this local verification.
