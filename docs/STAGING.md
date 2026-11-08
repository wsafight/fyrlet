# Real staging OIDC acceptance

English | [简体中文](zh/STAGING.md)

`scripts/staging_acceptance.mjs` is an **opt-in** runner for the deployed `examples/inbox-react` application. It complements `scripts/acceptance.mjs`: local tests and a signed test IdP are not evidence of an external IdP or staging deployment.

The runner performs real browser login, application and SDK checks. It does not start or replace the deployment, fabricate an identity, mock HTTP/WebSocket traffic, disable TLS, or convert unavailable scenarios into passes.

## Safety and result semantics

There are three entry points:

```sh
# Local files and Git only; no network.
node scripts/staging_acceptance.mjs --config .local/staging/acceptance.json

# Real discovery, PostgreSQL/schema and readiness only; no login.
node scripts/staging_acceptance.mjs --config .local/staging/acceptance.json \
  --preflight --confirm inbox-staging

# Preflight followed by real browser/application acceptance.
node scripts/staging_acceptance.mjs --config .local/staging/acceptance.json \
  --execute --confirm inbox-staging
```

`--preflight` and `--execute` both require `--confirm` to exactly equal the configured `deployment.id`. They also require a clean checkout with no tracked or non-ignored untracked changes, in addition to the exact `deployment.sourceRevision`; configuration-only mode may run in a dirty checkout. Missing configuration, credentials, browser steps, storage state, immutable metadata or the confirmation fails before the corresponding network action. The default mode never calls the deployment checker, launches a browser, rebuilds the SDK or contacts an IdP/API/host.

Every scenario is recorded as `passed`, `failed` or `not-run`, with a reason. `status: "passed"` for an execution requires exactly one passed record for every required application check and no recorded failure. Missing, duplicate, failed or `not-run` required records produce failed `application-completeness` evidence. Optional `not-run` scenarios remain visible and are never converted into passes. `complete` is true only when every recorded execution scenario passed. In particular:

- A preflight report has `kind: "staging-preflight"` and `acceptance.status: "not-run"`; discovery/readiness is not login acceptance.
- Storage-state authentication leaves `interactive-idp-login` as `not-run`.
- One host leaves `multi-host-shared-store` as `not-run`; an omitted secondary account leaves account switching/isolation as `not-run`.
- This generic tool always leaves `external-idp-revocation` as `not-run`. It verifies bounded host/session expiry and application logout/revocation, not an IdP-specific disable-user API or continuous introspection.
- Missing required result records and source changes during execution are failures, not partial passes.

Reports are written atomically to a unique directory under `.local/staging-acceptance/` unless `--out` is supplied. Use an ignored output directory: changing a non-ignored report inside the repository intentionally breaks the frozen-source check. The output must be a current-user-owned, non-symlink directory with no group/other access; files are mode `0600`. Each update uses a secure random exclusive temporary file followed by rename. No screenshots, traces or new storage state are captured.

Reports contain source cleanliness/revision/fingerprint metadata, declared deployment metadata, check names/statuses/reasons, public/direct and allowed browser origins, the sanitized SDK/Phoenix runtime digest, and browser version. They do not contain passwords, client/service keys, database URLs/keys, cookies, tokens, subject identifiers, usernames, OIDC callback parameters, response bodies, raw browser errors or storage state. Unexpected error details are suppressed in both the terminal and report. Release names, artifact digests, origins and provider names in the JSON configuration are therefore public report metadata, not secrets.

## Prerequisites

From the repository root, prepare the existing dependencies and browser (these installation commands are not part of the offline unit test):

```sh
npm --prefix sdks/typescript ci
npm --prefix sdks/typescript run build
npm --prefix sdks/react ci
npm --prefix sdks/react run build
npm --prefix examples/inbox-react ci
(cd examples/inbox-react && npx playwright install chromium)
```

The runner resolves Playwright and `@fyrlet/client` from `examples/inbox-react`; it does not add another protocol implementation.

The staging operator must provide all of the following:

