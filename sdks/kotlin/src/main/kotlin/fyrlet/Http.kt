package fyrlet

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParseException
import com.google.gson.JsonParser
import java.io.IOException
import java.net.URI
import java.net.URISyntaxException
import java.net.URLEncoder
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.net.http.HttpTimeoutException
import java.nio.charset.StandardCharsets
import java.time.Duration

/** One decoded HTTP response envelope. [data] is present for every successful response. */
internal data class Envelope(
    val requestId: String?,
    val data: JsonElement,
    val outcome: String?,
)

/** HTTP helpers shared by [FyrletClient] and [SessionService]. */
internal object FyrletHttp {
    /** The response cap; larger bodies are truncated and will fail to parse. */
    const val MAX_RESPONSE_BYTES = 16 * 1024 * 1024

    /**
     * Validates and normalizes an HTTP(S) base URL. Credentials, a query and a fragment are rejected so a
     * bearer token can never be redirected somewhere unexpected.
     */
    fun endpointUrl(endpoint: String): String {
        val uri = try {
            URI(endpoint)
        } catch (_: URISyntaxException) {
            throw IllegalArgumentException(ENDPOINT_MESSAGE)
        }
        if (uri.scheme != "http" && uri.scheme != "https") throw IllegalArgumentException(ENDPOINT_MESSAGE)
        if (uri.host.isNullOrEmpty()) throw IllegalArgumentException(ENDPOINT_MESSAGE)
        if (uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) {
            throw IllegalArgumentException(ENDPOINT_MESSAGE)
        }
        return endpoint.trimEnd('/')
    }

    /** Percent-encodes a path segment, leaving only RFC 3986 unreserved characters. */
    fun pathEscape(value: String): String {
        val bytes = value.toByteArray(StandardCharsets.UTF_8)
        val builder = StringBuilder(bytes.size)
        for (byte in bytes) {
            val code = byte.toInt() and 0xff
            val character = code.toChar()
            if (character in 'A'..'Z' || character in 'a'..'z' || character in '0'..'9' ||
                character == '-' || character == '.' || character == '_' || character == '~'
            ) {
                builder.append(character)
            } else {
                builder.append('%')
                builder.append(HEX[code shr 4])
                builder.append(HEX[code and 0x0f])
            }
        }
        return builder.toString()
    }

    /** Encodes a query-string value the same way Go's `url.Values.Encode` does for simple identifiers. */
    fun queryEscape(value: String): String = URLEncoder.encode(value, StandardCharsets.UTF_8)

    /**
     * Performs one request and decodes the response envelope.
     *
     * Network failures become retryable `NETWORK_ERROR`, request timeouts become retryable `TIMEOUT`, and an
     * unparsable or structurally invalid response becomes `PROTOCOL_ERROR`.
     */
    fun send(
        client: HttpClient,
        method: String,
        target: String,
        headers: Map<String, String>,
        body: JsonElement?,
        timeout: Duration,
    ): Envelope {
        val builder = HttpRequest.newBuilder(URI(target)).timeout(timeout)
        builder.header("accept", "application/json")
        for ((name, value) in headers) builder.header(name, value)
        if (body != null) {
            builder.header("content-type", "application/json")
            builder.method(method, HttpRequest.BodyPublishers.ofString(FyrletJson.gson.toJson(body), StandardCharsets.UTF_8))
        } else {
            when (method) {
                "GET" -> builder.GET()
                "DELETE" -> builder.DELETE()
                else -> builder.method(method, HttpRequest.BodyPublishers.noBody())
            }
        }

        val response = try {
            client.send(builder.build(), HttpResponse.BodyHandlers.ofInputStream())
        } catch (_: HttpTimeoutException) {
            throw apiError("TIMEOUT", "The request timed out", retryable = true)
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw apiError("NETWORK_ERROR", "The service could not be reached", retryable = true)
        } catch (_: IOException) {
            throw apiError("NETWORK_ERROR", "The service could not be reached", retryable = true)
        }

        val status = response.statusCode()
        val raw = try {
            response.body().use { input -> input.readNBytes(MAX_RESPONSE_BYTES) }
        } catch (_: IOException) {
            throw apiError("NETWORK_ERROR", "The response was interrupted", retryable = true)
        }

        val text = String(raw, StandardCharsets.UTF_8)
        val root = try {
            JsonParser.parseString(text)
        } catch (_: JsonParseException) {
            throw ApiException("PROTOCOL_ERROR", "Expected a JSON response", status = status)
        }
        if (!root.isJsonObject) {
            throw ApiException("PROTOCOL_ERROR", "Expected a JSON response", status = status)
        }
        val object0 = root.asJsonObject
        // Field types are validated like the reference decoder: a wrong type invalidates the envelope.
        if (object0.has("request_id") && !isNullableString(object0.get("request_id"))) {
            throw ApiException("PROTOCOL_ERROR", "Expected a JSON response", status = status)
        }
        if (object0.has("outcome") && !isNullableString(object0.get("outcome"))) {
            throw ApiException("PROTOCOL_ERROR", "Expected a JSON response", status = status)
        }
        val errorElement = object0.get("error")
        if (errorElement != null && !errorElement.isJsonNull && !errorElement.isJsonObject) {
            throw ApiException("PROTOCOL_ERROR", "Expected a JSON response", status = status)
        }
        val requestId = object0.stringOrNull("request_id")
        val outcome = object0.stringOrNull("outcome")
        val hasError = errorElement != null && errorElement.isJsonObject

        if (status !in 200..299 || hasError) {
            if (hasError) throw wireError(errorElement.asJsonObject, status, requestId)
            throw ApiException("HTTP_ERROR", "The request was rejected", status = status, requestId = requestId)
        }
        val data = object0.get("data")
            ?: throw ApiException("PROTOCOL_ERROR", "Missing response data", status = status)
        return Envelope(requestId, data, outcome)
    }

    private fun isNullableString(element: JsonElement): Boolean =
        element.isJsonNull || (element.isJsonPrimitive && element.asJsonPrimitive.isString)

    private const val HEX = "0123456789ABCDEF"
    private const val ENDPOINT_MESSAGE =
        "fyrlet: endpoint must be an HTTP(S) base URL without credentials, query or fragment"
}
