import type { Subscription, SubscriptionState } from "./types.js";

export function selectSubscription<Data, Selected>(
  source: Subscription<Data>,
  selector: (data: Data) => Selected,
  equal: (left: Selected, right: Selected) => boolean = Object.is,
): Subscription<Selected> {
  let previous: SubscriptionState<Data> | undefined;
  let snapshot: SubscriptionState<Selected>;
  const getState = () => {
    const current = source.getState();
    if (current === previous) return snapshot;
    const selected = current.data === undefined ? undefined : selector(current.data);
    const data = snapshot?.data !== undefined && selected !== undefined && equal(snapshot.data, selected) ? snapshot.data : selected;
    if (!snapshot || data !== snapshot.data || current.status !== snapshot.status || current.error !== snapshot.error ||
        current.generation !== snapshot.generation || current.seq !== snapshot.seq || current.pending !== snapshot.pending || current.cursor !== snapshot.cursor) {
      snapshot = Object.freeze({ ...current, data });
    }
    previous = current;
    return snapshot;
  };
  return {
    getState,
    onChange: (listener) => source.onChange(() => listener(getState())),
    refresh: () => source.refresh(),
    confirm: (options) => source.confirm(options),
    unsubscribe: () => source.unsubscribe(),
  };
}
