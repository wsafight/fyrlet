# Real multi-host failure acceptance

`scripts/multihost_acceptance.mjs` is an **opt-in runner for a real deployed Chat service**. It uses the TypeScript SDK over real HTTP/WebSocket connections and an operator-supplied executable to inspect deployment metadata, select a recovery route, stop one instance, and start it again. It does not start a local cluster, substitute in-process transports, simulate a network fault, or treat two ports on one machine as multi-host evidence.

The bundled Chat workload checks:

- concurrent cross-host write idempotency and exactly one durable commit;
- read, write, and subscription isolation for another user in the same project;
- recovery of the same routed SDK subscription with a new generation after the selected victim becomes unavailable;
- preservation of the pre-fault commit, replay of its idempotency key on the survivor, and a new write after failure;
- exact ordered convergence of the recovered subscription, surviving-host subscription, and durable drill history to the two expected writes, with no gap, duplicate, reordering, or unexpected message;
- victim start/rejoin, direct readiness, and reconfirmation of its instance/release/schema/database metadata.

No real external run is claimed by this document or by the addition of these files. The only execution supplied with the tool is its offline unit test suite.

## Trust and evidence boundaries

A passing report means that the configured checks passed in that deployment at that time. It does **not** independently prove physical topology:

- `physicalHostId`, `expectedInstanceId`, and the four attestation booleans are operator assertions.
- The runner compares them with allowlisted metadata returned by the trusted control hook. A wrong or misleading hook can produce wrong evidence.
- URLs, DNS names, IP addresses, load-balancer behavior, and different ports cannot prove that instances are on different physical hosts.
- `deployment.database` is a nonsecret canonical label such as `postgresql-cluster-a/fyrlet_chat`, not a DSN. Matching labels and hook metadata do not independently prove that PostgreSQL primaries, databases, or persistence semantics are identical.
- Release and schema checks are exact comparisons against operator-supplied expected identifiers. The runner does not derive the deployed schema or release from application URLs.
- The runner checkout fingerprint is separate from the deployed release identity. Real execution refuses a dirty checkout, rebuilds the SDK from that checkout, hashes the runtime artifact inventory, and requires the revision, clean state, source fingerprint, and runtime digest to remain unchanged.

The drill is a controlled stop/start check, not by itself a network-partition, power-loss, availability-zone, split-brain, capacity, 24-hour stability, or production-SLO test. Those claims require separately designed evidence. The route move is observed through the hook; whether it was automatic load-balancer failover or operator-controlled steering must be stated in the external change record.

## External prerequisites

Prepare every item before enabling execution:

1. **Runner host**
   - Node.js 22 or newer.
   - A **clean** checkout containing this runner and its adapters, with the TypeScript SDK dependencies already installed. Keep private configuration and reports in ignored or external paths so they do not dirty the checkout.
   - Git and npm. Before importing adapters or making network/control calls, the runner records the exact revision and source fingerprint, deletes `sdks/typescript/dist`, and rebuilds it with `npm --prefix sdks/typescript run build`; a dirty checkout or failed clean build fails closed.
   - The resulting SDK `dist`, installed Phoenix runtime, configured workload/control adapter entry modules, and control executable are hashed before execution and checked again afterward. Custom adapters' transitive dependencies remain trusted operator code and are not recursively inventoried by this digest.

2. **At least two real application instances on at least two physical hosts**
   - A release operator has attested distinct physical hosts and unique instance identities in a change/topology record.
   - The configured victim and survivor are on different attested physical hosts.
   - Each direct node endpoint serves successful `/health` and `/ready` responses and is distinct from every other direct endpoint.
   - Instances use the intended Erlang distribution/cluster configuration and trusted distribution network. The `start` hook must not return success until application readiness and the operator's cluster-rejoin checks are complete.

3. **Shared persistence and identical deployment expectations**
   - All instances are expected to use the same PostgreSQL cluster/database and the same compatible release and applied schema/migration set.
   - Record an immutable release identifier, an explicit schema/migration identifier or digest, and a nonsecret canonical database label in `deployment`.
   - The control hook must obtain the corresponding actual values from each instance or trusted deployment control plane. Do not merely echo the JSON configuration.

