import Foundation

/// The maximum number of consecutive retryable join failures of one subscription before it is reported as failed.
let maxJoinRetries = 10

/// Configuration for a `Client`.
public struct Options {
    /// HTTP(S) base URL of the Fyrlet server.
    public var endpoint: String
    /// The project this client is bound to.
    public var projectId: String
    /// Returns a short-lived user session token (`rts_...`). With `forceRefresh` set, revalidate the host login and
    /// obtain a new session, or throw `APIError(code: "UNAUTHENTICATED", ...)` to stop recovery.
    public var getToken: (_ forceRefresh: Bool) async throws -> String
    /// Bounds each HTTP request and socket reply. Default 10 seconds.
    public var timeout: TimeInterval = 10
    /// Backoff before reconnect attempt n (1-based). Default 250 ms doubling to 30 s.
    public var retryDelay: ((Int) -> TimeInterval)?
    /// Request `delta-v1` field deltas. Disable to receive full snapshots only.
    public var delta = true
    /// Optional capabilities to negotiate, as name -> version.
    public var capabilities: [String: Int] = [:]
    /// Generates idempotency keys and subscription IDs.
    public var makeId: () -> String = { UUID().uuidString.lowercased() }
    /// Overrides the URLSession used for HTTP.
    public var urlSession: URLSession?

    public init(endpoint: String, projectId: String, getToken: @escaping (_ forceRefresh: Bool) async throws -> String) {
        self.endpoint = endpoint; self.projectId = projectId; self.getToken = getToken
    }
}

public enum MutationStatus: String {
    /// A successful read.
    case completed
    /// A write committed to the database.
    case committed
    /// A Run or ingest accepted for later execution.
    case accepted
    /// A definite failure: nothing was written.
    case failed
    /// The write was dispatched but its result was not seen. Use `recover`.
    case unknown
}

public struct MutationState {
    public let status: MutationStatus
    public let data: Any?
    public let error: Error?
}

/// A stored receipt: `committed` or `accepted` with the original `data`, or `unknown`.
public struct RecoveryResult {
    public let status: MutationStatus
    public let data: Any?
}

/// Keeps the outcome of an operation so an unknown result can be recovered later.
public final class Mutation {
    public let idempotencyKey: String
    private let lock = NSLock()
    private var current: MutationState
    private let lookup: () async throws -> RecoveryResult

    init(key: String, state: MutationState, lookup: @escaping () async throws -> RecoveryResult) {
        idempotencyKey = key; current = state; self.lookup = lookup
    }

    public var state: MutationState { lock.lock(); defer { lock.unlock() }; return current }

    /// The business result, or the original error.
    public func result() throws -> Any {
        let snapshot = state
        switch snapshot.status {
        case .completed, .committed, .accepted: return snapshot.data ?? NSNull()
        default: throw snapshot.error ?? APIError(code: "PROTOCOL_ERROR", message: "The operation has no result")
        }
    }

    /// Queries the stored receipt of an `unknown` write without executing it again.
    public func recover() async throws -> MutationState {
        guard state.status == .unknown else { return state }
        let found = try await lookup()
        return settle(found)
    }

    private func settle(_ found: RecoveryResult) -> MutationState {
        lock.lock(); defer { lock.unlock() }
        if current.status == .unknown, found.status != .unknown {
            current = MutationState(status: found.status, data: found.data, error: nil)
        }
        return current
    }
}

private final class Flag { var value = false }

/// Bound to one project and one user; safe for concurrent use.
public final class Client {
    private let options: Options
    private let endpoint: String
    private let http: URLSession
    private let lock = NSRecursiveLock()
    private let listenerQueue = DispatchQueue(label: "fyrlet.listeners")
    private let retryQueue = DispatchQueue(label: "fyrlet.retry")

    private var entries: [String: Entry] = [:]
    private var connection: Connection?
    private var identity: (project: String, subject: String)?
    private var token: String?
    private var flight: Task<String, Error>?
    private var epoch = 0
    private var connectingEpoch = -1
    private var retries = 0
    private var retryItem: DispatchWorkItem?
    private var closed = false

    public init(_ options: Options) throws {
        guard !options.projectId.isEmpty else { throw APIError(code: "INVALID_OPTIONS", message: "projectId is required") }
        for (name, version) in options.capabilities where name.range(of: "^[a-z][a-z0-9_.-]*$", options: .regularExpression) == nil || version < 1 {
            throw APIError(code: "INVALID_OPTIONS", message: "capabilities must be names with a positive integer version")
        }
        self.options = options
        self.endpoint = try endpointURL(options.endpoint)
        self.http = options.urlSession ?? defaultSession()
    }

