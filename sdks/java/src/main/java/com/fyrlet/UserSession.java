package com.fyrlet;

/**
 * A short-lived user session issued by a trusted backend.
 *
 * @param token the user session token beginning with {@code rts_}
 * @param projectId the project the session belongs to
 * @param subjectId the user the session identifies
 * @param sessionId the session identifier, used to revoke it
 * @param expiresAt the UTC expiry timestamp
 */
public record UserSession(String token, String projectId, String subjectId, String sessionId, String expiresAt) {
}