4. **A separate stable recovery endpoint**
   - Its WebSocket-capable load balancer can route to every configured node and serves `/health` and `/ready`.
   - It must differ from every direct node endpoint.
   - The hook can query the actual current route and select an initial victim. After the victim stops, the route must move to the configured survivor for the same SDK subscription to recover there.
   - Existing client connections must be allowed to reconnect without depending on sticky-session state on the stopped node.

5. **TLS and network access**
   - Every non-loopback direct and routed endpoint must use HTTPS. Credentials, URL queries, and fragments are rejected.
   - Loopback endpoints are rejected by default. `execution.allowLoopbackEndpoints=true` exists only for an operator-managed tunnel to the real attested deployment; it still does not prove topology and must not be used to relabel a local simulation as multi-host acceptance.
   - The runner host can reach all direct endpoints, the recovery endpoint, and the control executable's own control-plane dependencies.

6. **A dedicated acceptance project and credentials**
   - Use an isolated/disposable project and a planned fault window. The drill creates users, sessions, a room, memberships, and messages and deliberately interrupts one instance.
   - Supply the project ID and backend service key only through the environment variables named by `project.projectIdEnv` and `project.serviceKeyEnv`.
   - The service key must be able to issue and revoke sessions. It is never placed in the JSON configuration or report. Session tokens, refreshed sessions, room invitation codes, and SDK error payloads are not reported.

7. **A trusted operator control executable**
   - Install it at an absolute path and test its authorization and targeting independently.
   - It must target the unique instance represented by each configured node ID, not infer physical identity from a URL.
   - Hook credentials belong in the executable's own protected configuration or a secret manager it accesses directly, never in `fixedArgs`, adapter paths, node metadata, reports, command strings, or inherited credential environment variables. The adapter removes the configured project variables and common credential-like environment names before starting the hook.

## Configuration

Start with [`deploy/multihost/chat.example.json`](../deploy/multihost/chat.example.json). Copy it into a private local working file and replace every placeholder. The checked-in example deliberately has:

```json
"realMultiHostOptIn": false
```

Validation is strict: unknown or missing fields, duplicate node IDs/endpoints/instance identities, fewer than two attested physical hosts, an unresolved victim/survivor, same-host victim/survivor, a recovery endpoint equal to a direct endpoint, credential-looking values, DSNs, relative hook paths, and reserved or credential-bearing fixed arguments fail closed.

Adapter references are relative to the configuration file. The example keeps them beside the bundled adapters. If the configuration is copied elsewhere, either preserve the relative layout or use the correct relative paths to `executable_control.mjs` and `chat_workload.mjs`.

`workload.runs` is `false` for the bundled Chat workload because Chat does not provide the Agent Runs workflow. Runs are then reported as optional `not-run`. If Runs are set to `true`, they become required and the adapter must declare `supportsRuns: true` and implement `runs()`; otherwise prerequisites fail. No Runs result is inferred from Chat checks.

## Control-hook contract

The bundled `deploy/multihost/executable_control.mjs` invokes the configured executable directly with `execFile`, `shell: false`, a timeout, and a 64 KiB output limit. There is no shell interpolation. The argument array is:

```text
[...fixedArgs, ACTION, ...ACTION_ARGUMENTS]
```

Node IDs match `[A-Za-z0-9][A-Za-z0-9_.-]{0,63}` and are passed as separate arguments. `fixedArgs` cannot override `--node` or an action. The hook receives a filtered copy of the process environment: the configured project ID/service-key variables and names matching common credential patterns are removed. This is secret-egress defense in depth, not a complete secret classifier. The adapter never records the environment, raw stdout/stderr, or raw hook error messages.

