import Foundation

/// A failure reported by the server or detected by the SDK.
public struct APIError: Error, CustomStringConvertible {
    public let code: String
    public let message: String
    public let details: [String: Any]
    public let retryable: Bool
    public let status: Int
    public let requestId: String?

    public init(code: String, message: String, details: [String: Any] = [:], retryable: Bool = false,
                status: Int = 0, requestId: String? = nil) {
        self.code = code; self.message = message; self.details = details
        self.retryable = retryable; self.status = status; self.requestId = requestId
    }

    public var description: String { "Fyrlet \(code): \(message)" }

    init(wire: Any?, status: Int, requestId: String?) {
        if let error = wire as? [String: Any], let code = error["code"] as? String, let message = error["message"] as? String {
            self.init(code: code, message: message, details: error["details"] as? [String: Any] ?? [:],
                      retryable: error["retryable"] as? Bool ?? false, status: status, requestId: requestId)
        } else {
            self.init(code: "PROTOCOL_ERROR", message: "Invalid error response", status: status, requestId: requestId)
        }
    }

    /// Converts a Phoenix error reply (`{"error": {...}, "status": 409}`).
    static func channel(_ response: [String: Any]?) -> APIError {
        guard let response = response, response["error"] is [String: Any] else {
            return APIError(code: "PROTOCOL_ERROR", message: "The server returned an invalid channel response")
        }
        return APIError(wire: response["error"], status: JSON.int(response["status"]) ?? 0, requestId: nil)
    }

    static func network(_ message: String = "The service could not be reached") -> APIError {
        APIError(code: "NETWORK_ERROR", message: message, retryable: true)
    }
}

/// A write was dispatched but its result is unknown. Use `Client.recover` with `idempotencyKey` before
/// deciding to submit it again.
public struct OutcomeUnknownError: Error, CustomStringConvertible {
    public let operation: String
    public let idempotencyKey: String
    public let cause: Error
    public var description: String { "The outcome of \(operation) is unknown: \(cause)" }
}

func asAPIError(_ error: Error) -> APIError {
    if let api = error as? APIError { return api }
    return APIError.network()
}

enum JSON {
    /// A JSON integer within the safe range; booleans are not integers.
    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double == double.rounded(), abs(double) <= 9_007_199_254_740_992 else { return nil }
        return Int(double)
    }

    static func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    static func parse(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Decodes JSON-compatible `value` into your own `Decodable` type.
    static func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        try JSONDecoder().decode(type, from: data(value))
    }
}

/// Decodes a call result or `State.data` into your own `Decodable` type.
public func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
    try JSON.decode(type, from: value)
}
