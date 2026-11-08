import type { Channel } from "phoenix";
import { ApiError } from "./errors.js";
import { applyDelta, immutable } from "./delta.js";
import { PROTOCOL_VERSION } from "./protocol.js";
import type { Identity } from "./protocol.js";
import type { ClientOptions, PresenceMeta, PresenceRoster, SubscriptionState } from "./types.js";

interface Snapshot extends Identity {
  protocol_version: number;
  subscription_id: string;
  generation: string;
  seq: number;
  data: unknown;
  delivery?: string;
  capabilities?: Record<string, number>;
  confirmed?: unknown;
}

interface AppendSnapshot extends Snapshot {
  cursor: string;
  mode: string;
  max_items: number;
}

interface AppendBatch { g: unknown; s: unknown; base_cursor: unknown; cursor: unknown; items: unknown }

export interface Overlay {
  update: (data: unknown) => unknown;
  settled: boolean;
  timer: ReturnType<typeof setTimeout> | undefined;
}

interface Confirmation {
  overlays: readonly Overlay[];
  finish(error?: unknown): void;
}

type Delivery = { generation: unknown; sequence: unknown; cursor?: string } | "refresh" | "reconnect" | undefined;
export type SubscriptionEvent = "snapshot" | "delta" | "append" | "presence_state" | "presence_diff";

const MAX_APPEND_ITEMS = 1_000;

function checkRoster(value: unknown): Record<string, PresenceMeta[]> | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  for (const metas of Object.values(value)) {
    if (!Array.isArray(metas)) return undefined;
    for (const meta of metas) {
      if (!meta || typeof meta !== "object" || typeof meta.ref !== "string" ||
          !meta.data || typeof meta.data !== "object" || Array.isArray(meta.data)) return undefined;
    }
  }
  return value as Record<string, PresenceMeta[]>;
}

export class SubscriptionEntry {
  state: SubscriptionState<unknown> = {
    status: "connecting", data: undefined, error: undefined, generation: undefined, seq: 0,
  };
  readonly listeners = new Set<(state: SubscriptionState<unknown>) => void>();
  channel: Channel | undefined;
  joinFailures = 0;
  private delta = false;
  private confirmationSupported = false;
  private readonly confirmations = new Map<string, Confirmation>();
  private readonly append: { cursor: string | undefined; maxItems: number; desynced: boolean } | undefined;
  private overlays: Overlay[] = [];
  private overlayVersion = 0;
  private shown: { base: SubscriptionState<unknown>; version: number; value: SubscriptionState<unknown> } | undefined;

  constructor(
    readonly id: string,
    readonly name: string,
    readonly params: unknown,
    private readonly options: ClientOptions,
    readonly appendMode: boolean,
    readonly presence?: { meta: Record<string, unknown>; self: string | undefined },
  ) {
    this.append = appendMode ? { cursor: undefined, maxItems: 0, desynced: false } : undefined;
  }

  receive(event: SubscriptionEvent, payload: unknown, identity: Identity | undefined, initial = false): Delivery {
    switch (event) {
      case "snapshot": return this.append ? this.applyAppendSnapshot(payload as AppendSnapshot, identity, initial)
        : this.applySnapshot(payload as Snapshot, identity, initial);
      case "delta": return this.applyPatch(payload);
      case "append": return this.applyAppend(payload as AppendBatch);
      case "presence_state": this.applyPresenceState(payload); return;
      case "presence_diff": this.applyPresenceDiff(payload); return;
    }
  }

  private applySnapshot(snapshot: Snapshot, identity: Identity | undefined, initial: boolean): Delivery {
    if (!snapshot || snapshot.protocol_version !== PROTOCOL_VERSION || snapshot.subscription_id !== this.id ||
        snapshot.project_id !== identity?.project_id || snapshot.subject_id !== identity?.subject_id ||
        typeof snapshot.generation !== "string" || !Number.isSafeInteger(snapshot.seq) || snapshot.seq < 1 || !("data" in snapshot)) {
      throw new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid subscription snapshot" });
    }
    if (!initial && snapshot.generation !== this.state.generation) return;
    if (initial) {
      this.delta = snapshot.delivery === "delta-v1";
      this.confirmationSupported = snapshot.capabilities?.view_confirmation === 1;
    }
    if (initial || snapshot.seq > this.state.seq) {
      this.applyConfirmed(snapshot, { status: "ready", data: immutable(snapshot.data), generation: snapshot.generation, seq: snapshot.seq, error: undefined });
    }
    return { generation: snapshot.generation, sequence: snapshot.seq };
  }

  private applyPatch(payload: unknown): Delivery {
    if (!payload || typeof payload !== "object") {
      throw new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid subscription delta" });
    }
    const delta = payload as { g?: unknown; s?: unknown; b?: unknown; p?: unknown };
    if (delta.g !== this.state.generation) return;
    if (!this.delta || !Number.isSafeInteger(delta.s) || !Number.isSafeInteger(delta.b) ||
        (delta.s as number) < 2 || (delta.b as number) < 1 || delta.s !== (delta.b as number) + 1) {
      throw new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid subscription delta sequence" });
    }
    if ((delta.s as number) <= this.state.seq) return { generation: delta.g, sequence: delta.s };
    if (delta.b !== this.state.seq) return "reconnect";
    try {
      const data = applyDelta(this.state.data, delta.p);
      this.setState({ status: "ready", data, generation: this.state.generation, seq: delta.s as number, error: undefined });
    } catch {
      throw new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid subscription delta" });
    }
    return { generation: delta.g, sequence: delta.s };
  }

