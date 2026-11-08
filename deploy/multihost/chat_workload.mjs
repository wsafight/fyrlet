import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

function messages(stream, text) {
  return (stream.getState().data ?? []).filter((message) => message.text === text);
}

async function forbidden(promise) {
  await assert.rejects(promise, (error) => error?.code === "FORBIDDEN" || error?.code === "NOT_FOUND");
}

export async function assertSubscriptionDeniedWithoutData(subscription, waitFor) {
  let exposed = false;
  const stop = subscription.onChange((state) => {
    if (state.status === "ready" || state.data !== undefined) exposed = true;
  });
  try {
    await waitFor(() => exposed || subscription.getState().status === "error");
    assert.equal(exposed, false, "An outsider subscription exposed a ready state or room data before denial");
    const code = subscription.getState().error?.code;
    assert.ok(code === "FORBIDDEN" || code === "NOT_FOUND", "Subscription denial must be an authorization failure, not a network/protocol/authentication error");
    assert.equal(subscription.getState().data, undefined, "An outsider subscription exposed room data");
  } finally {
    stop();
    subscription.unsubscribe();
  }
}

export function assertExactChatConvergence({ recovered, surviving, history, beforeId, afterId, beforeText, afterText }) {
  const expectedIds = [beforeId, afterId];
  for (const [name, stream] of [["recovered", recovered], ["surviving", surviving]]) {
    const items = stream.getState().data ?? [];
    assert.deepEqual(items.map((message) => message.id), expectedIds, `${name} subscription has a gap, duplicate or unexpected message`);
    assert.equal(items.filter((message) => message.text === beforeText).length, 1, `${name} subscription must contain the pre-fault text exactly once`);
    assert.equal(items.filter((message) => message.text === afterText).length, 1, `${name} subscription must contain the post-fault text exactly once`);
  }
  assert.deepEqual(history.items.map((message) => message.id), expectedIds, "Durable history has a gap, duplicate or unexpected message");
  assert.equal(history.items.filter((message) => message.text === beforeText).length, 1, "Durable history must contain the pre-fault text exactly once");
  assert.equal(history.items.filter((message) => message.text === afterText).length, 1, "Durable history must contain the post-fault text exactly once");
}

