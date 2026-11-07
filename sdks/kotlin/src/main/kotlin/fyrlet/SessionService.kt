package fyrlet

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import java.net.http.HttpClient
import java.time.Duration

/**
 * A short-lived user session issued by a trusted backend.
 *
 * The property names match the server payload exactly.
 */
data class UserSession(
    val token: String,
    val project_id: String,
    val subject_id: String,
    val session_id: String,
    val expires_at: String,
)

/**
 * Exchanges application logins for Fyrlet user sessions.
 *
 * Use it only on trusted backends: the service key must never reach a browser or app binary. The service is
 * safe for concurrent use.
 *
 * @param serviceKey a backend service key beginning with `rtk_`.
 * @param timeout bounds each HTTP request. Default 10 seconds.
 * @param httpClient overrides the HTTP client. Redirects are never followed by the default client.
 */
class SessionService @JvmOverloads constructor(
    endpoint: String,
    serviceKey: String,
    timeout: Duration = Duration.ofSeconds(10),
    httpClient: HttpClient? = null,
) {
    private val timeout: Duration =
        if (timeout.isZero || timeout.isNegative) Duration.ofSeconds(10) else timeout
    private val endpoint: String
    private val headers: Map<String, String>
    private val httpClient: HttpClient

    init {
        require(serviceKey.startsWith("rtk_")) { "fyrlet: expected a backend service key" }
        this.endpoint = FyrletHttp.endpointUrl(endpoint)
        this.headers = mapOf("authorization" to "Bearer $serviceKey")
        this.httpClient = httpClient ?: HttpClient.newBuilder()
            .followRedirects(HttpClient.Redirect.NEVER)
            .connectTimeout(timeout)
            .build()
    }

    /**
     * Creates a session for an externally authenticated subject. [user] must come from your application's
     * verified login state. Return only the resulting [UserSession.token] to that user.
     */
    @JvmOverloads
    fun issueSession(
        externalSubject: String,
        issuer: String? = null,
        ttlSeconds: Int? = null,
    ): UserSession {
        val body = JsonObject()
        body.addProperty("external_subject", externalSubject)
        if (issuer != null) body.addProperty("issuer", issuer)
        if (ttlSeconds != null) body.addProperty("ttl_seconds", ttlSeconds)
        val envelope = FyrletHttp.send(
            httpClient, "POST", endpoint + "/api/v1/sessions", headers, body, timeout,
        )
        val data = envelope.data
        if (!data.isJsonObject) throw apiError("PROTOCOL_ERROR", "Invalid session response")
        val object0 = data.asJsonObject
        val session = UserSession(
            token = field(object0, "token"),
            project_id = field(object0, "project_id"),
            subject_id = field(object0, "subject_id"),
            session_id = field(object0, "session_id"),
            expires_at = field(object0, "expires_at"),
        )
        if (session.token.isEmpty()) throw apiError("PROTOCOL_ERROR", "Invalid session response")
        return session
    }

    /** Revokes one session of this project. */
    fun revokeSession(sessionId: String): Boolean {
        val envelope = FyrletHttp.send(
            httpClient, "DELETE",
            endpoint + "/api/v1/sessions/" + FyrletHttp.pathEscape(sessionId),
            headers, null, timeout,
        )
        val data = envelope.data
        if (!data.isJsonObject) throw apiError("PROTOCOL_ERROR", "Invalid revoke response")
        val revoked: JsonElement? = data.asJsonObject.get("revoked")
        if (revoked == null || revoked.isJsonNull) return false
        if (!revoked.isJsonPrimitive || !revoked.asJsonPrimitive.isBoolean) {
            throw apiError("PROTOCOL_ERROR", "Invalid revoke response")
        }
        return revoked.asBoolean
    }

    private fun field(data: JsonObject, name: String): String {
        val value = data.get(name)
        if (value == null || value.isJsonNull) return ""
        val text = value.stringOrNull() ?: throw apiError("PROTOCOL_ERROR", "Invalid session response")
        return text
    }
}