    deinit { close() }

    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    // MARK: operations

    /// Runs an operation and returns its business result (decoded JSON; see `decode(_:from:)`).
    ///
    /// The SDK generates an idempotency key. After a network interruption the outcome of a write is unknown
    /// and the thrown `OutcomeUnknownError` carries the key for `recover`. Reuse that key explicitly if you
    /// decide to submit the write again.
    @discardableResult
    public func call(_ name: String, _ input: Any? = nil, idempotencyKey: String? = nil) async throws -> Any {
        try await mutate(name, input, idempotencyKey: idempotencyKey).result()
    }

    /// Like `call`, but never throws for a failed operation: inspect `Mutation.state`.
    public func mutate(_ name: String, _ input: Any? = nil, idempotencyKey: String? = nil) async -> Mutation {
        let key = idempotencyKey ?? options.makeId()
        let body: [String: Any] = ["input": input ?? [String: Any]()]
        let lookup: () async throws -> RecoveryResult = { [unowned self] in try await self.recoverReceipt(name, body, key) }
        do { try assertOpen() } catch {
            return Mutation(key: key, state: MutationState(status: .failed, data: nil, error: error), lookup: lookup)
        }
        let sent = Flag()
        do {
            let envelope = try await execute { token in
                sent.value = true
                do {
                    return try await self.request("POST", self.operationPath(name), token, body, key)
                } catch let error as APIError {
                    // A definite rejection by the server means nothing was written.
                    if (400..<500).contains(error.status), error.code != "PROTOCOL_ERROR", error.code != "HTTP_ERROR" { sent.value = false }
                    throw error
                }
            }
            guard let outcome = envelope.outcome, let status = MutationStatus(rawValue: outcome),
                  [.completed, .committed, .accepted].contains(status) else {
                throw APIError(code: "PROTOCOL_ERROR", message: "Invalid operation outcome")
            }
            return Mutation(key: key, state: MutationState(status: status, data: envelope.data, error: nil), lookup: lookup)
        } catch {
            if sent.value {
                let unknown = OutcomeUnknownError(operation: name, idempotencyKey: key, cause: error)
                return Mutation(key: key, state: MutationState(status: .unknown, data: nil, error: unknown), lookup: lookup)
            }
            return Mutation(key: key, state: MutationState(status: .failed, data: nil, error: error), lookup: lookup)
        }
    }

    /// Looks up the stored receipt of a write without executing it.
    public func recover(_ name: String, _ input: Any? = nil, idempotencyKey: String) async throws -> RecoveryResult {
        try assertOpen()
        return try await recoverReceipt(name, ["input": input ?? [String: Any]()], idempotencyKey)
    }

    /// The business contract this server exports.
    public func contract() async throws -> Any {
        try await execute { try await self.request("GET", "/api/v1/contract", $0, nil, nil) }.data
    }

