import Foundation

struct Frame {
    let joinRef: String?
    let ref: String?
    let topic: String
    let event: String
    let payload: [String: Any]
}

/// Decodes one Phoenix frame or a `{"batch": [...]}` wrapper, validating every member.
func decodeFrames(_ raw: Data) -> [Frame]? {
    guard let decoded = try? JSON.parse(raw) else { return nil }
    var members: [Any]
    if let wrapper = decoded as? [String: Any] {
        guard wrapper.count == 1, let batch = wrapper["batch"] as? [Any] else { return nil }
        members = batch
    } else {
        members = [decoded]
    }
    guard !members.isEmpty, members.count <= 64 else { return nil }
    var frames: [Frame] = []
    for member in members {
        guard let parts = member as? [Any], parts.count == 5,
              let topic = parts[2] as? String, let event = parts[3] as? String, let payload = parts[4] as? [String: Any],
              parts[0] is NSNull || parts[0] is String, parts[1] is NSNull || parts[1] is String else { return nil }
        frames.append(Frame(joinRef: parts[0] as? String, ref: parts[1] as? String, topic: topic, event: event, payload: payload))
    }
    return frames
}

func socketURL(endpoint: String, projectId: String) -> URL? {
    var components = URLComponents(string: "ws" + endpoint.dropFirst("http".count) + "/socket/websocket")
    components?.queryItems = [URLQueryItem(name: "project_id", value: projectId), URLQueryItem(name: "vsn", value: "2.0.0")]
    return components?.url
}

func authProtocol(_ token: String) -> String {
    let encoded = Data(token.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "base64url.bearer.phx." + encoded
}

typealias Reply = (_ status: String, _ response: [String: Any]?) -> Void

/// One authenticated socket. `onFrame` and `onClose` run on the URLSession delegate queue, in order.
final class Connection: NSObject, URLSessionWebSocketDelegate {
    private let lock = NSLock()
    private let timeout: TimeInterval
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private var pending: [String: (reply: Reply, timer: DispatchSourceTimer)] = [:]
    private var refs = 0
    private var closed = false
    private var opened: CheckedContinuation<Void, Error>?
    private var heartbeat: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "fyrlet.connection")
    var onFrame: ((Connection, Frame) -> Void)?
    var onClose: ((Connection, APIError?) -> Void)?

    /// Connects and waits for the WebSocket handshake.
    static func open(endpoint: String, projectId: String, token: String, timeout: TimeInterval,
                     onFrame: @escaping (Connection, Frame) -> Void,
                     onClose: @escaping (Connection, APIError?) -> Void) async throws -> Connection {
        guard let url = socketURL(endpoint: endpoint, projectId: projectId) else { throw APIError(code: "INVALID_ENDPOINT", message: "Invalid URL") }
        let connection = Connection(timeout: timeout)
        connection.onFrame = onFrame
        connection.onClose = onClose
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1  // frames are processed strictly in order
        connection.session = URLSession(configuration: configuration, delegate: connection, delegateQueue: operationQueue)
        connection.task = connection.session.webSocketTask(with: url, protocols: ["phoenix", authProtocol(token)])
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.lock.lock()
                connection.opened = continuation
                connection.lock.unlock()
                connection.task.resume()
            }
        } catch {
            connection.close()
            throw error
        }
        connection.receiveNext()
        connection.startHeartbeat()
        return connection
    }

    private init(timeout: TimeInterval) { self.timeout = timeout }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        resumeOpen(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let failure: APIError = (status == 401 || status == 403)
            ? APIError(code: "UNAUTHENTICATED", message: "The socket rejected the session", status: status)
            : APIError.network("The connection was interrupted")
        if resumeOpen(failure) { return }
        shutdown(failure, notify: true)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        shutdown(APIError.network("The connection was interrupted"), notify: true)
    }

    @discardableResult
    private func resumeOpen(_ error: Error?) -> Bool {
        lock.lock()
        let continuation = opened
        opened = nil
        lock.unlock()
        guard let continuation = continuation else { return false }
        if let error = error { continuation.resume(throwing: error) } else { continuation.resume() }
        return true
    }

    // MARK: outbound

    private func nextRef() -> String {
        lock.lock(); defer { lock.unlock() }
        refs += 1
        return String(refs)
    }

    private func register(_ ref: String, _ reply: @escaping Reply) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if closed { return false }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let entry = self.pending.removeValue(forKey: ref)
            self.lock.unlock()
            entry?.timer.cancel()
            entry?.reply("timeout", nil)
        }
        pending[ref] = (reply, timer)
        timer.resume()
        return true
    }

    private func send(_ parts: [Any], onFailure: (() -> Void)? = nil) {
        guard let data = try? JSON.data(parts), let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            guard error != nil, let self = self else { return }
            onFailure?()
            self.shutdown(APIError.network("The connection was interrupted"), notify: true)
        }
    }

    /// Sends an event; `reply` receives "ok", "error" or "timeout" exactly once.
    @discardableResult
    func push(_ topic: String, _ event: String, _ payload: [String: Any], reply: @escaping Reply) -> Bool {
        let ref = nextRef()
        guard register(ref, reply) else { return false }
        send([NSNull(), ref, topic, event, payload])
        return true
    }

    @discardableResult
    func join(_ topic: String, _ payload: [String: Any], reply: @escaping Reply) -> Bool {
        let ref = nextRef()
        guard register(ref, reply) else { return false }
        send([ref, ref, topic, "phx_join", payload])
        return true
    }

    /// Fire-and-forget event with no ref, such as `ack`.
    func notify(_ topic: String, _ event: String, _ payload: [String: Any]) {
        send([NSNull(), NSNull(), topic, event, payload])
    }

    func leave(_ topic: String) { send([NSNull(), nextRef(), topic, "phx_leave", [String: Any]()]) }

    func close() { shutdown(nil, notify: false) }

    // MARK: inbound

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                self.shutdown(APIError.network("The connection was interrupted"), notify: true)
            case .success(let message):
                let raw: Data
                switch message {
                case .string(let text): raw = Data(text.utf8)
                case .data(let data): raw = data
                @unknown default: raw = Data()
                }
                guard let frames = decodeFrames(raw) else {
                    self.shutdown(APIError(code: "PROTOCOL_ERROR", message: "Invalid transport frame"), notify: true)
                    return
                }
                for frame in frames { self.dispatch(frame) }
                self.receiveNext()
            }
        }
    }

    private func dispatch(_ frame: Frame) {
        if frame.event == "phx_reply", let ref = frame.ref {
            lock.lock()
            let entry = pending.removeValue(forKey: ref)
            lock.unlock()
            if let entry = entry {
                entry.timer.cancel()
                entry.reply(frame.payload["status"] as? String ?? "error", frame.payload["response"] as? [String: Any])
            }
            return
        }
        onFrame?(self, frame)
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.push("phoenix", "heartbeat", [:]) { status, _ in
                if status == "timeout" { self?.shutdown(APIError.network("Heartbeat timed out"), notify: true) }
            }
        }
        lock.lock(); heartbeat = timer; lock.unlock()
        timer.resume()
    }

    private func shutdown(_ failure: APIError?, notify: Bool) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let waiters = Array(pending.values)
        pending.removeAll()
        let beat = heartbeat
        lock.unlock()
        beat?.cancel()
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        // Callbacks run asynchronously because the caller may hold the client lock they take.
        for waiter in waiters { waiter.timer.cancel(); queue.async { waiter.reply("timeout", nil) } }
        if notify { queue.async { self.onClose?(self, failure) } }
    }
}
