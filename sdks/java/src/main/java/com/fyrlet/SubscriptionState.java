package com.fyrlet;

import com.google.gson.JsonElement;

/**
 * What a subscription listener sees.
 *
 * <p>{@link #data()} is a JSON view and must be treated as read-only. A later delta creates new
 * containers and never modifies a value that was already delivered. Data is retained while
 * {@link SubscriptionStatus#RECOVERING} and cleared for {@link SubscriptionStatus#ERROR} and
 * {@link SubscriptionStatus#CLOSED}.</p>
 *
 * @param status the lifecycle status
 * @param data the current decoded JSON, or {@code null}
 * @param error the terminal or join failure, or {@code null}
 * @param generation the generation confirmed by the current join, or {@code null}
 * @param seq the last applied sequence number, or {@code 0}
 */
public record SubscriptionState(SubscriptionStatus status, JsonElement data, ApiException error,
                                String generation, long seq) {

    /** Returns an initial connecting state. */
    public static SubscriptionState connecting() {
        return new SubscriptionState(SubscriptionStatus.CONNECTING, null, null, null, 0);
    }

    /** Copies this state with a new status and clears the error, keeping data, generation and seq. */
    SubscriptionState recovering() {
        return new SubscriptionState(SubscriptionStatus.RECOVERING, data, null, generation, seq);
    }

    /** Copies this state as terminal error, clearing data. */
    SubscriptionState failed(ApiException failure) {
        return new SubscriptionState(SubscriptionStatus.ERROR, null, failure, generation, seq);
    }

    /** Copies this state as closed, clearing data and error. */
    SubscriptionState closed() {
        return new SubscriptionState(SubscriptionStatus.CLOSED, null, null, generation, seq);
    }

    /**
     * Deserializes {@link #data()} into the requested type.
     *
     * @param type the target type
     * @param <T> the target type
     * @return the decoded value, or {@code null} when there is no data
     */
    public <T> T decode(Class<T> type) {
        return data == null ? null : Json.GSON.fromJson(data, type);
    }
}