    private func operationPath(_ name: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return "/api/v1/operations/" + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)
    }

    private func recoverReceipt(_ name: String, _ body: [String: Any], _ key: String) async throws -> RecoveryResult {
        let envelope = try await execute { try await self.request("POST", self.operationPath(name) + "/recover", $0, body, key) }
        switch envelope.outcome {
        case "unknown" where envelope.data is NSNull: return RecoveryResult(status: .unknown, data: nil)
        case "committed", "accepted": return RecoveryResult(status: MutationStatus(rawValue: envelope.outcome!)!, data: envelope.data)
        default: throw APIError(code: "PROTOCOL_ERROR", message: "Invalid recovery outcome")
        }
    }

    private func request(_ method: String, _ path: String, _ token: String, _ body: Any?, _ key: String?) async throws -> Envelope {
        var headers = ["authorization": "Bearer \(token)", "x-project-id": options.projectId]
        if let key = key { headers["idempotency-key"] = key }
        if !options.capabilities.isEmpty {
            headers["x-fyrlet-capabilities"] = options.capabilities.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        }
        return try await requestJSON(http, method: method, url: endpoint + path, headers: headers, body: body, timeout: options.timeout)
    }

    /// Authorizes, runs `perform` and refreshes the token at most once after an authentication failure.
    private func execute(_ perform: (String) async throws -> Envelope) async throws -> Envelope {
        do {
            let token = try await authorize(force: false, stale: nil)
            do {
                return try await perform(token)
            } catch let error as APIError where error.status == 401 || error.code == "UNAUTHENTICATED" {
                try assertOpen()
                return try await perform(try await authorize(force: true, stale: token))
            }
        } catch let error as APIError {
            if error.code == "UNAUTHENTICATED" || error.code == "FORBIDDEN" { failAll(error) }
            throw error
        }
    }

    private enum Step {
        case ready(String)
        case wait(Task<String, Error>)
        case run(Task<String, Error>)
    }

    private func nextStep(force: Bool, stale: String?) throws -> Step {
        lock.lock(); defer { lock.unlock() }
        if closed { throw closedError() }
        // Another caller may already have refreshed past the token this one failed with.
        if let token = token, !force || (stale != nil && token != stale) { return .ready(token) }
        if let running = flight { return .wait(running) }
        let task = Task { try await self.refreshToken(force: force) }
        flight = task
        return .run(task)
    }

    private func finishFlight(_ task: Task<String, Error>) {
        withLock { if flight == task { flight = nil } }
    }

    private func authorize(force: Bool, stale: String?) async throws -> String {
        while true {
            switch try nextStep(force: force, stale: stale) {
            case .ready(let token): return token
            case .wait(let running): _ = try? await running.value  // then re-evaluate
            case .run(let task):
                defer { finishFlight(task) }
                return try await task.value
            }
        }
    }

    private func refreshToken(force: Bool) async throws -> String {
        var fresh = try await userToken(force)
        var found: (project: String, subject: String)
        do {
            found = try await identityFor(fresh)
        } catch let error as APIError where !force && error.status == 401 {
            fresh = try await userToken(true)
            found = try await identityFor(fresh)
        }
        return try withLock {
            try assertOpen()
            if found.project != options.projectId || (identity != nil && found.subject != identity!.subject) {
                throw APIError(code: "FORBIDDEN", message: "Create a new client when changing accounts")
            }
            identity = found
            token = fresh
            return fresh
        }
    }

    private func userToken(_ force: Bool) async throws -> String {
        let value = try await options.getToken(force)
        try assertOpen()
        guard value.hasPrefix("rts_") else {
            throw APIError(code: "UNAUTHENTICATED", message: "getToken must return a user session token")
        }
        return value
    }

    private func identityFor(_ token: String) async throws -> (project: String, subject: String) {
        let envelope = try await request("GET", "/api/v1/identity", token, nil, nil)
        guard let data = envelope.data as? [String: Any], let project = data["project_id"] as? String,
              let subject = data["subject_id"] as? String else {
            throw APIError(code: "PROTOCOL_ERROR", message: "Invalid identity response")
        }
        return (project, subject)
    }

    private func closedError() -> APIError { APIError(code: "CLIENT_CLOSED", message: "The client is closed") }

    private func assertOpen() throws {
        if withLock({ closed }) { throw closedError() }
    }

    // MARK: subscriptions

    /// Starts a realtime subscription. Observe it with `Subscription.onChange`.
    public func subscribe(_ name: String, params: Any? = nil) throws -> Subscription {
        lock.lock(); defer { lock.unlock() }
        try assertOpen()
        let id = options.makeId()
        guard entries[id] == nil else { throw APIError(code: "INVALID_OPTIONS", message: "makeId returned a duplicate subscription ID") }
        let entry = Entry(id: id, name: name, params: params ?? [String: Any](), wantDelta: options.delta)
        entries[id] = entry
        if let connection = connection { attach(entry, connection, epoch) } else { start(force: false) }
        return Subscription(client: self, entry: entry)
    }

    func addListener(_ entry: Entry, _ listener: @escaping (State) -> Void) -> () -> Void {
        lock.lock(); defer { lock.unlock() }
        let id = entry.nextListener
        entry.nextListener += 1
        entry.listeners[id] = listener
        dispatch(listener, entry.state)
        return { [weak self, weak entry] in
            guard let self = self, let entry = entry else { return }
            self.withLock { entry.listeners[id] = nil }
        }
    }

    func refresh(_ entry: Entry) async throws {
        let target: Connection? = withLock { entry.state.status == .ready ? entry.connection : nil }
        guard let connection = target else { throw APIError(code: "NOT_READY", message: "The subscription is not ready") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let sent = connection.push(entry.topic, "refresh", [:]) { status, response in
                switch status {
                case "ok": continuation.resume()
                case "error": continuation.resume(throwing: APIError.channel(response))
                default: continuation.resume(throwing: APIError(code: "TIMEOUT", message: "refresh was not acknowledged", retryable: true))
                }
            }
            if !sent { continuation.resume(throwing: APIError.network("The connection was interrupted")) }
        }
    }

    func unsubscribe(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        guard entries.removeValue(forKey: entry.id) != nil else { return }
        cancelRejoin(entry)
        entry.connection?.leave(entry.topic)
        entry.connection = nil
        entry.state = State(status: .closed, data: nil, error: nil, generation: entry.state.generation, seq: entry.state.seq)
        emit(entry)
        entry.listeners.removeAll()
        if entries.isEmpty { detach() }
    }

    /// Explicitly rebuilds the connection and the retained subscriptions.
    public func reconnect() async throws {
        let target: Int? = try withLock {
            try assertOpen()
            detach()
            recovering()
            return entries.isEmpty ? nil : epoch
        }
        guard let target = target else { return }
        do { try await connect(force: true, epoch: target) } catch {
            withLock { connectionFailed(error, target) }
            throw error
        }
    }

    /// Releases subscriptions, timers and connections. The client cannot be reused.
    public func close() {
        lock.lock(); defer { lock.unlock() }
        if closed { return }
        closed = true
        detach()
        for entry in entries.values {
            entry.state = State(status: .closed)
            emit(entry)
            entry.listeners.removeAll()
        }
        entries.removeAll()
        token = nil
    }

    // MARK: connection management (callers hold `lock` unless noted)

    private func start(force: Bool) {
        let target = epoch
        if connectingEpoch == target { return }
        connectingEpoch = target
        Task {
            do { try await self.connect(force: force, epoch: target) } catch {
                self.withLock { self.connectionFailed(error, target) }
            }
        }
    }

    /// Runs without the lock held.
    private func connect(force: Bool, epoch target: Int) async throws {
        defer { withLock { if connectingEpoch == target { connectingEpoch = -1 } } }
        let token = try await authorize(force: force, stale: nil)
        let stale = withLock { closed || epoch != target || entries.isEmpty || connection != nil }
        if stale { return }
        let opened = try await Connection.open(
            endpoint: endpoint, projectId: options.projectId, token: token, timeout: options.timeout,
            onFrame: { [weak self] in self?.onFrame($0, $1) }, onClose: { [weak self] in self?.onClose($0, $1) })
        adopt(opened, target)
    }

    private func adopt(_ opened: Connection, _ target: Int) {
        lock.lock(); defer { lock.unlock() }
        if closed || epoch != target || entries.isEmpty { opened.close(); return }
        connection = opened
        for entry in entries.values where entry.state.status != .error { attach(entry, opened, target) }
    }

    private func joinPayload(_ entry: Entry) -> [String: Any] {
        var payload: [String: Any] = ["protocol_version": protocolVersion, "name": entry.name, "params": entry.params]
        if !options.capabilities.isEmpty { payload["capabilities"] = options.capabilities }
        if entry.wantDelta { payload["delivery"] = "delta-v1" }
        return payload
    }

    private func isCurrent(_ entry: Entry, _ conn: Connection, _ target: Int) -> Bool {
        !closed && epoch == target && entry.connection === conn && entries[entry.id] != nil
    }

    private func attach(_ entry: Entry, _ conn: Connection, _ target: Int) {
        entry.connection = conn
        conn.join(entry.topic, joinPayload(entry)) { [weak self] status, response in
            guard let self = self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.isCurrent(entry, conn, target) else { return }
            switch status {
            case "ok":
                self.retries = 0
                entry.joinFailures = 0
                self.receive(entry, conn, snapshot: response, initial: true)
            case "error":
                let error = APIError.channel(response)
                if error.code == "UNAUTHENTICATED" {
                    self.transportFailed(conn)
                } else if error.retryable && entry.joinFailures < maxJoinRetries {
                    // For example the observer was briefly unavailable: retry this subscription only.
                    entry.joinFailures += 1
                    entry.state.status = .recovering
                    entry.state.error = nil
                    self.emit(entry)
                    self.scheduleRejoin(entry, conn, target)
                } else {
                    self.fail(entry, error)
                }
            default:
                self.transportFailed(conn)
            }
        }
    }

    private func scheduleRejoin(_ entry: Entry, _ conn: Connection, _ target: Int) {
        cancelRejoin(entry)
        let item = DispatchWorkItem { [weak self, weak entry] in
            guard let self = self, let entry = entry else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            entry.rejoin = nil
            if self.isCurrent(entry, conn, target) { self.attach(entry, conn, target) }
        }
        entry.rejoin = item
        retryQueue.asyncAfter(deadline: .now() + delay(entry.joinFailures), execute: item)
    }

    private func cancelRejoin(_ entry: Entry) {
        entry.rejoin?.cancel()
        entry.rejoin = nil
    }

    private func delay(_ attempt: Int) -> TimeInterval {
        if let custom = options.retryDelay { return custom(attempt) }
        return min(0.25 * pow(2, Double(min(max(attempt - 1, 0), 7))), 30)
    }

    private func onFrame(_ conn: Connection, _ frame: Frame) {
        lock.lock(); defer { lock.unlock() }
        guard conn === connection, !closed, frame.topic.hasPrefix("subscription:"),
              let entry = entries[String(frame.topic.dropFirst("subscription:".count))], entry.connection === conn else { return }
        switch frame.event {
        case "snapshot": receive(entry, conn, snapshot: frame.payload, initial: false)
        case "delta": receive(entry, conn, delta: frame.payload)
        case "status":
            let error = APIError.channel(frame.payload)
            if error.code == "UNAUTHENTICATED" {
                for item in entries.values { item.state.data = nil }
                transportFailed(conn)
            } else if error.retryable {
                transportFailed(conn)
            } else {
                fail(entry, error)
            }
        case "phx_error": transportFailed(conn)
        case "phx_close": fail(entry, APIError(code: "SUBSCRIPTION_CLOSED", message: "The server closed the subscription"))
        default: break
        }
    }

    private func onClose(_ conn: Connection, _ failure: APIError?) {
        lock.lock(); defer { lock.unlock() }
        guard conn === connection, !closed else { return }
        if let failure = failure, !failure.retryable { failAllLocked(failure) } else { transportFailed(conn) }
    }

    private func receive(_ entry: Entry, _ conn: Connection, snapshot payload: [String: Any]?, initial: Bool) {
        apply(entry, conn) { try entry.applySnapshot(payload, identity: self.identity, initial: initial) }
    }

    private func receive(_ entry: Entry, _ conn: Connection, delta payload: [String: Any]) {
        apply(entry, conn) { try entry.applyDelta(payload) }
    }

    private func apply(_ entry: Entry, _ conn: Connection, _ change: () throws -> Applied) {
        let before = entry.state
        let result: Applied
        do { result = try change() } catch {
            fail(entry, asAPIError(error))
            return
        }
        if entry.state.seq != before.seq || entry.state.status != before.status || entry.state.generation != before.generation {
            emit(entry)
        }
        switch result {
        case .reconnect: transportFailed(conn)
        case .ack(let ack): conn.notify(entry.topic, "ack", ["g": ack.generation, "s": ack.seq])
        case .none: break
        }
    }

    private func transportFailed(_ conn: Connection) {
        guard conn === connection, !closed else { return }
        detach()
        recovering()
        scheduleRetry()
    }

    private func connectionFailed(_ error: Error, _ target: Int) {
        guard !closed, epoch == target, !(error is CancellationError) else { return }
        // A foreign error, such as a failing getToken, counts as a retryable network failure.
        let failure = asAPIError(error)
        if !failure.retryable { failAllLocked(failure) } else { recovering(); scheduleRetry() }
    }

    private func scheduleRetry() {
        guard !closed, retryItem == nil, !entries.isEmpty else { return }
        retries += 1
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.retryItem = nil
            if !self.closed && !self.entries.isEmpty { self.start(force: true) }
        }
        retryItem = item
        retryQueue.asyncAfter(deadline: .now() + delay(retries), execute: item)
    }

    private func recovering() {
        for entry in entries.values where entry.state.status != .error {
            entry.state.status = .recovering
            entry.state.error = nil
            emit(entry)
        }
    }

    private func failAll(_ error: APIError) { withLock { failAllLocked(error) } }

    private func failAllLocked(_ error: APIError) {
        detach()
        token = nil
        for entry in entries.values { fail(entry, error) }
    }

    private func fail(_ entry: Entry, _ error: APIError) {
        cancelRejoin(entry)
        entry.connection?.leave(entry.topic)
        entry.connection = nil
        entry.state.status = .error
        entry.state.data = nil
        entry.state.error = error
        emit(entry)
    }

    private func detach() {
        epoch += 1
        connectingEpoch = -1
        retryItem?.cancel()
        retryItem = nil
        let old = connection
        connection = nil
        for entry in entries.values { cancelRejoin(entry); entry.connection = nil }
        old?.close()
    }

    // MARK: listener dispatch

    private func emit(_ entry: Entry) {
        for listener in entry.listeners.values { dispatch(listener, entry.state) }
    }

    private func dispatch(_ listener: @escaping (State) -> Void, _ state: State) {
        listenerQueue.async { listener(state) }
    }
}
