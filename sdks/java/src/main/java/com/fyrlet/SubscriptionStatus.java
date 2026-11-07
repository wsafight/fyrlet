package com.fyrlet;

/** The lifecycle of a subscription. */
public enum SubscriptionStatus {

    /** The initial connection. */
    CONNECTING("connecting"),
    /** The subscription holds a current snapshot. */
    READY("ready"),
    /** The previous data is retained while the connection is rebuilt. */
    RECOVERING("recovering"),
    /** Terminal: data is cleared and {@link SubscriptionState#error()} explains why. */
    ERROR("error"),
    /** Terminal: the subscription or client was closed. */
    CLOSED("closed");

    private final String wire;

    SubscriptionStatus(String wire) {
        this.wire = wire;
    }

    /** Returns the protocol value, such as {@code ready}. */
    public String wire() {
        return wire;
    }
}