| Invocation after `fixedArgs` | Required behavior | Stdout contract |
| --- | --- | --- |
| `get-route` | Return the actual current target of the stable recovery endpoint, not merely a desired value. | `{"nodeId":"node-a"}` |
| `inspect --node NODE` | Read actual instance and deployment metadata from the target or trusted control plane. | JSON shown below |
| `select --node NODE` | Route the recovery endpoint to the selected configured node and wait until the route is effective. Return nonzero on any ambiguity or partial failure. | Ignored and discarded |
| `stop --node NODE` | Controlled stop or fencing of exactly the selected unique instance. Do not target the survivor or unrelated resources. Return only after the stop/fence operation is effective; the runner independently requires direct readiness to disappear and the route to move. | Ignored and discarded |
| `start --node NODE` | Start/unfence exactly that instance, wait for application and operator-defined cluster rejoin, and return zero only when it is ready for inspection. | Ignored and discarded |

`inspect` returns these required string fields:

```json
{
  "instanceId": "provider-instance-a",
  "physicalHostId": "physical-host-a",
  "release": "chat@sha256:actual-immutable-release",
  "schema": "migrations-sha256:actual-schema",
  "database": "postgresql-cluster-a/fyrlet_chat"
}
```

Extra hook fields are ignored, not copied into reports. Missing, malformed, oversized, credential-looking, or ambiguous values fail the scenario. A nonzero exit, timeout, or invalid JSON also fails. The runner records only action, configured node ID, timestamps/duration, pass/fail, and a numeric exit code when available.

The original route is read before setup. Cleanup attempts to start an unrejoined victim and restore that original route even after a failed scenario. The hook should be safe to retry after a partially completed stop/start/select operation.

## Running

### Offline configuration check

Use a fresh report directory; reports are never overwritten:

```sh
node scripts/multihost_acceptance.mjs \
  --config deploy/multihost/chat.example.json \
  --out .local/readiness/multihost-config-check
```

This mode does not read credential values, import the SDK/adapters, access endpoints, inspect source deployment metadata, or invoke the hook. A valid configuration produces overall `not-run`, never `passed`, and exits **2**. Invalid configuration exits **1**. Configuration success is only the status of the `configuration` scenario, not multi-host acceptance.

### Real drill (external operators only)

After completing every prerequisite, editing all placeholders, reviewing the hook, and setting `execution.realMultiHostOptIn` to `true` in the private copy:

```sh
export FYRLET_MULTIHOST_PROJECT_ID='project-id-from-the-dedicated-project'
export FYRLET_MULTIHOST_SERVICE_KEY='backend-service-key-from-a-secret-manager'

node scripts/multihost_acceptance.mjs \
  --config .local/multihost/chat.real.json \
  --out .local/readiness/multihost-real-001 \
  --execute-real-multihost
```

Both the CLI flag and the JSON opt-in are required. Without either one, no real network request or control action is attempted and the result is incomplete. With both opt-ins, credential presence is checked first, then a clean checkout is required before the SDK rebuild, artifact hashing, or adapter import. The command above is an operator example, **not an execution record for this repository change**.

## Statuses and exit codes

Every scenario has `passed`, `failed`, or `not-run` plus a reason. Required scenarios cover configuration, runtime prerequisites, runner source, topology, setup, idempotency, cross-user isolation, routed subscription recovery, writes after failure, node rejoin, cleanup, and unchanged runner sources/runtime artifacts. Runs are required only when configured and supported.

| Overall status | Meaning | Exit |
| --- | --- | ---: |
| `passed` | Every required scenario passed and no optional attempted scenario failed. Optional unsupported/unrequested Runs may remain `not-run`. | 0 |
| `failed` | Any scenario failed, including cleanup or source-stability failure. | 1 |
| `not-run` | No scenario failed, but at least one required scenario is incomplete or real execution was not enabled. | 2 |

A local preflight can never produce overall acceptance `passed`. A passing status is not a capacity or physical-topology certification.

## Private reports and source metadata

The report directory is forced to mode `0700`; `result.json` is written mode `0600`, without overwriting an existing report, and replaced through a private temporary file. Reports are checkpointed after configuration and scenarios. Before the final aggregation, an interrupted checkpoint remains `not-run`, not an implied pass.

