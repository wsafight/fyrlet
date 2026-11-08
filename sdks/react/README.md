# Fyrlet React adapter

English | [简体中文](README.zh-CN.md)

`@fyrlet/react` is an independent React 18.3 and 19 adapter in the initial formal release scope; it has not yet been published. The TypeScript core remains framework independent. Build the core before this package:

```sh
npm --prefix sdks/typescript ci
npm --prefix sdks/typescript run build
npm --prefix sdks/react ci
npm --prefix sdks/react test
npm --prefix sdks/react run typecheck
npm --prefix sdks/react run test:coverage
```

## Query hooks

```tsx
import { FyrletProvider, useFyrletClient, useQuery } from "@fyrlet/react";
import type { AppContract } from "@fyrlet/client/example-contract";

function Inbox() {
  const client = useFyrletClient<AppContract>();
  const recent = useQuery(client, "inbox.recent", { limit: 20 });
  return <ul>{recent.data?.map((item) => <li key={item.id}>{item.text}</li>)}</ul>;
}

function Application({ client }: { client: import("@fyrlet/client").Client<AppContract> }) {
  return <FyrletProvider client={client}><Inbox /></FyrletProvider>;
}
```

`useQuery(client, name, params, options?)` infers inputs and results from the client contract. Options are `mode: "snapshot" | "append"`, a pure `select(data)` function and `isEqual(left, right)` for retaining equal selected values. Append still requires declaring the server's `append` capability. The result contains the SDK subscription state and `subscription`, which is initially undefined and becomes available after commit. Use that handle as a mutation's `optimistic` or `confirm` target. The hook owns its lifetime; do not call `unsubscribe()` on it.

Queries within one client share a subscription even when the core's `shareSubscriptions` option is off. Names, canonical JSON parameters and delivery modes define identity. The adapter limits each client to 100 active queries; parameters have the core's 64 KiB limit. Releasing one component leaves other consumers active; the final release immediately unsubscribes and deletes the entry. No inactive cache is retained. Enable core query sharing as well when combining hooks and direct SDK subscriptions.

`useFyrletClient<Contract>()` reads the provider; passing a client directly to `useQuery` also works without a provider. The provider does not create or close clients. The application owns the client, closes it on logout or identity changes, and creates a new instance for the next identity. Presence remains a separately managed SDK handle.

## SSR and lifecycle

The adapter uses `useSyncExternalStore`. Rendering creates no subscription, including abandoned or suspended renders. Unchanged snapshots retain references. Strict Mode cleanup/re-subscribe, parameter changes and unmount release their references.

Server rendering and the first hydration snapshot use a deterministic empty `connecting` state, with no data or active subscriptions. There is no preloaded server-data API. Create clients per request and per authenticated browser session; never reuse a server client across users. Private entries are held only for active subscriptions and are scoped by the client object.

The [Suiji with OIDC login](../../examples/inbox-react/README.md) demonstrates two consumers of the same query, parameter changes, optimistic writes, authoritative view confirmation, optional retries and account cleanup. For distribution, `bash scripts/package.sh` creates both client and React tarballs; install both together with React before using the adapter outside this repository. TypeScript consumers must also install `@types/react` and `@types/phoenix` for the React and Phoenix declarations referenced by the packed types.
