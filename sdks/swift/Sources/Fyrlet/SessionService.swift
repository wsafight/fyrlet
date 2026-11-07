import Foundation

/// A short-lived user session issued by a trusted backend.
public struct UserSession {
    public let token: String
    public let projectId: String
    public let subjectId: String
    public let sessionId: String
    public let expiresAt: String
}

/// Session exchange for trusted backends. Never ship the service key in an app binary.
public final class SessionService {
    private let endpoint: String
    private let headers: [String: String]
    private let session: URLSession
    private let timeout: TimeInterval

    public init(endpoint: String, serviceKey: String, timeout: TimeInterval = 10, session: URLSession? = nil) throws {
        guard serviceKey.hasPrefix("rtk_") else { throw APIError(code: "INVALID_KEY", message: "Expected a backend service key") }
        self.endpoint = try endpointURL(endpoint)
        self.headers = ["authorization": "Bearer \(serviceKey)"]
        self.timeout = timeout
        self.session = session ?? defaultSession()
    }

    public func issueSession(externalSubject: String, issuer: String? = nil, ttlSeconds: Int? = nil) async throws -> UserSession {
        var body: [String: Any] = ["external_subject": externalSubject]
        if let issuer = issuer { body["issuer"] = issuer }
        if let ttl = ttlSeconds { body["ttl_seconds"] = ttl }
        let envelope = try await requestJSON(session, method: "POST", url: endpoint + "/api/v1/sessions",
                                             headers: headers, body: body, timeout: timeout)
        guard let data = envelope.data as? [String: Any], let token = data["token"] as? String,
              let project = data["project_id"] as? String, let subject = data["subject_id"] as? String,
              let id = data["session_id"] as? String, let expires = data["expires_at"] as? String else {
            throw APIError(code: "PROTOCOL_ERROR", message: "Invalid session response")
        }
        return UserSession(token: token, projectId: project, subjectId: subject, sessionId: id, expiresAt: expires)
    }

    @discardableResult
    public func revokeSession(_ sessionId: String) async throws -> Bool {
        let escaped = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? sessionId
        let envelope = try await requestJSON(session, method: "DELETE", url: endpoint + "/api/v1/sessions/" + escaped,
                                             headers: headers, timeout: timeout)
        return (envelope.data as? [String: Any])?["revoked"] as? Bool ?? false
    }
}