  private applyAppendSnapshot(snapshot: AppendSnapshot, identity: Identity | undefined, initial: boolean): Delivery {
    const append = this.append;
    if (!append || !snapshot || snapshot.protocol_version !== PROTOCOL_VERSION || snapshot.mode !== "append" ||
        snapshot.subscription_id !== this.id || snapshot.project_id !== identity?.project_id ||
        snapshot.subject_id !== identity?.subject_id || typeof snapshot.generation !== "string" ||
        !Number.isSafeInteger(snapshot.seq) || snapshot.seq < 1 || typeof snapshot.cursor !== "string" ||
        !Number.isSafeInteger(snapshot.max_items) || snapshot.max_items < 1 || !Array.isArray(snapshot.data) ||
        snapshot.data.length > snapshot.max_items) {
      throw new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid append snapshot" });
    }
    if (!initial && (snapshot.generation !== this.state.generation || snapshot.seq <= this.state.seq)) return;
    if (initial) this.confirmationSupported = snapshot.capabilities?.view_confirmation === 1;
    append.cursor = snapshot.cursor;
    append.maxItems = snapshot.max_items;
    append.desynced = false;
    this.applyConfirmed(snapshot, {
      status: "ready", data: immutable(snapshot.data), generation: snapshot.generation, seq: snapshot.seq,
      cursor: snapshot.cursor, error: undefined,
    });
    return { generation: snapshot.generation, sequence: snapshot.seq, cursor: snapshot.cursor };
  }

  private applyAppend(batch: AppendBatch): Delivery {
    const append = this.append;
    if (!append || !batch || typeof batch !== "object") {
      throw new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid append batch" });
    }
    if (batch.g !== this.state.generation || append.desynced) return;
    if (!Number.isSafeInteger(batch.s) || typeof batch.base_cursor !== "string" || typeof batch.cursor !== "string" ||
        !Array.isArray(batch.items) || batch.items.length > MAX_APPEND_ITEMS) {
      throw new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid append batch" });
    }
    const sequence = batch.s as number;
    if (sequence <= this.state.seq) return;
    if (sequence !== this.state.seq + 1 || batch.base_cursor !== append.cursor) {
      append.desynced = true;
      return "refresh";
    }
    const data = [...(this.state.data as unknown[]), ...batch.items].slice(-append.maxItems);
    append.cursor = batch.cursor;
    this.setState({
      status: "ready", data: immutable(data), generation: this.state.generation, seq: sequence, cursor: batch.cursor, error: undefined,
    });
    return { generation: batch.g, sequence, cursor: batch.cursor };
  }

  private applyPresenceState(reply: unknown): void {
    const body = reply as { protocol_version?: unknown; self?: unknown; state?: unknown } | undefined;
    const roster = body && body.protocol_version === PROTOCOL_VERSION && typeof body.self === "string" ? checkRoster(body.state) : undefined;
    if (!roster || !this.presence) throw new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid presence state" });
    this.presence.self = body!.self as string;
    this.setState({ status: "ready", data: immutable(roster), generation: undefined, seq: this.state.seq + 1, error: undefined });
  }

  private applyPresenceDiff(payload: unknown): void {
    const diff = payload as { joins?: unknown; leaves?: unknown } | undefined;
    const joins = diff ? checkRoster(diff.joins) : undefined;
    const leaves = diff ? checkRoster(diff.leaves) : undefined;
    if (!joins || !leaves) throw new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid presence diff" });
    const next = new Map<string, PresenceMeta[]>(
      Object.entries((this.state.data as PresenceRoster | undefined) ?? {}).map(([key, metas]) => [key, [...metas]]));
    for (const [key, metas] of Object.entries(leaves)) {
      const gone = new Set(metas.map((meta) => meta.ref));
      const kept = (next.get(key) ?? []).filter((meta) => !gone.has(meta.ref));
      if (kept.length > 0) next.set(key, kept); else next.delete(key);
    }
    for (const [key, metas] of Object.entries(joins)) {
      const present = next.get(key) ?? [];
      const known = new Set(present.map((meta) => meta.ref));
      const added = metas.filter((meta) => !known.has(meta.ref));
      if (added.length > 0) next.set(key, [...present, ...added]);
    }
    this.setState({ status: "ready", data: immutable(Object.fromEntries(next)), generation: undefined, seq: this.state.seq + 1, error: undefined });
  }

