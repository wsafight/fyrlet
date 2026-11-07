import { createClient } from "../src/index.js";
import type { Mutation, MutationState, OutcomeUnknownError, RecoveryResult } from "../src/index.js";
import type { AppContract } from "../src/generated/app.js";

type Expect<Condition extends true> = Condition;
type Equal<Left, Right> = [Left, Right] extends [Right, Left] ? true : false;
export type ContractNames = Expect<Equal<keyof AppContract["subscriptions"], "inbox.recent">>;
export type AddRequiresText = Expect<Equal<{} extends AppContract["operations"]["inbox.add"]["input"] ? true : false, false>>;
export type RecentAllowsDefaults = Expect<Equal<{} extends AppContract["subscriptions"]["inbox.recent"]["input"] ? true : false, true>>;
export type InvalidContentType = Expect<Equal<{ text: string; content_type: "wrong" } extends AppContract["operations"]["inbox.add"]["input"] ? true : false, false>>;

const client = createClient<AppContract>({ endpoint: "http://localhost:4000", projectId: "project", getToken: () => "rts_test" });
export const operation: Promise<AppContract["operations"]["inbox.add"]["output"]> = client.call("inbox.add", { text: "typed" });
export const subscription = client.subscribe("inbox.recent", { limit: 20 });
export const mutation: Mutation<AppContract["operations"]["inbox.add"]["output"]> = client.mutate("inbox.add", { text: "typed" });
export const recovery: Promise<RecoveryResult<AppContract["operations"]["inbox.add"]["output"]>> =
  client.recover("inbox.add", { text: "typed" }, { idempotencyKey: mutation.idempotencyKey });
export type MutationInput = Expect<Equal<Parameters<typeof client.mutate<"inbox.add">>[1], AppContract["operations"]["inbox.add"]["input"]>>;
export type RecoveryRequiresKey = Expect<Equal<{} extends Parameters<typeof client.recover<"inbox.add">>[2] ? true : false, false>>;
export type UnknownMutationError = Expect<Equal<Extract<MutationState<string>, { status: "unknown" }>["error"], OutcomeUnknownError>>;
client.close();
