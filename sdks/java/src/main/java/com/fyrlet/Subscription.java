package com.fyrlet;

import java.util.function.Consumer;

/**
 * A handle to one realtime subscription. All methods are safe to use from any thread.
 *
 * <p>Data is retained while the status is {@link SubscriptionStatus#RECOVERING} and cleared for
 * {@link SubscriptionStatus#ERROR} and {@link SubscriptionStatus#CLOSED}.</p>
 */
public final class Subscription {

    private final FyrletClient client;
    private final SubscriptionEntry entry;

    Subscription(FyrletClient client, SubscriptionEntry entry) {
        this.client = client;
        this.entry = entry;
    }

    /** Returns the current state. */
    public SubscriptionState state() {
        synchronized (client.gate()) {
            return entry.state;
        }
    }

    /**
     * Registers a listener. It receives the current state first, then every change, serially on the
     * client's listener thread, so it may call back into the client.
     *
     * @param listener the listener, which must not be {@code null}
     * @return a handle that removes the listener
     */
    public ListenerHandle onChange(Consumer<SubscriptionState> listener) {
        if (listener == null) {
            throw new IllegalArgumentException("listener is required");
        }
        return client.addListener(entry, listener);
    }

    /**
     * Asks the server for a fresh snapshot. Returns once the server accepted the request; the data
     * arrives through {@link #onChange}.
     *
     * @throws ApiException when the subscription is not ready or the request fails
     */
    public void refresh() throws ApiException {
        client.refresh(entry);
    }

    /** Ends this subscription. It is safe to call more than once. */
    public void unsubscribe() {
        client.unsubscribe(entry);
    }
}
