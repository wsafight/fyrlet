package com.fyrlet;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ScheduledFuture;
import java.util.function.Consumer;

/**
 * Server-side state of one logical subscription. Fields are guarded by the owning client's lock, except
 * where a method documents otherwise.
 */
final class SubscriptionEntry {

    final String id;
    final String name;
    final Object params;
    final boolean wantDelta;
    final Map<Integer, Consumer<SubscriptionState>> listeners = new LinkedHashMap<>();

    SubscriptionState state = SubscriptionState.connecting();
    int nextListener;
    PhoenixConnection connection;
    int joinFailures;
    ScheduledFuture<?> rejoin;
    private boolean delta;

    SubscriptionEntry(String id, String name, Object params, boolean wantDelta) {
        this.id = id;
        this.name = name;
        this.params = params;
        this.wantDelta = wantDelta;
    }

    String topic() {
        return "subscription:" + id;
    }

    /** The next fact the client must act on after applying a snapshot or delta. */
    sealed interface Applied permits Nothing, Ack, Reconnect {
    }

    record Nothing() implements Applied {
        static final Nothing INSTANCE = new Nothing();
    }

    record Ack(String generation, long seq) implements Applied {
    }

    record Reconnect() implements Applied {
        static final Reconnect INSTANCE = new Reconnect();
    }

    /**
     * Applies a full snapshot. Callers hold the client lock.
     *
     * @throws ApiException when the snapshot is structurally invalid or belongs to another identity
     */
    Applied applySnapshot(JsonObject payload, Identity identity, boolean initial) throws ApiException {
        Long version = payload == null ? null : Json.integer(payload, "protocol_version");
        String subscriptionId = payload == null ? null : Json.text(payload, "subscription_id");
        String generation = payload == null ? null : Json.text(payload, "generation");
        Long seq = payload == null ? null : Json.integer(payload, "seq");
        boolean hasData = payload != null && payload.has("data");
        if (payload == null || version == null || version != 1L || !id.equals(subscriptionId)
                || identity == null || !identity.projectId().equals(Json.text(payload, "project_id"))
                || !identity.subjectId().equals(Json.text(payload, "subject_id"))
                || generation == null || seq == null || seq < 1 || !hasData) {
            throw new ApiException("PROTOCOL_ERROR", "Invalid subscription snapshot");
        }
        if (!initial && !generation.equals(state.generation())) {
            return Nothing.INSTANCE;
        }
        if (initial) {
            delta = "delta-v1".equals(Json.text(payload, "delivery"));
        }
        if (initial || seq > state.seq()) {
            state = new SubscriptionState(SubscriptionStatus.READY, payload.get("data"), null, generation, seq);
        }
        return new Ack(generation, seq);
    }

    /**
     * Applies a compact delta. Callers hold the client lock.
     *
     * @throws ApiException when the delta sequence or patch is invalid
     */
    Applied applyDelta(JsonObject payload) throws ApiException {
        if (payload == null) {
            throw new ApiException("PROTOCOL_ERROR", "Invalid subscription delta");
        }
        String generation = Json.text(payload, "g");
        if (generation == null || !generation.equals(state.generation())) {
            return Nothing.INSTANCE;
        }
        Long seq = Json.integer(payload, "s");
        Long base = Json.integer(payload, "b");
        if (!delta || seq == null || base == null || seq < 2 || base < 1 || seq != base + 1) {
            throw new ApiException("PROTOCOL_ERROR", "Invalid subscription delta sequence");
        }
        String current = state.generation();
        if (seq <= state.seq()) {
            return new Ack(current, seq);
        }
        if (base != state.seq()) {
            return Reconnect.INSTANCE;
        }
        JsonElement data = Delta.apply(state.data(), payload.get("p"));
        if (data == null) {
            throw new ApiException("PROTOCOL_ERROR", "Invalid subscription delta");
        }
        state = new SubscriptionState(SubscriptionStatus.READY, data, null, current, seq);
        return new Ack(current, seq);
    }
}
