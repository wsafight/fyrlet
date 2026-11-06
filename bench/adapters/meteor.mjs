import { until } from "../lib/async.mjs";
import { trafficMeter } from "../lib/transport.mjs";

export const capabilities = {
  transport: "DDP v1 raw WebSocket", database: "MongoDB replica set",
  synchronization: "Meteor cursor publication + added/changed/removed deltas",
  idempotency: "MongoDB transaction; success result retained 24h", notification: "Meteor Mongo observer driver; record configuration separately",
  client: "benchmark-only Node DDP materializer with explicit reconnect/session resumption; no Minimongo, optimistic stubs or automatic reconnect",
  authorization: "session checked at methods/publication join; expiry timer stops publications; no per-change database reauthorization or revocation/write serialization",
};

export function decodeFields(fields = {}) {
  return Object.fromEntries(Object.entries(fields).map(([name, value]) => [name,
    ["inserted_at", "updated_at"].includes(name) && value && typeof value === "object" && "$date" in value
      ? new Date(value.$date).toISOString() : value,
  ]));
}

export class DDPConnection {
  constructor(endpoint, network, timeoutMs) {
    this.endpoint = endpoint;
    this.network = network;
    this.timeoutMs = timeoutMs;
    this.pending = new Map();
    this.records = new Map();
    this.listeners = new Set();
    this.state = { status: "connecting", data: undefined };
    this.receivedCount = 0;
  }
  emit(status) {
    this.state = {
      status, error: status === "error" ? this.failure : undefined,
      data: status === "ready" ? [...this.records.values()].sort((left, right) => right.inserted_at.localeCompare(left.inserted_at) || right.id.localeCompare(left.id))
        : status === "recovering" ? this.state.data : undefined,
    };
    for (const listener of this.listeners) listener(this.state);
  }
  async open() {
    this.connected = false;
    this.failure = undefined;
    const url = new URL("websocket", `${this.endpoint.replace(/\/$/, "")}/`);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    this.socket = new this.network.WebSocket(url);
    const socket = this.socket;
    this.socket.onopen = () => {
      if (this.socket === socket) this.send({ msg: "connect", version: "1", support: ["1"],
        ...(this.sessionId ? { session: this.sessionId, receivedCount: this.receivedCount } : {}) });
    };
    this.socket.onmessage = (event) => {
      if (this.socket !== socket) return;
      try { this.receive(JSON.parse(event.data)); }
      catch (error) { this.failure = error; this.emit("error"); }
    };
    this.socket.onerror = (event) => {
      if (this.socket === socket) this.failure = new Error(`DDP transport error: ${event.error?.message ?? "unknown"}`);
    };
    this.socket.onclose = (event) => {
      if (this.socket !== socket) return;
      this.connected = false;
      this.failure ??= new Error(`DDP disconnected (${event.code}: ${event.reason || "no reason"})`);
      for (const request of this.pending.values()) { clearTimeout(request.timer); request.reject(new Error("DDP disconnected")); }
      this.pending.clear();
      if (!this.closed) this.emit(this.intentionalOffline ? "recovering" : "error");
    };
    await until(() => { if (this.failure) throw this.failure; return this.connected; }, this.timeoutMs, "DDP connection");
  }
  send(message) { this.socket.send(JSON.stringify(message)); }
  receive(message) {
    if (!["ping", "pong"].includes(message.msg)) this.receivedCount++;
    if (message.msg === "connected") {
      this.resumed = Boolean(this.sessionId) && this.sessionId === message.session;
      if (!this.resumed) {
        this.records.clear();
        this.receivedCount = 1;
      }
      this.sessionId = message.session;
      this.connected = true;
      if (this.resumed && this.subscriptionId) this.emit("ready");
    }
    else if (message.msg === "ping") this.send({ msg: "pong", ...(message.id ? { id: message.id } : {}) });
    else if (message.msg === "failed" || message.msg === "error" || message.msg === "nosub") {
      this.failure = new Error(`DDP ${message.msg}: ${message.error?.error ?? message.reason ?? "protocol error"}`);
      this.emit("error");
    } else if (message.msg === "result") {
      const request = this.pending.get(message.id);
      if (request) {
        request.received = true;
        request.value = message.result;
        if (message.error) {
          const error = new Error(message.error.reason ?? "Meteor method failed");
          error.code = String(message.error.error);
          clearTimeout(request.timer); this.pending.delete(message.id); request.reject(error);
        } else this.complete(message.id);
      }
    } else if (message.msg === "updated") {
      for (const identifier of message.methods) {
        const request = this.pending.get(identifier);
        if (request) { request.updated = true; this.complete(identifier); }
      }
    } else if (message.msg === "added") {
      this.records.set(message.id, { ...decodeFields(message.fields), id: message.id });
      if (this.state.status === "ready") this.emit("ready");
    } else if (message.msg === "changed") {
      const previous = this.records.get(message.id);
      if (!previous) throw new Error("DDP changed an unknown record");
      const next = { ...previous, ...decodeFields(message.fields) };
      for (const field of message.cleared ?? []) delete next[field];
      this.records.set(message.id, next);
      if (this.state.status === "ready") this.emit("ready");
    } else if (message.msg === "removed") {
      this.records.delete(message.id);
      if (this.state.status === "ready") this.emit("ready");
    } else if (message.msg === "ready" && message.subs.includes(this.subscriptionId)) this.emit("ready");
  }
  complete(identifier) {
    const request = this.pending.get(identifier);
    if (request.received && request.updated) {
      clearTimeout(request.timer); this.pending.delete(identifier); request.resolve(request.value);
    }
  }
  call(method, params) {
    const id = crypto.randomUUID();
    return new Promise((resolveRequest, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`DDP method ${method} timed out`)); }, this.timeoutMs);
      this.pending.set(id, { resolve: resolveRequest, reject, timer, received: false, updated: false });
      try { this.send({ msg: "method", method, params, id }); }
      catch (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
    });
  }
  subscribe(rows) {
    this.subscriptionId = crypto.randomUUID();
    this.send({ msg: "sub", id: this.subscriptionId, name: "inbox.recent", params: [rows] });
  }
  close() {
    this.closed = true;
    for (const request of this.pending.values()) { clearTimeout(request.timer); request.reject(new Error("DDP client closed")); }
    this.pending.clear();
    this.listeners.clear();
    if (this.connected && this.socket?.readyState === 1) this.send({ msg: "disconnect" });
    this.socket?.close();
  }
}