  setState(state: SubscriptionState<unknown>): void {
    const previous = this.state;
    this.state = Object.freeze(state);
    if (state.data === undefined) this.clearOverlays();
    if (this.presence && this.overlays.length > 0 && (state.seq !== previous.seq || state.data !== previous.data)) {
      for (const overlay of [...this.overlays]) if (overlay.settled) this.removeOverlay(overlay, false);
    }
    if (["recovering", "error", "closed"].includes(state.status)) {
      const error = state.error ?? new ApiError({ code: state.status === "closed" ? "SUBSCRIPTION_CLOSED" : "NETWORK_ERROR", message: "The view was not confirmed" });
      for (const confirmation of [...this.confirmations.values()]) confirmation.finish(error);
    }
    this.emit();
  }

  confirm(identifier: string, overlays: readonly Overlay[], signal?: AbortSignal): Promise<void> {
    if (signal?.aborted) return Promise.reject(signal.reason);
    if (this.state.status !== "ready") return Promise.reject(new ApiError({ code: "NOT_READY", message: "The subscription is not ready" }));
    if (!this.confirmationSupported || this.presence) return Promise.reject(new ApiError({ code: "UNSUPPORTED_CAPABILITY", message: "The subscription cannot confirm views" }));
    if (this.confirmations.size >= 32 || this.confirmations.has(identifier)) {
      return Promise.reject(new ApiError({ code: "LIMIT_EXCEEDED", message: "Too many pending confirmations or a duplicate confirmation ID" }));
    }
    return new Promise((resolve, reject) => {
      const abort = () => this.rejectConfirmation(identifier, signal?.reason);
      const timer = setTimeout(() => this.rejectConfirmation(identifier, new ApiError({ code: "TIMEOUT", message: "The view was not confirmed in time", retryable: true })), this.options.timeoutMs ?? 10_000);
      this.confirmations.set(identifier, {
        overlays,
        finish: (error) => {
          if (!this.confirmations.delete(identifier)) return;
          clearTimeout(timer);
          signal?.removeEventListener("abort", abort);
          if (error === undefined) resolve(); else reject(error);
        },
      });
      signal?.addEventListener("abort", abort, { once: true });
    });
  }

  hasConfirmation(identifier: string): boolean { return this.confirmations.has(identifier); }

  rejectConfirmation(identifier: string, error: unknown): void { this.confirmations.get(identifier)?.finish(error); }

  private applyConfirmed(snapshot: Snapshot, state: SubscriptionState<unknown>): void {
    const identifiers = snapshot.confirmed ?? [];
    if (!Array.isArray(identifiers) || identifiers.length > 32 ||
        identifiers.some((identifier) => typeof identifier !== "string" || identifier.length < 1 || identifier.length > 128) ||
        new Set(identifiers).size !== identifiers.length) {
      throw new ApiError({ code: "PROTOCOL_ERROR", message: "Invalid view confirmations" });
    }
    const pending = identifiers.map((identifier: string) => this.confirmations.get(identifier)).filter((value): value is Confirmation => value !== undefined);
    for (const confirmation of pending) for (const overlay of confirmation.overlays) this.removeOverlay(overlay, false);
    this.setState(state);
    for (const confirmation of pending) confirmation.finish();
  }

  view(): SubscriptionState<unknown> {
    if (this.overlays.length === 0 || this.state.data === undefined) return this.state;
    if (this.shown && this.shown.base === this.state && this.shown.version === this.overlayVersion) return this.shown.value;
    let data: unknown = this.state.data;
    for (const overlay of [...this.overlays]) {
      try { data = immutable(overlay.update(data)); }
      catch (error) {
        this.removeOverlay(overlay, false);
        this.report(error);
      }
    }
    const value = this.overlays.length === 0 ? this.state
      : Object.freeze({ ...this.state, data, pending: this.overlays.length });
    this.shown = { base: this.state, version: this.overlayVersion, value };
    return value;
  }

  predict(update: (data: unknown) => unknown): Overlay | undefined {
    if (this.state.data === undefined) return;
    const overlay: Overlay = { update, settled: false, timer: undefined };
    this.overlays.push(overlay);
    this.overlayVersion++;
    this.emit();
    return overlay;
  }

  settle(overlay: Overlay): void {
    if (!this.overlays.includes(overlay)) return;
    overlay.settled = true;
    overlay.timer = setTimeout(() => this.removeOverlay(overlay, true), this.options.optimisticTtlMs ?? 5_000);
    (overlay.timer as { unref?: () => void }).unref?.();
  }

  removeOverlay(overlay: Overlay, notify: boolean): void {
    const index = this.overlays.indexOf(overlay);
    if (index < 0) return;
    this.overlays.splice(index, 1);
    this.overlayVersion++;
    if (overlay.timer) clearTimeout(overlay.timer);
    if (notify && this.state.status !== "closed") this.emit();
  }

  clearOverlays(): void {
    for (const overlay of this.overlays) if (overlay.timer) clearTimeout(overlay.timer);
    this.overlays = [];
    this.overlayVersion++;
    this.shown = undefined;
  }

  notify(listener: (state: SubscriptionState<unknown>) => void): void {
    try { listener(this.view()); }
    catch (error) { this.report(error); }
  }

  private report(error: unknown): void {
    try { this.options.onListenerError?.(error); } catch {}
  }

  private emit(): void {
    for (const listener of this.listeners) this.notify(listener);
  }
}
