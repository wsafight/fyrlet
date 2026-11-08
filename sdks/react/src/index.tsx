import { createContext, createElement, useContext, useMemo, useSyncExternalStore } from "react";
import type { ReactNode } from "react";
import { queryKey, selectSubscription } from "@fyrlet/client";
import type { Client, FyrletContract, Subscription, SubscriptionState } from "@fyrlet/client";
import { QueryStore } from "./store.js";

const ClientContext = createContext<Client<FyrletContract> | undefined>(undefined);

export function FyrletProvider<Contract extends FyrletContract>({ client, children }: { client: Client<Contract>; children?: ReactNode }) {
  return createElement(ClientContext.Provider, { value: client as unknown as Client<FyrletContract> }, children);
}

export function useFyrletClient<Contract extends FyrletContract>(): Client<Contract> {
  const client = useContext(ClientContext);
  if (!client) throw new Error("useFyrletClient requires FyrletProvider");
  return client as unknown as Client<Contract>;
}

export interface QueryOptions<Data, Selected> {
  mode?: "snapshot" | "append";
  select?: (data: Data) => Selected;
  isEqual?: (left: Selected, right: Selected) => boolean;
}

export interface QueryResult<Data, Selected> extends SubscriptionState<Selected> {
  readonly subscription: Subscription<Data> | undefined;
}

export function useQuery<
  Contract extends FyrletContract,
  Name extends keyof Contract["subscriptions"] & string,
  Selected = Contract["subscriptions"][Name]["output"],
>(
  client: Client<Contract>, name: Name, params: Contract["subscriptions"][Name]["input"],
  options: QueryOptions<Contract["subscriptions"][Name]["output"], Selected> = {},
): QueryResult<Contract["subscriptions"][Name]["output"], Selected> {
  type Data = Contract["subscriptions"][Name]["output"];
  const encoded = queryKey(params);
  const mode = options.mode ?? "snapshot";
  const store = useMemo(() => new QueryStore<Data>(client as unknown as Client<FyrletContract>, name, JSON.parse(encoded), mode), [client, name, encoded, mode]);
  const selected = useMemo(() => selectSubscription<Data, Selected>({
    getState: store.getSnapshot,
    onChange: (listener) => store.subscribe(() => listener(store.getSnapshot())),
    refresh: async () => { await store.getSubscription()?.refresh(); },
    confirm: async (request) => { await store.getSubscription()?.confirm(request); },
    unsubscribe: () => {},
  }, options.select ?? ((data) => data as unknown as Selected), options.isEqual), [store, options.select, options.isEqual]);
  const server = useMemo(() => ({ ...store.getServerSnapshot(), data: undefined }) as SubscriptionState<Selected>, [store]);
  const state = useSyncExternalStore(store.subscribe, selected.getState, () => server);
  return useMemo(() => Object.freeze({ ...state, subscription: store.getSubscription() }), [state, store]);
}