export async function connect({ endpoint, fixture, user, network, timeoutMs, observe = true }) {
  const connection = new DDPConnection(endpoint, network, timeoutMs);
  const start = async () => {
    await connection.open();
    if (!connection.resumed) {
      await connection.call("bench.login", [user.token]);
      if (observe) connection.subscribe(fixture.rows);
    }
  };
  try { await start(); } catch (error) { connection.close(); throw error; }
  return {
    getState: () => connection.state,
    onChange: (listener) => { connection.listeners.add(listener); listener(connection.state); return () => connection.listeners.delete(listener); },
    update: (item, text) => connection.call("inbox.update", [{ id: item.id, text, expected_version: item.version }, crypto.randomUUID()]),
    offline: async () => { connection.intentionalOffline = true; connection.emit("recovering"); connection.network.disconnect(); },
    online: async () => { connection.intentionalOffline = false; await start(); },
    close: () => connection.close(),
  };
}

export async function seed({ endpoint, secret, runId, users, rows, payloadBytes, devices, sessions, timeoutMs }) {
  const connection = new DDPConnection(endpoint, trafficMeter(), timeoutMs);
  try { await connection.open(); return await connection.call("bench.seed", [secret, runId, users, rows, payloadBytes, devices, sessions]); }
  finally { connection.close(); }
}

export async function cleanup({ endpoint, secret, runId, network, timeoutMs }) {
  const connection = new DDPConnection(endpoint, network, timeoutMs);
  try { await connection.open(); await connection.call("bench.cleanup", [secret, runId]); }
  finally { connection.close(); }
}

export async function runtimeStats({ endpoint, timeoutMs }) {
  const response = await fetch(`${endpoint}/__bench/health`, { signal: AbortSignal.timeout(timeoutMs) });
  if (!response.ok) throw new Error("Meteor diagnostics are unavailable");
  return response.json();
}