1. The exact deployed Git revision, immutable host/API release names and SHA-256 artifact digests. The local checkout's `HEAD` must equal `deployment.sourceRevision`. Real network modes additionally reject every tracked or non-ignored untracked checkout change; run configuration-only validation separately while editing. Artifact fields are exact **operator declarations**; the generic runner cannot introspect Kubernetes, a container registry or another orchestrator.
2. A production-built Inbox host and API with the same project/configuration under test. The source fingerprint covers Git-tracked and non-ignored untracked files and is checked again after execution. Real CLI execution also removes and rebuilds `sdks/typescript/dist` with the existing local dependencies using `npm --offline run build`, verifies that Inbox resolves that exact SDK, and hashes the built runtime, package locks/metadata and resolved Phoenix ESM entry. The digest is recorded and checked again after execution; preflight and injected offline test runners do not perform this build.
3. HTTPS public/API/direct-host and IdP URLs. HTTP is accepted only for explicit loopback URLs; the existing deployment preflight remains strict about secure deployment configuration. Redirects carrying credentials are rejected.
4. At each configured IdP, an exact issuer, client ID, S256 PKCE support, and either public-client (`none`) or `client_secret_basic` token authentication as used by the host. Register only the real public callback, for example `https://staging.inbox.example.com/auth/callback`. Configure API CORS/allowed origins for the same public origin.
5. Dedicated staging accounts with known, non-production data. Configure two accounts for account switching and same-issuer subject isolation; configure accounts at two issuers for issuer/subject-pair isolation. For the strongest cross-issuer check, use two identities with the same external username/subject at different issuers. Interactive flows must be automatable without bypassing CAPTCHA or other IdP policy.
6. Outbound access from the runner to IdP discovery/authorization/token/JWKS endpoints, every direct host, and the API's HTTP/WebSocket endpoints. Preflight also connects to the configured PostgreSQL host store and API readiness endpoint, so database/network policy must permit it.
7. For multiple hosts, distinct direct HTTPS origins and the same public origin, project, endpoint, provider identities, `HOST_STORE_NAMESPACE` and 32-byte base64url `HOST_STORE_KEY` on every instance. `hosts.length` must equal `HOST_INSTANCES`. Use direct or session-affine PostgreSQL, never transaction/statement pooling; per-host advisory locks are session-bound. Run the existing store migration before acceptance.

Direct-host origins must be unique. Repeating a load-balancer URL under two IDs is rejected because it cannot prove two-host behavior. Direct origins are used only for host session/metadata requests; browser login stays on the public origin.

## Private configuration

Copy the safe examples into an ignored directory:

```sh
mkdir -p .local/staging
chmod 700 .local/staging
cp deploy/staging/acceptance.example.json .local/staging/acceptance.json
cp deploy/staging/inbox-react.env.example .local/staging/inbox-react.env
chmod 600 .local/staging/inbox-react.env
```

Edit both copied files. `environmentFile` is resolved relative to the JSON file. The environment file and any storage-state file must be regular, non-symlink files without group/other permissions. The JSON itself contains no credentials and is suitable for source fingerprinting.

Replace all zero digests and the zero Git revision; placeholders are deliberately rejected. `deployment.hostRelease` and `apiRelease` must be immutable identifiers, not `latest`.

The environment file supplies the exact host deployment settings (`PUBLIC_ORIGIN`, `FYRLET_ENDPOINT`, project/service configuration, `OIDC_PROVIDERS`, and host-store settings). `ALLOW_INSECURE_OIDC=1` is rejected. Put referenced account values in that private file or inject them into the runner process through a secret manager. Never put passwords or tokens in command-line arguments, shell history, JSON steps or reports.

### Configurable interactive IdP flow

Each account selects a provider from `OIDC_PROVIDERS`, configures exactly one authentication method, and declares its own `allowedBrowserOrigins`. This must be a unique list of exact origins, without paths, trailing slashes, queries or wildcards, and must include both `PUBLIC_ORIGIN` and the `FYRLET_ENDPOINT` origin. Add only the real IdP authorization, MFA, consent and redirect origins needed by that account; keep different accounts' third-party origins separate. HTTPS is mandatory except for explicit loopback HTTP.

For `steps`, supported actions are:

- `fill`: `selector` plus `valueFromEnv`; the value is resolved only in memory.
- `click`, `check`, `uncheck`: a Playwright CSS selector.
- `press`: a selector and key such as `Enter`.
- `wait`: wait for a selector to become visible.

Steps execute in order in the same tab after the runner clicks the existing Inbox provider link. Adjust selectors for username, password, deterministic MFA and consent pages. At most 30 steps and bounded Playwright timeouts are allowed. Literal `value`, `text` and `password` fields are rejected. Chromium service workers are blocked, every routed request outside the active account's exact origin allowlist is aborted, and the current page origin is checked before every step and again immediately before each credential `fill`.

The native WebSocket constructor is retained rather than message-proxying the real subscription, but its destination is restricted to the configured API origin's `/socket/websocket` endpoint (`wss:` for HTTPS, with `ws:` only for loopback HTTP). SDK HTTP requests are likewise pinned to the configured API origin and redirects are rejected.

The runner then verifies the exact configured issuer returned by `/auth/me`, the existing Inbox selectors, a bounded Secure/HttpOnly/SameSite=Lax host cookie, and a ready real subscription. A flow that cannot complete is a failure; it is not replaced with a synthetic login.

### Existing real-login storage state

Instead of `steps`, an account can use:

```json
{
  "provider": "first",
  "allowedBrowserOrigins": [
    "https://staging.inbox.example.com",
    "https://api-staging.example.com"
  ],
  "storageStateFromEnv": "STAGING_PRIMARY_STATE"
}
```

Set `STAGING_PRIMARY_STATE` to a fresh Playwright storage-state JSON path, relative to the acceptance configuration when not absolute. Capture it only after a genuine login to this same staging deployment, keep it mode `0600`, and delete it when no longer needed. The file must contain exactly one cookie: `fyrlet_host`, host-only for `PUBLIC_ORIGIN` (not a parent-domain cookie), `Path=/`, bounded, HttpOnly and SameSite=Lax, with `Secure` for HTTPS. Unrelated cookies and every local-storage origin are rejected. The runner never saves or prints the bearer-equivalent contents.

Storage state proves that the supplied authenticated state works with the real application; it does not prove a new interactive IdP authorization. Returning to the primary account after an account switch requires a fresh interactive primary login, so that scenario remains `not-run` when primary storage state is used.

## Executed application coverage

A fully configured execution performs the following real checks:

1. Non-authenticated `/auth/me` endpoint, project and complete provider name/label metadata on every direct host must equal the loaded configuration, not merely agree with another host. This does not claim to verify orchestrator artifact digests.
2. A real interactive IdP flow or supplied real-login storage state authenticates the primary account.
3. Host-cookie and issued-session expiry timestamps fit `revocation.maxHostSessionSeconds` (60–3600 seconds) and `maxTokenSeconds` (60–600 seconds), with bounded clock skew. The strategy must be `bounded-host-expiry`. Every API rejection used as revocation evidence receives the full session record and must remain unexpired beyond clock skew both before and after the rejected query, so natural expiry cannot create a false pass.
4. The existing Inbox UI creates a unique note and reaches `已保存并同步`. A second browser page and a real SDK `inbox.recent` query independently observe it. This covers mutation commit **and authoritative view confirmation**, not merely optimistic text. The sample has no delete operation, so the note remains in staging (including after some failures).
5. Forced session renewal revokes the old credential, preserves the stable SDK subject identity and retains the confirmed view. With two or more hosts, renewal is deliberately sent to the second direct host using the first host's cookie; the old credential must fail with `UNAUTHENTICATED` and the new one must complete a real SDK query.
6. The existing logout button must produce an awaited same-origin POST `/auth/logout` response with HTTP 200 and both `signedOut: true` and `revoked: true`; UI state alone is insufficient. The old host cookie must retain validity beyond clock skew throughout the check and cannot issue another session, including through the last direct host. The old unexpired API credential is rejected by a real SDK query.
7. With a secondary account and interactive primary flow, the runner switches accounts, checks that the primary note/subject is inaccessible, switches back, and verifies the stable primary subject and restored data. Exact configured issuers and SDK subject identifiers are compared in memory and never reported. Browser cookies are cleared between interactive accounts to prevent silent SSO back into the previous account; this is not a claim of global IdP logout.
8. Browser JavaScript errors fail the runtime check; their potentially sensitive messages are not retained. Best-effort cleanup attempts and validates logout on every direct host, even after an earlier failure. A sanitized `cleanup-logout` pass/failure is recorded without changing earlier scenario records; cleanup failure prevents an overall pass.
9. Before the real default browser loads the SDK, the clean offline rebuild/runtime digest gate described above must pass. The same SDK resolution and runtime digest must remain unchanged at the end. Missing, duplicate, failed or `not-run` required application records fail `application-completeness`; optional storage-state, single-host, account-switch and external-revocation limitations remain separate `not-run` evidence as applicable.

External IdP disable/revoke propagation is intentionally not guessed. The host currently bounds its effect by host invalidation or host/session expiry. The observed TTL bound is not evidence that an external revocation webhook exists or that revocation was externally triggered. Run an IdP-specific revocation drill separately if that evidence is required.

## Remaining external evidence

This runner does not establish production capacity, 24-hour stability, physical-device behavior, host kill/network-partition recovery, global IdP logout, external IdP revocation, registry publication or production approval. Artifact identity and uniform secret/configuration delivery still require deployment-system evidence. The SDK digest binds the local runtime used by this run; it does not establish upstream package provenance or deployed image identity. Browser origin and native WebSocket restrictions reduce exfiltration paths but are not a reason to trust a malicious explicitly allowed origin. A passed staging report must be reviewed together with its `not-run` reasons and the existing release checklist.

## Offline focused tests

```sh
node --check scripts/staging_acceptance.mjs
node --test scripts/staging_acceptance.test.mjs
```

The tests use temporary local fixtures, an injected SDK builder and injected failures only. They do not run the real SDK build, launch a browser, bind a port, contact PostgreSQL, perform OIDC discovery or make any real network request.
