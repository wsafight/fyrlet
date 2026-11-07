package com.fyrlet;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

/**
 * A failure reported by the Fyrlet server or detected by the SDK.
 *
 * <p>{@link #code()} is one of the protocol codes ({@code UNAUTHENTICATED}, {@code FORBIDDEN},
 * {@code NOT_FOUND}, {@code VALIDATION_FAILED}, {@code CONFLICT}, {@code LIMIT_EXCEEDED},
 * {@code UNSUPPORTED_VERSION}, {@code UNSUPPORTED_CAPABILITY}, {@code EFFECT_UNKNOWN},
 * {@code EFFECT_CONFLICT}, {@code LEASE_LOST}, {@code INTERNAL_ERROR}) or an SDK code
 * ({@code NETWORK_ERROR}, {@code TIMEOUT}, {@code PROTOCOL_ERROR}, {@code HTTP_ERROR},
 * {@code SUBSCRIPTION_CLOSED}, {@code NOT_READY}, {@code CLIENT_CLOSED}).</p>
 *
 * <p>Instances are immutable and safe to share between threads.</p>
 */
public class ApiException extends Exception {

    private static final long serialVersionUID = 1L;

    private final String code;
    private final boolean retryable;
    private final int status;
    private final String requestId;
    private final JsonObject details;

    /**
     * Creates a non-retryable exception without HTTP metadata.
     *
     * @param code a protocol or SDK error code
     * @param message a human-readable explanation
     */
    public ApiException(String code, String message) {
        this(code, message, false, 0, null, new JsonObject(), null);
    }

    /**
     * Creates an exception without HTTP metadata.
     *
     * @param code a protocol or SDK error code
     * @param message a human-readable explanation
     * @param retryable whether retrying the same operation later may succeed
     */
    public ApiException(String code, String message, boolean retryable) {
        this(code, message, retryable, 0, null, new JsonObject(), null);
    }

    /**
     * Creates a fully described exception.
     *
     * @param code a protocol or SDK error code
     * @param message a human-readable explanation
     * @param retryable whether retrying the same operation later may succeed
     * @param status the HTTP status, or {@code 0} when unavailable
     * @param requestId the server request identifier, or {@code null}
     * @param details structured error details, or {@code null}
     * @param cause the underlying failure, or {@code null}
     */
    public ApiException(String code, String message, boolean retryable, int status, String requestId,
                        JsonObject details, Throwable cause) {
        super(message, cause);
        this.code = code;
        this.retryable = retryable;
        this.status = status;
        this.requestId = requestId;
        this.details = details == null ? new JsonObject() : details;
    }

    /** Returns the protocol or SDK error code. */
    public String code() {
        return code;
    }

    /** Returns whether retrying the same operation later may succeed. */
    public boolean retryable() {
        return retryable;
    }

    /** Returns the HTTP status, or {@code 0} when the failure did not come from an HTTP response. */
    public int status() {
        return status;
    }

    /** Returns the server request identifier, or {@code null} when unavailable. */
    public String requestId() {
        return requestId;
    }

    /** Returns immutable-by-convention structured details; never {@code null}. */
    public JsonObject details() {
        return details;
    }

    @Override
    public String toString() {
        return "fyrlet: " + code + ": " + getMessage();
    }

    // ---- construction helpers -----------------------------------------------------------------

    static ApiException network() {
        return network("The service could not be reached");
    }

    static ApiException network(String message) {
        return new ApiException("NETWORK_ERROR", message, true);
    }

    static ApiException closed() {
        return new ApiException("CLIENT_CLOSED", "The client is closed");
    }

    /** Converts any failure into an {@link ApiException}, treating foreign errors as network failures. */
    static ApiException from(Throwable error) {
        return error instanceof ApiException api ? api : network();
    }

    /** Converts a wire error object that must contain {@code code} and {@code message} strings. */
    static ApiException fromWire(JsonElement error, int status, String requestId) {
        if (error != null && error.isJsonObject()) {
            JsonObject value = error.getAsJsonObject();
            String code = Json.text(value, "code");
            String message = Json.text(value, "message");
            if (code != null && message != null) {
                JsonObject details = new JsonObject();
                JsonElement rawDetails = value.get("details");
                if (rawDetails != null && rawDetails.isJsonObject()) {
                    details = rawDetails.getAsJsonObject().deepCopy();
                }
                JsonElement rawRetryable = value.get("retryable");
                boolean retryable = rawRetryable != null && rawRetryable.isJsonPrimitive()
                        && rawRetryable.getAsJsonPrimitive().isBoolean() && rawRetryable.getAsBoolean();
                return new ApiException(code, message, retryable, status, requestId, details, null);
            }
        }
        return new ApiException("PROTOCOL_ERROR", "Invalid error response", false, status, requestId,
                new JsonObject(), null);
    }

    /**
     * Converts a Phoenix error reply such as {@code {"error":{"code":...},"status":409}}.
     *
     * @param response the reply payload, possibly {@code null}
     * @return the converted exception
     */
    static ApiException channel(JsonElement response) {
        if (response != null && response.isJsonObject()) {
            JsonObject reply = response.getAsJsonObject();
            JsonElement error = reply.get("error");
            if (error != null && error.isJsonObject()) {
                Long status = Json.integer(reply.get("status"));
                return fromWire(error, status == null ? 0 : status.intValue(), "");
            }
        }
        return new ApiException("PROTOCOL_ERROR", "The server returned an invalid channel response");
    }
}
