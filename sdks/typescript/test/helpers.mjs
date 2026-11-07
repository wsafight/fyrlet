import { setTimeout as delay } from "node:timers/promises";

export async function until(check, timeout = 5000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = check();
    if (value) return value;
    await delay(10);
  }
  throw new Error("Condition did not become true within the timeout");
}

export function response(data, status = 200) {
  return new Response(JSON.stringify(status < 400 ? { request_id: "test-request", data } : { request_id: "test-request", error: data }), {
    status, headers: { "content-type": "application/json" },
  });
}

export class TestWebSocket {
  static instances = [];
  readyState = 0;
  bufferedAmount = 0;
  messages = [];
  joins = new Map();

  constructor(url, protocols) {
    this.url = url;
    this.protocols = protocols;
    TestWebSocket.instances.push(this);
    queueMicrotask(() => { if (this.readyState === 0) { this.readyState = 1; this.onopen?.({}); } });
  }

  send(raw) {
    const [joinRef, ref, topic, event, payload] = JSON.parse(raw);
    this.messages.push({ joinRef, ref, topic, event, payload });
    if (event === "phx_join") {
      if (topic === "operations") {
        queueMicrotask(() => this.emit([joinRef, ref, topic, "phx_reply", { status: "ok", response: { protocol_version: payload.protocol_version } }]));
        return;
      }
      if (topic.startsWith("presence:")) {
        const state = { alice: [{ ref: `ref-${this.joins.size + 1}`, data: payload.meta ?? {}, joined_at: "2026-11-07T00:00:00Z" }] };
        const reply = { protocol_version: payload.protocol_version, name: payload.name, capabilities: payload.capabilities, self: "alice", state };
        this.joins.set(topic, { joinRef, snapshot: reply });
        queueMicrotask(() => this.emit([joinRef, ref, topic, "phx_reply", { status: "ok", response: reply }]));
        return;
      }
      const append = topic.startsWith("append:");
      const snapshot = append ? {
        protocol_version: payload.protocol_version, subscription_id: topic.slice("append:".length),
        generation: crypto.randomUUID(), seq: 1, cursor: "e:0", mode: "append", max_items: 3,
        project_id: "project", subject_id: "alice", data: [],
      } : {
        protocol_version: payload.protocol_version, subscription_id: topic.slice("subscription:".length),
        generation: crypto.randomUUID(), seq: 1, project_id: "project", subject_id: "alice", data: ["initial"], delivery: payload.delivery,
      };
      this.joins.set(topic, { joinRef, snapshot });
      queueMicrotask(() => this.emit([joinRef, ref, topic, "phx_reply", { status: "ok", response: snapshot }]));
    } else if (event === "ack") {
      return;
    } else if (event === "call") {
      queueMicrotask(() => this.emit([joinRef, ref, topic, "phx_reply", { status: "ok", response: { data: payload } }]));
    } else {
      queueMicrotask(() => this.emit([joinRef, ref, topic, "phx_reply", { status: "ok", response: {} }]));
    }
  }

  snapshot(data, changes = {}) {
    const [topic, entry] = [...this.joins][0];
    this.emit([entry.joinRef, null, topic, "snapshot", { ...entry.snapshot, seq: 2, data, ...changes }]);
  }

  presenceDiff(diff) {
    const [topic, entry] = [...this.joins].find(([name]) => name.startsWith("presence:"));
    this.emit([entry.joinRef, null, topic, "diff", diff]);
  }

  append(batch) {
    const [topic, entry] = [...this.joins][0];
    this.emit([entry.joinRef, null, topic, "append", batch]);
  }

  emit(frame) { this.onmessage?.({ data: JSON.stringify(frame) }); }
  close() { this.readyState = 3; queueMicrotask(() => this.onclose?.({ code: 1000 })); }
  interrupt() { this.readyState = 3; this.onclose?.({ code: 1006 }); }
}
