package com.fyrlet;

import com.google.gson.JsonElement;

/**
 * A snapshot of a {@link Mutation}.
 *
 * @param status the outcome status
 * @param data the business result, or {@code null} when there is none
 * @param error the failure for {@link MutationStatus#FAILED} and {@link MutationStatus#UNKNOWN}
 */
public record MutationState(MutationStatus status, JsonElement data, ApiException error) {

    /**
     * Returns whether this state carries a successful business result.
     *
     * @return {@code true} for completed, committed and accepted
     */
    public boolean isSuccess() {
        return status != null && status.isSuccess();
    }
}
