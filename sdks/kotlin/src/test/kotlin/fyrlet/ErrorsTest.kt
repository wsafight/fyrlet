package fyrlet

import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

class ErrorsTest {
    @Test
    fun `channel error parses code and status`() {
        val error = channelError(json("""{"error":{"code":"CONFLICT","message":"m"},"status":409}""").asJsonObject)
        assertEquals("CONFLICT", error.code)
        assertEquals(409, error.status)
        assertFalse(error.retryable)
    }

    @Test
    fun `channel error keeps retryable and details`() {
        val error = channelError(
            json("""{"error":{"code":"INTERNAL_ERROR","message":"m","retryable":true,"details":{"a":1}},"status":500}""")
                .asJsonObject,
        )
        assertEquals("INTERNAL_ERROR", error.code)
        assertTrue(error.retryable)
        assertEquals(1, error.details?.get("a")?.asInt)
    }

    @Test
    fun `invalid channel response is a protocol error`() {
        assertEquals("PROTOCOL_ERROR", channelError(json("{}").asJsonObject).code)
        assertEquals("PROTOCOL_ERROR", channelError(null).code)
        assertEquals("PROTOCOL_ERROR", channelError(json("""{"error":"x"}""").asJsonObject).code)
    }

    @Test
    fun `invalid wire error is a protocol error`() {
        val error = wireError(json("""{"details":{}}""").asJsonObject, 400, "r1")
        assertEquals("PROTOCOL_ERROR", error.code)
        assertEquals(400, error.status)
        assertEquals("r1", error.requestId)
    }

    @Test
    fun `outcome unknown exposes the original cause`() {
        val cause = ApiException("TIMEOUT", "t", retryable = true)
        val wrapped = OutcomeUnknownException("op", "k", cause)
        assertEquals("TIMEOUT", wrapped.code)
        assertFalse(wrapped.retryable)
        assertSame(cause, wrapped.cause)
        assertEquals("op", wrapped.operation)
        assertEquals("k", wrapped.idempotencyKey)
    }

    @Test
    fun `foreign errors become retryable network errors`() {
        val converted = asApiException(IllegalStateException("boom"))
        assertEquals("NETWORK_ERROR", converted.code)
        assertTrue(converted.retryable)
    }
}
