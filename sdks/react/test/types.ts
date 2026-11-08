import { createClient } from "@fyrlet/client";
import type { Subscription } from "@fyrlet/client";
import type { AppContract } from "@fyrlet/client/example-contract";
import { useQuery } from "../src/index.js";

type Expect<Condition extends true> = Condition;
type Equal<Left, Right> = [Left, Right] extends [Right, Left] ? true : false;
type Recent = AppContract["subscriptions"]["inbox.recent"];
export type QueryNames = Expect<Equal<Parameters<typeof useQuery<AppContract, "inbox.recent">>[1], "inbox.recent">>;
export type QueryInput = Expect<Equal<Parameters<typeof useQuery<AppContract, "inbox.recent">>[2], Recent["input"]>>;
export type InvalidQueryName = Expect<Equal<"wrong" extends Parameters<typeof useQuery<AppContract, "inbox.recent">>[1] ? true : false, false>>;
export type InvalidQueryParameter = Expect<Equal<{ limit: string } extends Recent["input"] ? true : false, false>>;
const client = createClient<AppContract>({ endpoint: "http://localhost:4000", projectId: "project", getToken: () => "rts_token" });
export function Component() {
  const query = useQuery(client, "inbox.recent", { limit: 20 });
  const count = useQuery(client, "inbox.recent", {}, { select: (items) => items.length });
  const selected = useQuery(client, "inbox.recent", {}, {
    select: (items) => ({ ids: items.map((item) => item.id), total: items.length }),
    isEqual: (left, right) => left.total === right.total && left.ids.every((identifier, index) => identifier === right.ids[index]),
  });
  type Count = Expect<Equal<typeof count.data, number | undefined>>;
  type Data = Expect<Equal<typeof query.data, AppContract["subscriptions"]["inbox.recent"]["output"] | undefined>>;
  type SourceHandle = Expect<Equal<typeof count.subscription, Subscription<Recent["output"]> | undefined>>;
  type SelectedObject = Expect<Equal<typeof selected.data, { ids: string[]; total: number } | undefined>>;
  return null as Count | Data | SourceHandle | SelectedObject | null;
}
