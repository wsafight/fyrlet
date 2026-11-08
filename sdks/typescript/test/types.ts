import { createClient } from "../src/index.js";
import type { Client, Mutation, MutationState, OutcomeUnknownError, RecoveryResult, PresenceName, PresenceInput, PresenceData, OperationNames, RetryProgress } from "../src/index.js";
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

interface RoomsContract {
  operations: {
    "room.read": { kind: "read"; input: {}; output: string };
    "room.write": { kind: "write"; input: { text: string }; output: string };
    "room.run": { kind: "run"; input: { text: string }; output: { run_id: string } };
    "room.ingest": { kind: "ingest"; input: { items: string[] }; output: { batch_id: string } };
  };
  subscriptions: {};
  presence: { "room.members": { input: { room: string }; meta: { typing: boolean } } };
}
export type RoomNames = Expect<Equal<PresenceName<RoomsContract>, "room.members">>;
export type InvalidRoomName = Expect<Equal<"wrong" extends PresenceName<RoomsContract> ? true : false, false>>;
export type InvalidRoomInput = Expect<Equal<{ room: number } extends PresenceInput<RoomsContract, "room.members"> ? true : false, false>>;
export type InvalidRoomMeta = Expect<Equal<{ typing: string } extends PresenceData<RoomsContract, "room.members"> ? true : false, false>>;
export type OperationCategory = Expect<Equal<AppContract["operations"]["inbox.add"]["kind"], "write">>;
export type ReadNames = Expect<Equal<OperationNames<RoomsContract, "read">, "room.read">>;
export type RunNames = Expect<Equal<OperationNames<RoomsContract, "run">, "room.run">>;
export type WriteNames = Expect<Equal<OperationNames<RoomsContract, "write">, "room.write">>;
export type IngestNames = Expect<Equal<OperationNames<RoomsContract, "ingest">, "room.ingest">>;
export type InvalidRunName = Expect<Equal<"room.write" extends OperationNames<RoomsContract, "run"> ? true : false, false>>;
declare const rooms: Client<RoomsContract>;
export const roster = rooms.subscribePresence("room.members", { room: "lobby" }, { typing: false });
export const typedMeta: Promise<void> = roster.update({ typing: true });
export type RosterMeta = Expect<Equal<NonNullable<ReturnType<typeof roster.getState>["data"]>[string][number]["data"]["typing"], boolean>>;
interface MissingKindContract {
  operations: { "invalid.action": { input: {}; output: string } };
  subscriptions: {};
  presence: {};
}
// @ts-expect-error Every operation must declare its kind.
export declare const missingKind: Client<MissingKindContract>;
interface MissingPresenceContract {
  operations: { "valid.read": { kind: "read"; input: {}; output: string } };
  subscriptions: {};
}
// @ts-expect-error The contract must declare presence, even when it has no rooms.
export declare const missingPresence: Client<MissingPresenceContract>;
export type NoGeneratedRooms = Expect<Equal<PresenceName<AppContract>, never>>;
export type NoGeneratedRuns = Expect<Equal<OperationNames<AppContract, "run">, never>>;
export type RequiredRoomParameter = Expect<Equal<{} extends PresenceInput<RoomsContract, "room.members"> ? true : false, false>>;
export type RequiredRoomMeta = Expect<Equal<{} extends PresenceData<RoomsContract, "room.members"> ? true : false, false>>;
export type PendingRetry = Expect<Equal<Extract<MutationState<string>, { status: "pending" }>["retry"], RetryProgress | undefined>>;
export type RunMethodNames = Expect<Equal<Parameters<typeof rooms.startRun>[0], "room.run">>;
export type RunMethodInput = Expect<Equal<Parameters<typeof rooms.startRun>[1], { text: string }>>;
export const typedRun = rooms.startRun("room.run", { text: "typed" }, { retry: { maxAttempts: 2 } });
export type RunMethodResult = Expect<Equal<Awaited<typeof typedRun>["run_id"], string>>;
