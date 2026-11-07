package com.fyrlet;

import com.google.gson.JsonParser;
import org.junit.jupiter.api.Test;

import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;

class ErrorsTest {

    @Test
    void parsesChannelErrors() {
        ApiException error = ApiException.channel(
                JsonParser.parseString("{\"error\":{\"code\":\"CONFLICT\",\"message\":\"m\"},\"status\":409}"));

        assertEquals("CONFLICT", error.code());
        assertEquals(409, error.status());
        assertFalse(error.retryable());

        ApiException invalid = ApiException.channel(JsonParser.parseString("{\"nope\":1}"));
        assertEquals("PROTOCOL_ERROR", invalid.code());
    }

    @Test
    void unknownOutcomeKeepsCauseAndKey() {
        ApiException cause = new ApiException("TIMEOUT", "t", true);
        OutcomeUnknownException error = new OutcomeUnknownException("op", "key", cause);

        assertEquals("TIMEOUT", error.code());
        assertEquals("op", error.operation());
        assertEquals("key", error.idempotencyKey());
        assertFalse(error.retryable());
        assertSame(cause, error.getCause());
    }

    @Test
    void mutationRecoveryTransitionsOnlyFromUnknown() throws ApiException {
        AtomicInteger calls = new AtomicInteger();
        Mutation mutation = new Mutation("k",
                new MutationState(MutationStatus.UNKNOWN, null,
                        new OutcomeUnknownException("op", "k", new ApiException("TIMEOUT", "t", true))),
                () -> {
                    calls.incrementAndGet();
                    return new RecoveryResult(MutationStatus.COMMITTED, JsonParser.parseString("{\"id\":\"a\"}"));
                });

        MutationState recovered = mutation.recover();
        assertEquals(MutationStatus.COMMITTED, recovered.status());
        assertEquals(1, calls.get());
        assertEquals(MutationStatus.COMMITTED, mutation.recover().status());
        assertEquals(1, calls.get());
    }

    @Test
    void mutationResultThrowsFailure() {
        ApiException failure = new ApiException("CONFLICT", "conflict");
        Mutation mutation = new Mutation("k", new MutationState(MutationStatus.FAILED, null, failure), () -> {
            throw new AssertionError("must not recover a definite failure");
        });

        assertThrows(ApiException.class, mutation::result);
        assertNull(mutation.state().data());
    }

    @Test
    void integersAreJavaScriptSafe() {
        assertEquals(42L, Json.integer(JsonParser.parseString("42")));
        assertEquals(9007199254740992L, Json.integer(JsonParser.parseString("9007199254740992")));
        assertNull(Json.integer(JsonParser.parseString("9007199254740993")));
        assertNull(Json.integer(JsonParser.parseString("1.5")));
        assertNull(Json.integer(JsonParser.parseString("\"1\"")));
    }
}
