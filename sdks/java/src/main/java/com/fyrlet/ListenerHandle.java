package com.fyrlet;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Removes a subscription listener. Closing it more than once is harmless.
 *
 * <p>The handle may be used from any thread, including from inside the listener itself.</p>
 */
public final class ListenerHandle implements AutoCloseable {

    private final Runnable remove;
    private final AtomicBoolean removed = new AtomicBoolean();

    ListenerHandle(Runnable remove) {
        this.remove = remove;
    }

    /** Removes the listener. */
    @Override
    public void close() {
        if (removed.compareAndSet(false, true)) {
            remove.run();
        }
    }
}
