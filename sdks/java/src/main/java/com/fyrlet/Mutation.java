package com.fyrlet;

import com.google.gson.JsonElement;

/**
 * Keeps the outcome of one operation so an unknown result can be recovered later.
 *
 * <p>{@link #state()} is always safe to read. {@link #recover()} performs an HTTP request and may block;
 * concurrent calls share this handle's lock and serialize.</p>
 */
public final class Mutation {

    /** Looks up the stored receipt without executing the operation. */
    @FunctionalInterface
    interface Lookup {
        RecoveryResult lookup() throws ApiException;
    }

    private final String idempotencyKey;
    private final Lookup lookup;
    private MutationState state;

    Mutation(String idempotencyKey, MutationState state, Lookup lookup) {
        this.idempotencyKey = idempotencyKey;
        this.state = state;
        this.lookup = lookup;
    }

    /** Returns the key that identifies the write; reuse it to retry or recover. */
    public String idempotencyKey() {
        return idempotencyKey;
    }

    /** Returns the current outcome. */
    public synchronized MutationState state() {
        return state;
    }

    /**
     * Returns the business result, or throws the original failure.
     *
     * @return the result of a completed, committed or accepted operation
     * @throws ApiException the failure of a failed or unknown operation
     */
    public JsonElement result() throws ApiException {
        MutationState current = state();
        if (current.status() != null && current.status().isSuccess()) {
            return current.data();
        }
        if (current.error() != null) {
            throw current.error();
        }
        throw new ApiException("PROTOCOL_ERROR", "The operation has no result");
    }

    /**
     * Queries the stored receipt of an unknown write without executing it again. A terminal handle returns
     * its existing state without a request; a failed recovery keeps the unknown state and throws.
     *
     * @return the state after recovery
     * @throws ApiException when the recovery request fails
     */
    public synchronized MutationState recover() throws ApiException {
        if (state.status() != MutationStatus.UNKNOWN) {
            return state;
        }
        RecoveryResult found = lookup.lookup();
        if (found.status() != MutationStatus.UNKNOWN) {
            state = new MutationState(found.status(), found.data(), null);
        }
        return state;
    }
}
