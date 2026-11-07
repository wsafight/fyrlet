package com.fyrlet;

import com.google.gson.JsonElement;

/**
 * A stored receipt returned by recovery: committed or accepted with the original result, or unknown when
 * no receipt is visible.
 *
 * @param status {@link MutationStatus#COMMITTED}, {@link MutationStatus#ACCEPTED} or
 *               {@link MutationStatus#UNKNOWN}
 * @param data the original result for a committed or accepted receipt
 */
public record RecoveryResult(MutationStatus status, JsonElement data) {
}