On SIGINT/SIGTERM the runner stops starting new acceptance scenarios and waits for the current bounded operation, while still allowing victim rejoin, cleanup, and source finalization. An interrupted drill cannot aggregate to `passed`, even if cleanup passes. A second signal or external kill can force termination, so operators must still verify deployment state after any interruption.

Reports include:

- a random drill ID, timings, scenario reasons/assertion facts, and bounded control events;
- configuration SHA-256 and nonsecret adapter summaries, rather than a copy of secret-bearing configuration;
- runner Git revision, clean/dirty state, source fingerprint, Node version, final revision/fingerprint/state comparison, and the initial/final SHA-256 runtime artifact digest and file count;
- expected deployment release/schema/database labels, operator attestation, direct/routed endpoints, and allowlisted observed node metadata;
- the explicit topology caveat.

Recursive redaction covers common credential keys and token/DSN/Bearer forms. Raw SDK responses, tokens, service keys, invitation codes, session IDs, subjects, message contents, and hook output are not report fields. Avoid pasting private reports into public issues; redaction is defense in depth, not a substitute for review.

## Cleanup and failure handling

The runner tracks only users/sessions/resources created by the current drill. It does not enumerate or delete pre-existing rooms or users. Best-effort cleanup:

1. starts and verifies the victim if it remains stopped;
2. closes the drill room and removes the drill owner/colleague memberships;
3. restores the original recovery route;
4. closes every SDK client and revokes every session issued by the drill, including refreshes, through the stable endpoint.

Session issue and revoke calls have independent timeouts and abort signals. A failed, timed-out, or malformed issuance response is treated as an **unknown issuance outcome**, not as proof that no session exists. If such a call later succeeds, the runner attempts to revoke the late session, but cleanup still fails and never claims that all sessions were revoked. Cleanup also closes issuance before closing clients, waits for bounded in-flight issue operations, and revokes every known session ID.

Chat has no room-delete operation, so an empty closed room remains. The room title contains the report's drill ID for operator reconciliation. If room creation had an unknown outcome, or rejoin/routing/room/membership/session cleanup fails, cleanup fails and overall acceptance fails. Operators must inspect and reconcile the deployment using the drill ID and their private control-plane records; the runner does not claim complete cleanup in that case.

## Custom workload adapters

A custom adapter is trusted local code and is loaded only after both real opt-ins. Imports and factory creation should have no network or control side effects; real work belongs in scenario methods. The module exports:

```js
export function createWorkload(context) {
  return {
    kind: "chat",                 // Must equal workload.kind.
    supportsRuns: false,
    async setup() {},
    async idempotency() {},
    async crossUserIsolation() {},
    async crossHostSubscriptionRecovery() {},
    async writesAfterFailure() {},
    async runs() {},              // Called only when required and supported.
    recoveryRequired() { return false; },
    async rejoin() {},
    async cleanup() {},
  };
}
```

`context` provides the validated config, drill ID, `control`, bounded `waitFor`, direct-node `isReady`, `verifyNode`, and `createUser`. `createUser({nodeId})` creates a direct SDK user; `createUser({routed:true})` uses the recovery endpoint; passing an earlier `subject` creates another session/client for that same user. Clients and all issued sessions are tracked centrally. Adapter return values must contain only nonsecret assertion facts, never raw service responses or credentials.

A Runs adapter must genuinely exercise the configured Runs API and ownership/durability checks. Setting `supportsRuns` without implementing the required method fails closed.

## Offline tests

Run only the offline suite when developing the runner:

```sh
node --test scripts/multihost_acceptance.test.mjs
```

The tests use temporary files, stubbed session services, subscription fixtures, and stubbed control executors. They cover strict validation, canonical loopback forms, topology metadata, redaction, statuses/exit codes, report permissions, dual opt-in, fail-closed prerequisites, fixed argv, filtered hook environments, output redaction, deterministic runtime hashes, exact stream/history convergence, authorization-only subscription denial, session timeout/refresh/revocation, and late or malformed issuance outcomes. They do not open real endpoints or execute real control hooks.
