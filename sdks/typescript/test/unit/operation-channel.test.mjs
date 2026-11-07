import test from "node:test";
import assert from "node:assert/strict";
import { createClient, ApiError, OutcomeUnknownError } from "../../dist/index.js";
import { response, TestWebSocket, until } from "../helpers.mjs";

const identity = { project_id: "project", subject_id: "alice" };

function client(context, WebSocket) {
  const instance = createClient({
    endpoint: "http://localhost:4000", projectId: "project", getToken: () => "rts_test",
    fetch: async () => response(identity), WebSocket, operationTransport: "socket", timeoutMs: 100,
  });
  context.after(() => instance.close());
  return instance;
}

for (const [failure, code] of [
  ["wrong protocol", "PROTOCOL_ERROR"], ["malformed error", "PROTOCOL_ERROR"],
  ["rejection", "CONFLICT"], ["timeout", "TIMEOUT"],
]) {
  test(`an operation join ${failure} is a definite failure and a later call can join again`, async (context) => {
    class JoinFailureSocket extends TestWebSocket {
      attempts = 0;
      send(raw) {
        const [joinRef, ref, topic, event] = JSON.parse(raw);
        if (topic === "operations" && event === "phx_join" && ++this.attempts === 1) {
          if (failure === "timeout") return;
          const reply = failure === "wrong protocol"
            ? { status: "ok", response: { protocol_version: 999 } }
            : { status: "error", response: failure === "rejection"
              ? { status: 409, error: { code: "CONFLICT", message: "Join rejected" } } : {} };
          queueMicrotask(() => this.emit([joinRef, ref, topic, "phx_reply", reply]));
          return;
        }
        super.send(raw);
      }
    }
    const instance = client(context, JoinFailureSocket);
    const mutation = instance.mutate("records.add", {}, { idempotencyKey: "first-key" });

    await assert.rejects(mutation.result, (error) => error instanceof ApiError &&
      !(error instanceof OutcomeUnknownError) && error.code === code);
    assert.equal(mutation.getState().status, "failed");
    const socket = TestWebSocket.instances.at(-1);
    assert.equal(socket.messages.filter((message) => message.event === "call").length, 0);
    await until(() => socket.messages.some((message) => message.topic === "operations" && message.event === "phx_leave"));
    const result = await instance.call("records.add", { text: "retry" }, { idempotencyKey: "second-key" });
    assert.equal(result.idempotency_key, "second-key");
    assert.deepEqual(result.input, { text: "retry" });
    assert.equal(socket.attempts, 2);
    assert.equal(socket.messages.filter((message) => message.event === "call").length, 1);
  });
}

test("concurrent socket calls share a failed join and leave a sibling subscription usable", async (context) => {
  let rejectJoin;
  let joins = 0;
  class PendingJoinSocket extends TestWebSocket {
    send(raw) {
      const [joinRef, ref, topic, event] = JSON.parse(raw);
      if (topic === "operations" && event === "phx_join" && ++joins === 1) {
        rejectJoin = () => this.emit([joinRef, ref, topic, "phx_reply", {
          status: "error", response: { status: 409, error: { code: "CONFLICT", message: "Join rejected" } },
        }]);
        return;
      }
      super.send(raw);
    }
  }
  const instance = client(context, PendingJoinSocket);
  const subscription = instance.subscribe("records.recent", {});
  await until(() => subscription.getState().status === "ready");
  const first = instance.mutate("records.add", {});
  const second = instance.mutate("records.add", {});
  const failures = Promise.all([
    assert.rejects(first.result, { code: "CONFLICT" }),
    assert.rejects(second.result, { code: "CONFLICT" }),
  ]);
  await until(() => rejectJoin);
  rejectJoin();
  await failures;

  assert.equal(joins, 1);
  assert.equal(first.getState().status, "failed");
  assert.equal(second.getState().status, "failed");
  assert.equal(subscription.getState().status, "ready");
  TestWebSocket.instances.at(-1).snapshot(["still live"]);
  assert.deepEqual(subscription.getState().data, ["still live"]);
  await instance.call("records.add", {});
  assert.equal(joins, 2);
});

test("closing while an operation is joining rejects before dispatch and ignores a late join reply", async (context) => {
  let reply;
  class PendingJoinSocket extends TestWebSocket {
    send(raw) {
      const [joinRef, ref, topic, event] = JSON.parse(raw);
      if (topic === "operations" && event === "phx_join") {
        reply = () => this.emit([joinRef, ref, topic, "phx_reply", {
          status: "ok", response: { protocol_version: 1 },
        }]);
        return;
      }
      super.send(raw);
    }
  }
  const instance = client(context, PendingJoinSocket);
  const mutation = instance.mutate("records.add", {});
  const rejected = assert.rejects(mutation.result, { name: "AbortError" });
  await until(() => reply);
  instance.close();
  await rejected;
  reply();
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(mutation.getState().status, "failed");
  assert.equal(TestWebSocket.instances.at(-1).messages.filter((message) => message.event === "call").length, 0);
});
