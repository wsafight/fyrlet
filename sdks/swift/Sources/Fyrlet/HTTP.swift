import Foundation

func endpointURL(_ endpoint: String) throws -> String {
    guard let url = URL(string: endpoint), let scheme = url.scheme, ["http", "https"].contains(scheme),
          url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
        throw APIError(code: "INVALID_ENDPOINT", message: "endpoint must be an HTTP(S) base URL without credentials, query or fragment")
    }
    return endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
}

/// Never follow redirects: they could forward bearer credentials to another host.
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct Envelope {
    let data: Any
    let outcome: String?
    let requestId: String?
}

func requestJSON(_ session: URLSession, method: String, url: String, headers: [String: String],
                 body: Any? = nil, timeout: TimeInterval) async throws -> Envelope {
    guard let target = URL(string: url) else { throw APIError(code: "INVALID_ENDPOINT", message: "Invalid URL") }
    var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "accept")
    if let body = body {
        request.httpBody = try JSON.data(body)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
    }
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await session.data(for: request, delegate: NoRedirect())
    } catch let error as URLError where error.code == .timedOut {
        throw APIError(code: "TIMEOUT", message: "The request timed out", retryable: true)
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
        throw CancellationError()
    } catch {
        throw APIError.network()
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard let envelope = try? JSON.parse(data) as? [String: Any] else {
        throw APIError(code: "PROTOCOL_ERROR", message: "Expected a JSON response envelope", status: status)
    }
    let requestId = envelope["request_id"] as? String
    if !(200..<300).contains(status) || envelope["error"] != nil {
        if envelope["error"] != nil { throw APIError(wire: envelope["error"], status: status, requestId: requestId) }
        throw APIError(code: "HTTP_ERROR", message: "The request was rejected", status: status, requestId: requestId)
    }
    guard let payload = envelope["data"] else {
        throw APIError(code: "PROTOCOL_ERROR", message: "Missing response data", status: status)
    }
    return Envelope(data: payload, outcome: envelope["outcome"] as? String, requestId: requestId)
}

func defaultSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
}