/** Real Chat SDK workload. Importing this module has no network or hook side effects. */
export function createWorkload(context) {
  const { config, control } = context;
  const victim = config.nodes.find((node) => node.id === config.fault.victim);
  const survivor = config.nodes.find((node) => node.id === config.fault.survivor);
  const idempotencyKey = randomUUID();
  const closeKey = randomUUID();
  const beforeText = `multihost-before-${context.drillId}`;
  const afterText = `multihost-after-${context.drillId}`;
  const idempotentInput = () => ({ room_id: room.id, text: beforeText });
  let ownerVictim;
  let ownerSurvivor;
  let colleague;
  let outsider;
  let routedOwner;
  let room;
  let roomCreationAttempted = false;
  let roomClosed = false;
  let membershipsRemoved = false;
  let recovered;
  let surviving;
  let originalRoute;
  let routeTouched = false;
  let rejoinNeeded = false;
  let beforeId;
  let generation;

  async function requireRoute(expected) {
    assert.equal(await control.getRoute(), expected, "Recovery endpoint routed to an unexpected node");
  }

  async function readyStreams() {
    await context.waitFor(() => recovered.getState().status === "ready" && surviving.getState().status === "ready");
  }

  return {
    kind: "chat",
    supportsRuns: false,

    async setup() {
      originalRoute = await control.getRoute();
      assert.ok(config.nodes.some((node) => node.id === originalRoute), "Current route is not a configured node");
      routeTouched = true;
      await control.select(victim.id);
      await requireRoute(victim.id);

      ownerVictim = await context.createUser({ nodeId: victim.id });
      ownerSurvivor = await context.createUser({ nodeId: survivor.id, subject: ownerVictim.subject });
      colleague = await context.createUser({ nodeId: survivor.id });
      outsider = await context.createUser({ nodeId: survivor.id });
      routedOwner = await context.createUser({ routed: true, subject: ownerVictim.subject });

      roomCreationAttempted = true;
      room = await ownerVictim.client.call("chat.create", { title: `Multi-host acceptance ${context.drillId}` });
      const reference = { room_id: room.id };
      await colleague.client.call("chat.join", { code: room.code });
      assert.equal((await ownerSurvivor.client.call("chat.get", reference)).id, room.id, "The new room was not visible on the survivor");
      recovered = routedOwner.client.subscribeAppend("chat.messages", reference);
      surviving = colleague.client.subscribeAppend("chat.messages", reference);
      await readyStreams();
      generation = recovered.getState().generation;
      return { drillUsersCreated: 5, crossHostRoomVisible: true, initialRouteSelected: true, subscriptionsReady: true };
    },

    async idempotency() {
      assert.ok(room && beforeText, "Workload setup is incomplete");
      const [first, second] = await Promise.all([
        ownerVictim.client.call("chat.post", idempotentInput(), { idempotencyKey }),
        ownerSurvivor.client.call("chat.post", idempotentInput(), { idempotencyKey }),
      ]);
      assert.equal(first.id, second.id, "Concurrent cross-host idempotent calls produced different messages");
      beforeId = first.id;
      await context.waitFor(() => messages(recovered, beforeText).length === 1 && messages(surviving, beforeText).length === 1);
      assert.equal(messages(recovered, beforeText)[0].id, beforeId);
      assert.equal(messages(surviving, beforeText)[0].id, beforeId);
      const history = await ownerSurvivor.client.call("chat.history", { room_id: room.id, limit: 50 });
      assert.equal(history.items.filter((message) => message.text === beforeText).length, 1, "Durable history contains a duplicate or missing write");
      return { concurrentResponsesMatched: true, durableCommitCount: 1, bothHostsObservedExactlyOneCommit: true };
    },

    async crossUserIsolation() {
      const reference = { room_id: room.id };
      await forbidden(outsider.client.call("chat.get", reference));
      await forbidden(outsider.client.call("chat.history", { ...reference, limit: 50 }));
      await forbidden(outsider.client.call("chat.post", { ...reference, text: `forbidden-${context.drillId}` }));
      const denied = outsider.client.subscribeAppend("chat.messages", reference);
      await assertSubscriptionDeniedWithoutData(denied, context.waitFor);
      return { readsDenied: true, writesDenied: true, subscriptionDeniedWithoutData: true };
    },

    async crossHostSubscriptionRecovery() {
      assert.ok(beforeId && recovered && surviving, "Pre-fault facts are not established");
      rejoinNeeded = true;
      await control.stop(victim.id);
      await context.waitFor(async () => !(await context.isReady(victim.id)) && await context.isReady(survivor.id));
      await context.waitFor(async () => await control.getRoute() === survivor.id);
      await context.waitFor(() => {
        const state = recovered.getState();
        return state.status === "ready" && state.generation !== generation && messages(recovered, beforeText).length === 1;
      });
      await context.waitFor(() => surviving.getState().status === "ready" && messages(surviving, beforeText).length === 1);
      assert.equal(messages(recovered, beforeText)[0].id, beforeId, "Recovered subscription lost or duplicated the pre-fault commit");
      return { directVictimBecameUnavailable: true, survivorRemainedReady: true, routeMovedToSurvivor: true, sameSubscriptionGenerationChanged: true, preFaultCommitPreservedExactlyOnce: true };
    },

    async writesAfterFailure() {
      const replay = await ownerSurvivor.client.call("chat.post", idempotentInput(), { idempotencyKey });
      assert.equal(replay.id, beforeId, "Replaying the pre-fault idempotency key on the survivor created a different result");
      const written = await colleague.client.call("chat.post", { room_id: room.id, text: afterText });
      await context.waitFor(() => messages(recovered, afterText).length === 1 && messages(surviving, afterText).length === 1);
      const history = await ownerSurvivor.client.call("chat.history", { room_id: room.id, limit: 50 });
      assertExactChatConvergence({ recovered, surviving, history, beforeId, afterId: written.id, beforeText, afterText });
      return { preFaultIdempotencySurvived: true, postFailureWriteCommitted: true, recoveredAndSurvivingSubscriptionsConvergedExactly: true, durableHistoryHasNoGapDuplicateOrUnexpectedMessage: true };
    },

    recoveryRequired() {
      return rejoinNeeded;
    },

    async rejoin() {
      if (!rejoinNeeded) return { alreadyJoined: true };
      await control.start(victim.id);
      await context.waitFor(() => context.isReady(victim.id));
      await context.waitFor(() => context.isReady(survivor.id));
      await context.verifyNode(victim.id);
      rejoinNeeded = false;
      return { victimStarted: true, directReadinessRestored: true, instanceAndDeploymentIdentityReconfirmed: true };
    },

    async cleanup() {
      const failures = [];
      if (rejoinNeeded) {
        try { await this.rejoin(); } catch { failures.push("victim-rejoin"); }
      }
      if (roomCreationAttempted && !room) failures.push("room-outcome-requires-operator-reconciliation");
      if (room && !roomClosed && colleague && ownerSurvivor) {
        let closed = false;
        for (const user of [colleague, ownerSurvivor, routedOwner].filter(Boolean)) {
          try {
            await user.client.call("chat.close", { room_id: room.id }, { idempotencyKey: closeKey });
            closed = true;
            break;
          } catch { /* Try another drill member with the same idempotency key. */ }
        }
        if (closed) roomClosed = true;
        else failures.push("drill-room-close");
      }
      if (room && roomClosed && !membershipsRemoved && colleague && ownerSurvivor) {
        try {
          await colleague.client.call("chat.leave", { room_id: room.id });
          await ownerSurvivor.client.call("chat.leave", { room_id: room.id });
          membershipsRemoved = true;
        } catch { failures.push("drill-membership-cleanup"); }
      }
      if (routeTouched && originalRoute) {
        try {
          await control.select(originalRoute);
          await requireRoute(originalRoute);
        } catch { failures.push("original-route-restore"); }
      }
      if (failures.length) throw new Error(`Chat cleanup incomplete: ${failures.join(",")}`);
      return { stoppedVictimRestored: !rejoinNeeded, drillRoomClosed: room ? roomClosed : null, drillMembershipsRemoved: room ? membershipsRemoved : null, originalRouteRestored: !routeTouched || Boolean(originalRoute), note: "Chat rooms are closed and emptied rather than deleted; the drill ID supports operator reconciliation if cleanup failed" };
    },
  };
}
