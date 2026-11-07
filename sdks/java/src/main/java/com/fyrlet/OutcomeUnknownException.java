package com.fyrlet;

import com.google.gson.JsonObject;

/**
 * A write was dispatched, but its result could not be established.
 *
 * <p>The underlying failure is available as the cause and through the inherited {@link #code()},
 * {@link #status()} and {@link #requestId()}. Uncertainty alone does not authorize replay: call
 * {@link Mutation#recover()} or {@link FyrletClient#recover(String, Object, String)} with
 * {@link #idempotencyKey()} before deciding to submit the write again.</p>
 */
public final class OutcomeUnknownException extends ApiException {

    private static final long serialVersionUID = 1L;

    private final String operation;
    private final String idempotencyKey;

    /**
     * Creates an unknown-outcome exception from the underlying failure.
     *
     * @param operation the operation name
     * @param idempotencyKey the key that identifies the dispatched write
     * @param cause the failure that prevented observing the result
     */
    public OutcomeUnknownException(String operation, String idempotencyKey, Throwable cause) {
        super(codeOf(cause), "The operation outcome is unknown", false, statusOf(cause), requestIdOf(cause),
                detailsOf(cause), cause);
        this.operation = operation;
        this.idempotencyKey = idempotencyKey;
    }

    /** Returns the operation whose result is unknown. */
    public String operation() {
        return operation;
    }

    /** Returns the idempotency key that identifies the dispatched write. */
    public String idempotencyKey() {
        return idempotencyKey;
    }

    private static String codeOf(Throwable cause) {
        return cause instanceof ApiException api ? api.code() : "NETWORK_ERROR";
    }

    private static int statusOf(Throwable cause) {
        return cause instanceof ApiException api ? api.status() : 0;
    }

    private static String requestIdOf(Throwable cause) {
        return cause instanceof ApiException api ? api.requestId() : null;
    }

    private static JsonObject detailsOf(Throwable cause) {
        return cause instanceof ApiException api ? api.details().deepCopy() : new JsonObject();
    }
}
