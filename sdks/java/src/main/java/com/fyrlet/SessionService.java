package com.fyrlet;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import java.net.http.HttpClient;
import java.time.Duration;
import java.util.Map;

/**
 * Exchanges application logins for Fyrlet user sessions and revokes them.
 *
 * <p>Use this only on a trusted backend. The project service key must never reach a browser or an app
 * binary.</p>
 */
public final class SessionService {

    private final String endpoint;
    private final Map<String, String> headers;
    private final HttpClient http;
    private final Duration timeout;

    /**
     * Creates a service using a 10 second timeout.
     *
     * @param endpoint the HTTP(S) base URL of the Fyrlet server
     * @param serviceKey a backend service key beginning with {@code rtk_}
     */
    public SessionService(String endpoint, String serviceKey) {
        this(endpoint, serviceKey, Duration.ofSeconds(10), null);
    }

    /**
     * Creates a service.
     *
     * @param endpoint the HTTP(S) base URL of the Fyrlet server
     * @param serviceKey a backend service key beginning with {@code rtk_}
     * @param timeout an optional request timeout; {@code null} means 10 seconds
     * @param http an optional HTTP client that must not follow redirects
     */
    public SessionService(String endpoint, String serviceKey, Duration timeout, HttpClient http) {
        if (serviceKey == null || !serviceKey.startsWith("rtk_")) {
            throw new IllegalArgumentException("Expected a backend service key");
        }
        this.endpoint = Wire.endpointUrl(endpoint);
        this.headers = Map.of("authorization", "Bearer " + serviceKey);
        this.timeout = timeout == null || timeout.isZero() || timeout.isNegative()
                ? Duration.ofSeconds(10) : timeout;
        if (http != null) {
            FyrletHttp.requireNoRedirects(http);
            this.http = http;
        } else {
            this.http = FyrletHttp.newHttpClient(this.timeout);
        }
    }

    /**
     * Creates a session for an externally authenticated subject.
     *
     * @param externalSubject the verified login identifier from the host application
     * @return the issued session
     * @throws ApiException on transport, protocol or server failure
     */
    public UserSession issueSession(String externalSubject) throws ApiException {
        return issueSession(externalSubject, null, null);
    }

    /**
     * Creates a session for an externally authenticated subject.
     *
     * @param externalSubject the verified login identifier from the host application
     * @param issuer an optional issuer label
     * @param ttlSeconds an optional requested lifetime
     * @return the issued session
     * @throws ApiException on transport, protocol or server failure
     */
    public UserSession issueSession(String externalSubject, String issuer, Integer ttlSeconds) throws ApiException {
        JsonObject body = new JsonObject();
        body.addProperty("external_subject", externalSubject);
        if (issuer != null) {
            body.addProperty("issuer", issuer);
        }
        if (ttlSeconds != null) {
            body.addProperty("ttl_seconds", ttlSeconds);
        }
        FyrletHttp.Envelope envelope = FyrletHttp.send(
                http, "POST", endpoint + "/api/v1/sessions", headers, body, timeout);
        JsonElement data = envelope.data();
        if (data == null || !data.isJsonObject()) {
            throw new ApiException("PROTOCOL_ERROR", "Invalid session response");
        }
        JsonObject session = data.getAsJsonObject();
        String token = Json.text(session, "token");
        String projectId = Json.text(session, "project_id");
        String subjectId = Json.text(session, "subject_id");
        String sessionId = Json.text(session, "session_id");
        String expiresAt = Json.text(session, "expires_at");
        if (token == null || token.isEmpty() || projectId == null || subjectId == null
                || sessionId == null || expiresAt == null) {
            throw new ApiException("PROTOCOL_ERROR", "Invalid session response");
        }
        return new UserSession(token, projectId, subjectId, sessionId, expiresAt);
    }

    /**
     * Revokes one session of this project.
     *
     * @param sessionId the session to revoke
     * @return whether the server reported the session revoked
     * @throws ApiException on transport, protocol or server failure
     */
    public boolean revokeSession(String sessionId) throws ApiException {
        FyrletHttp.Envelope envelope = FyrletHttp.send(
                http, "DELETE", endpoint + "/api/v1/sessions/" + Wire.pathSegment(sessionId),
                headers, null, timeout);
        JsonElement data = envelope.data();
        if (data == null || !data.isJsonObject()) {
            throw new ApiException("PROTOCOL_ERROR", "Invalid revoke response");
        }
        JsonElement revoked = data.getAsJsonObject().get("revoked");
        return revoked != null && revoked.isJsonPrimitive() && revoked.getAsJsonPrimitive().isBoolean()
                && revoked.getAsBoolean();
    }
}
