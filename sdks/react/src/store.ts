import { queryKey } from "@fyrlet/client";
import type { Client, FyrletContract, Subscription, SubscriptionState } from "@fyrlet/client";

const empty: SubscriptionState<never> = Object.freeze({ status: "connecting", data: undefined, error: undefined, generation: undefined, seq: 0 });
type Shared = { source: Subscription<unknown>; references: number };
const clients = new WeakMap<object, Map<string, Shared>>();

export class QueryStore<Data> {
  private shared: Shared | undefined;
  private readonly params: unknown;
  private readonly key: string;

  constructor(private readonly client: Client<FyrletContract>, private readonly name: string, params: unknown, private readonly mode: "snapshot" | "append", encoded: string = queryKey(params)) {
    this.params = JSON.parse(encoded);
    this.key = JSON.stringify([name, mode, encoded]);
  }

  getSnapshot = (): SubscriptionState<Data> => (this.shared?.source.getState() ?? empty) as SubscriptionState<Data>;
  getServerSnapshot = (): SubscriptionState<Data> => empty;
  getSubscription = (): Subscription<Data> | undefined => this.shared?.source as Subscription<Data> | undefined;

  subscribe = (listener: () => void): (() => void) => {
    let queries = clients.get(this.client);
    if (!queries) { queries = new Map(); clients.set(this.client, queries); }
    let shared = queries.get(this.key);
    if (!shared) {
      if (queries.size >= 100) throw new RangeError("React queries are limited to 100 active entries per client");
      const source = this.mode === "append" ? this.client.subscribeAppend(this.name, this.params) : this.client.subscribe(this.name, this.params);
      shared = { source, references: 0 };
      queries.set(this.key, shared);
    }
    this.shared = shared;
    shared.references++;
    const stop = shared.source.onChange(listener);
    let active = true;
    return () => {
      if (!active) return;
      active = false;
      stop();
      this.shared = undefined;
      if (--shared.references === 0) {
        queries.delete(this.key);
        shared.source.unsubscribe();
        if (queries.size === 0) clients.delete(this.client);
      }
    };
  };
}
