# Authentication and project isolation

Authentication has four parts: identity and sessions, authorization enforcement points, business authorization rules, and the credential scheme for new entry points. The layer boundaries are described in [ARCHITECTURE.md](ARCHITECTURE.md#authentication-boundaries).

## Identity layers

| Identity | Credential | Where used | Capability |
| --- | --- | --- | --- |
| Platform developer | No platform account is provided yet | Admin console | Create projects and manage keys; managed through a trusted CLI |
| Customer backend | `rtk_` project service key | The customer's own server | Issue sessions for verified external users; revoke this project's sessions |
| End user | `rts_` short-lived session token | Web / Node / mobile SDK | Call operations and subscribe to the data this identity is authorized to see |
| Anonymous read-only principal | `rts_` token, session `kind = "anonymous"` | Public pages | Read-only, and only content the contract marks `public`; see [Anonymous principals](#anonymous-principals) |
| External executor | `rtx_` executor credential (`Fyrlet.Features.Executors.create/3`) | Executor process | Claim steps from the queues it is authorized for in its own project, and renew leases on and report the attempts it holds; nothing else |
| Receipt sender | Project service key `rtk_` | Customer backend | Submit receipts for this project's side effects |
| Webhook source | Configured shared secret + request signature | Third-party service | Deliver signals to wait nodes of this project's runs, and nothing more |

`project_id` is a public routing identifier, not a secret or proof of permission. A service key cannot call end-user business endpoints directly. Tokens use 32 bytes of secure random data, and the database stores only a SHA-256 hash. A user token cannot be used as an executor, service key or anonymous identity, and vice versa; the issuer name `anonymous` is reserved when a backend issues a session, so that real users are not cleaned up as anonymous principals.

## Onboarding flow

1. The deployer runs `mix fyrlet.project "My App"` and stores the returned project ID and service key in trusted backend configuration.
2. The customer backend authenticates the user with its existing login system and takes the external user identifier from the verified login context.
3. The customer backend calls `POST /api/v1/sessions` with the service key and `external_subject`, and may specify `issuer` and a lifetime.
4. The framework looks up or creates a Subject by `(project_id, issuer, external_subject)` and returns a short-lived user token.
5. The customer backend returns the user token only to the corresponding user. The SDK uses it for HTTP calls and Socket authentication.
6. The host application obtains a new token from its own backend before or after expiry; the framework does not expose project keys to end users and does not issue long-lived refresh tokens.

The customer's own token-exchange endpoint must take the user ID from the login session and must not trust an `external_subject` submitted by the browser. No password system, OAuth authorization server or third-party JWT verifier is implemented.

## Authorization and isolation

- An Actor contains the project, subject, session and expiry as verified by the server; client overrides are not accepted.
- The session and authorization are re-checked before every operation, subscription setup, re-query and snapshot send.
- Business queries constrain both project and subject in SQL; a record ID in an example does not grant access.
- Composite foreign keys on Subject and service key guarantee that their project matches the project of the session.
- A scope only routes invalidation notifications; it carries no body and grants no permission; different users do not share private snapshots.
- A write transaction holds a shared lock on the session, and revocation takes an update lock. After a revocation returns successfully, later writes cannot commit with the old session.

## Anonymous principals

- Deny by default: an operation must be `kind: read` and `public: true`, and a subscription must be `public: true`; `authorize/3` is still called and can see `actor.kind == "anonymous"`.
- Marking something `public` is a declaration by the application: every viewer can see everything it returns; the framework cannot verify this for arbitrary business code.
- Each anonymous session is a new, empty principal with no user data; expired anonymous principals are deleted by the cleanup job.

## Execution authorization

When a Run is created, the initiator and an execution grant (project, operations, expiry) are recorded; **the user token is neither stored nor reused**. Expiry of the user session does not terminate an accepted run; the grant is re-checked before each new step is claimed and before each side effect is claimed, and if the grant is revoked (`Fyrlet.Runs.revoke_grant/2`) or expired, new work is refused and the run fails. Viewing, signaling and cancellation are re-authorized against the caller's current identity through `run_authorize/4`; by default only the initiator may perform them.

## Managed data access

`data_scope/3` and `Fyrlet.Scope` enforce project and subject constraints on queries and writes **that go through them**, and reject any query shape they cannot verify. Code that uses `Fyrlet.Repo` directly is not constrained; this is not database row-level security. See [SHARING.md](SHARING.md#declarative-data-scope) for details.

## Data protection

`Fyrlet.Vault` provides optional encryption at rest (AES-256-GCM, keys carry an ID and can be rotated; when a key is missing, reads fail instead of returning wrong data); an operation can declare `sensitive` fields, which are redacted in run views; `Fyrlet.Runs.Privacy.purge_subject/2` removes a person's run content while keeping identifiers, status, hashes and audit events. See [OPERATIONS.md](OPERATIONS.md#run-limits-and-data-protection).

## Lifecycle

User tokens last 600 seconds by default, and 60–900 seconds may be issued. `DELETE /api/v1/sessions/:id` lets only a project service key revoke a session in the same project; a user can sign out their own session through `DELETE /api/v1/session`. After revocation, a disconnect is broadcast, and the periodic re-check compensates for missed notifications. Data already delivered to a device cannot be erased remotely; after the SDK confirms that authentication or permission has become invalid, it clears subscription data held in memory.

`mix fyrlet.revoke_key KEY_ID` revokes a service key and stops it from issuing new sessions. Existing sessions continue until they expire or are revoked individually, so that a key rotation is not mistaken for a full user sign-out. When an emergency project-wide sign-out is needed, revoke all sessions of that project in a trusted operations procedure; there is currently no admin UI.

## Deployment boundaries

By default the server listens only on loopback locally. Production requires DATABASE_URL, SECRET_KEY_BASE and ALLOWED_ORIGINS; cross-origin HTTP uses a separate CORS_ORIGINS. Tokens are passed only in HTTPS request headers or the WSS subprotocol, never in a URL. Responses are not cached, and logs do not record request bodies or authentication headers.

Before offering the service to other developers, the deployer still needs to add gateway rate limiting, TLS, backups, key rotation and quotas. Project isolation is an implemented business boundary; it does not mean a commercial multi-tenant console or a sandbox for arbitrary tenant code has been delivered.
