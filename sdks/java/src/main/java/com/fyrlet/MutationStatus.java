package com.fyrlet;

/** The outcome of one operation. */
public enum MutationStatus {

    /** A successful read. */
    COMPLETED("completed"),
    /** A write committed to the database. */
    COMMITTED("committed"),
    /** A Run or ingest request was durably accepted for later execution. */
    ACCEPTED("accepted"),
    /** A definite failure: nothing was written. */
    FAILED("failed"),
    /** The write was dispatched, but its result was not seen. Use {@link Mutation#recover()}. */
    UNKNOWN("unknown");

    private final String wire;

    MutationStatus(String wire) {
        this.wire = wire;
    }

    /** Returns the protocol value, such as {@code committed}. */
    public String wire() {
        return wire;
    }

    /** Returns the status for a protocol value, or {@code null} when the value is unknown. */
    public static MutationStatus fromWire(String value) {
        if (value == null) {
            return null;
        }
        for (MutationStatus status : values()) {
            if (status.wire.equals(value)) {
                return status;
            }
        }
        return null;
    }

    /** Returns whether this status carries a successful business result. */
    public boolean isSuccess() {
        return this == COMPLETED || this == COMMITTED || this == ACCEPTED;
    }
}
