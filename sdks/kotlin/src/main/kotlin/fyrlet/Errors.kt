package fyrlet

import com.google.gson.JsonObject

/**
 * A failure reported by the server or detected by the SDK.
 *
 * @property code stable machine-readable code, such as `UNAUTHENTICATED`, `CONFLICT` or `NETWORK_ERROR`.
 * @property retryable whether retrying the same request later may succeed.
 * @property status HTTP status for HTTP failures, or the `status` carried by a channel error; 0 when unknown.
 * @property requestId the server request identifier when one was returned.
 * @property details structured error details, when the server supplied them.
 */
open class ApiException @JvmOverloads constructor(
    val code: String,
    message: String,
    val retryable: Boolean = false,
    val status: Int = 0,
    val requestId: String? = null,
    val details: JsonObject? = null,
    cause: Throwable? = null,
) : RuntimeException("fyrlet: $code: $message", cause)

/**
 * A write was dispatched but its result is unknown. The write may have committed.
 *
 * Use [Mutation.recover] or [FyrletClient.recover] with [idempotencyKey] before deciding to submit the
 * operation again. [operation] names the operation that produced the uncertain outcome.
 */
class OutcomeUnknownException(
    val operation: String,
    val idempotencyKey: String,
    override val cause: ApiException,
) : ApiException(
    code = cause.code,
    message = "The operation outcome is unknown",
    retryable = false,
    status = cause.status,
    requestId = cause.requestId,
    details = cause.details,
    cause = cause,
)

internal fun apiError(code: String, message: String, retryable: Boolean = false): ApiException =
    ApiException(code, message, retryable)

/** Converts any throwable into an [ApiException], treating foreign errors as retryable network failures. */
internal fun asApiException(error: Throwable): ApiException =
    error as? ApiException ?: ApiException("NETWORK_ERROR", "The service could not be reached", retryable = true, cause = error)

/** Converts a decoded wire error object into an [ApiException], validating its required fields. */
internal fun wireError(error: JsonObject?, status: Int, requestId: String?): ApiException {
    val code = error?.stringOrNull("code")
    val message = error?.stringOrNull("message")
    if (error == null || code == null || message == null) {
        return ApiException("PROTOCOL_ERROR", "Invalid error response", status = status, requestId = requestId)
    }
    val details = error.get("details")
        ?.takeIf { it.isJsonObject }
        ?.asJsonObject
    val retryable = error.get("retryable")
        ?.takeIf { it.isJsonPrimitive && it.asJsonPrimitive.isBoolean }
        ?.asBoolean ?: false
    return ApiException(code, message, retryable, status, requestId, details)
}

/**
 * Converts a Phoenix error reply (`{"error": {...}, "status": 409}`) into an [ApiException].
 *
 * A missing or malformed `error` object is a non-retryable `PROTOCOL_ERROR`.
 */
internal fun channelError(response: JsonObject?): ApiException {
    val error = response?.get("error")?.takeIf { it.isJsonObject }?.asJsonObject
        ?: return ApiException("PROTOCOL_ERROR", "The server returned an invalid channel response")
    val status = response.longOrNull("status")?.toInt() ?: 0
    return wireError(error, status, null)
}
