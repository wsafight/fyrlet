import XCTest
@testable import Fyrlet

// Runs against a real Fyrlet inbox server. Start it with scripts/integration_sdks.sh.

private struct Item: Decodable { let id: String; let text: String; let version: Int }
private struct Project: Decodable { let project_id: String; let service_key: String }

final class IntegrationTests: XCTestCase {
    private var endpoint = ""
    private var projects: [Project] = []
    private var clients: [Client] = []

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["INTEGRATION_ENDPOINT"], let fixtures = environment["INTEGRATION_FIXTURES"] else {
            throw XCTSkip("needs INTEGRATION_ENDPOINT / INTEGRATION_FIXTURES")
        }
        self.endpoint = endpoint
        projects = try JSONDecoder().decode([Project].self, from: Data(contentsOf: URL(fileURLWithPath: fixtures)))
    }

    override func tearDown() { clients.forEach { $0.close() }; clients = [] }

    private func service(_ project: Int = 0) throws -> SessionService {
        try SessionService(endpoint: endpoint, serviceKey: projects[project].service_key)
    }

    private func user(project: Int = 0, subject: String = UUID().uuidString, retryDelay: Double = 0.05,
                      session: URLSession? = nil) async throws -> Client {
        let issued = try await service(project).issueSession(externalSubject: subject, ttlSeconds: 600)
        var options = Options(endpoint: endpoint, projectId: projects[project].project_id) { _ in issued.token }
        options.retryDelay = { _ in retryDelay }
        options.urlSession = session
        let client = try Client(options)
        clients.append(client)
        return client
    }

    private func until(_ what: String, timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not reached: \(what)")
        throw CancellationError()
    }

    private func ready(_ sub: Subscription) async throws { try await until("ready") { sub.state.status == .ready } }
    private func items(_ sub: Subscription) -> [Item] { (try? sub.state.decoded([Item].self)) ?? [] }

    func testCallIdempotencyConflictAndContract() async throws {
        let client = try await user()
        let key = UUID().uuidString
        let first = try decode(Item.self, from: try await client.call("inbox.add", ["text": "hello"], idempotencyKey: key))
        let again = try decode(Item.self, from: try await client.call("inbox.add", ["text": "hello"], idempotencyKey: key))
        XCTAssertEqual(first.id, again.id)
        do { _ = try await client.call("inbox.add", ["text": "changed"], idempotencyKey: key); XCTFail("expected CONFLICT") }
        catch let error as APIError { XCTAssertEqual(error.code, "CONFLICT"); XCTAssertEqual(error.status, 409) }
        let history = try await client.call("inbox.history", [:]) as! [String: Any]
        XCTAssertEqual((history["items"] as! [Any]).count, 1)
        _ = try await client.call("inbox.update", ["id": first.id, "text": "new", "expected_version": first.version])
        do { _ = try await client.call("inbox.update", ["id": first.id, "text": "late", "expected_version": first.version]); XCTFail() }
        catch let error as APIError { XCTAssertEqual(error.code, "CONFLICT") }
        let contract = try await client.contract()
        XCTAssertTrue(String(data: try JSON.data(contract), encoding: .utf8)!.contains("inbox.add"))
    }

    func testSubscriptionSnapshotDeltaRefreshAndSharedDevices() async throws {
        let subject = UUID().uuidString
        let first = try await user(subject: subject), second = try await user(subject: subject)
        let left = try first.subscribe("inbox.recent"), right = try second.subscribe("inbox.recent")
        try await ready(left); try await ready(right)
        let seen = Locked<[Status]>([])
        left.onChange { state in seen.update { $0.append(state.status) } }
        let created = try decode(Item.self, from: try await first.call("inbox.add", ["text": "shared"]))
        try await until("left sees item") { self.items(left).contains { $0.id == created.id } }
        try await until("right sees item") { self.items(right).contains { $0.id == created.id } }
        _ = try await first.call("inbox.update", ["id": created.id, "text": "edited", "expected_version": created.version])
        try await until("delta applied") { self.items(left).first?.text == "edited" }
        let before = left.state.seq
        try await left.refresh()
        try await until("refresh snapshot") { left.state.seq > before }
        XCTAssertEqual(seen.value.first, .ready)
        left.unsubscribe()
        XCTAssertEqual(left.state.status, .closed)
        XCTAssertNil(left.state.data)
        do { try await left.refresh(); XCTFail() } catch let error as APIError { XCTAssertEqual(error.code, "NOT_READY") }
    }

    func testAuthorizationIsolation() async throws {
        let owner = try await user()
        _ = try await owner.call("inbox.add", ["text": "private"])
        for other in [try await user(), try await user(project: 1)] {
            let sub = try other.subscribe("inbox.recent")
            try await ready(sub)
            XCTAssertTrue(items(sub).isEmpty)
            let history = try await other.call("inbox.history", [:]) as! [String: Any]
            XCTAssertTrue((history["items"] as! [Any]).isEmpty)
        }
    }

    func testLostResponseIsUnknownThenRecoveredWithoutSecondWrite() async throws {
        LossyProtocol.writes.update { $0 = 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LossyProtocol.self]
        let client = try await user(session: URLSession(configuration: configuration))
        let mutation = await client.mutate("inbox.add", ["text": "lost"])
        XCTAssertEqual(mutation.state.status, .unknown)
        XCTAssertTrue(mutation.state.error is OutcomeUnknownError)
        XCTAssertThrowsError(try mutation.result())
        let recovered = try await mutation.recover()
        XCTAssertEqual(recovered.status, .committed)
        XCTAssertEqual(try decode(Item.self, from: recovered.data!).text, "lost")
        XCTAssertEqual(LossyProtocol.writes.value, 1)
        let stranger = try await user()
        let found = try await stranger.recover("inbox.add", ["text": "lost"], idempotencyKey: mutation.idempotencyKey)
        XCTAssertEqual(found.status, .unknown)
    }

    func testTokenRefreshAndRevocation() async throws {
        let sessions = try service()
        let subject = UUID().uuidString
        let old = try await sessions.issueSession(externalSubject: subject)
        try await sessions.revokeSession(old.sessionId)
        let calls = Locked<[Bool]>([])
        let client = try Client(Options(endpoint: endpoint, projectId: projects[0].project_id) { force in
            calls.update { $0.append(force) }
            return force ? try await sessions.issueSession(externalSubject: subject).token : old.token
        })
        clients.append(client)
        _ = try await client.call("inbox.history", [:])
        XCTAssertEqual(calls.value, [false, true])

        let live = try await sessions.issueSession(externalSubject: subject)
        var options = Options(endpoint: endpoint, projectId: projects[0].project_id) { force in
            if force { throw APIError(code: "UNAUTHENTICATED", message: "logged out") }
            return live.token
        }
        options.retryDelay = { _ in 0.05 }
        let dead = try Client(options)
        clients.append(dead)
        let sub = try dead.subscribe("inbox.recent")
        try await ready(sub)
        try await sessions.revokeSession(live.sessionId)
        try await until("terminal error") { sub.state.status == .error }
        XCTAssertNil(sub.state.data)
        XCTAssertEqual(sub.state.error?.code, "UNAUTHENTICATED")
    }

    func testAccountSwitchIsRejected() async throws {
        let sessions = try service()
        let a = try await sessions.issueSession(externalSubject: UUID().uuidString)
        let b = try await sessions.issueSession(externalSubject: UUID().uuidString)
        let client = try Client(Options(endpoint: endpoint, projectId: projects[0].project_id) { force in force ? b.token : a.token })
        clients.append(client)
        _ = try await client.call("inbox.history", [:])
        try await sessions.revokeSession(a.sessionId)  // the refresh now yields B's identity
        do { _ = try await client.call("inbox.history", [:]); XCTFail("expected FORBIDDEN") }
        catch let error as APIError { XCTAssertEqual(error.code, "FORBIDDEN") }
    }

    func testRecoversAfterReconnectAndCloseReleases() async throws {
        let client = try await user()
        let sub = try client.subscribe("inbox.recent")
        try await ready(sub)
        let created = try decode(Item.self, from: try await client.call("inbox.add", ["text": "before"]))
        try await until("item arrives") { self.items(sub).count == 1 }
        let statuses = Locked<[Status]>([])
        sub.onChange { state in statuses.update { $0.append(state.status) } }
        let generation = sub.state.generation
        try await client.reconnect()
        try await ready(sub)
        try await until("new generation") { sub.state.generation != generation }
        XCTAssertTrue(statuses.value.contains(.recovering))
        XCTAssertEqual(items(sub).map(\.id), [created.id])
        client.close()
        XCTAssertEqual(sub.state.status, .closed)
        do { _ = try await client.call("inbox.history", [:]); XCTFail() } catch let error as APIError { XCTAssertEqual(error.code, "CLIENT_CLOSED") }
        XCTAssertThrowsError(try client.subscribe("inbox.recent"))
    }
}

final class Locked<Value> {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func update(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

/// Performs the real request, then drops the response of `inbox.add` to simulate a lost reply after commit.
final class LossyProtocol: URLProtocol {
    static let writes = Locked(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let plain = URLSession(configuration: .ephemeral)
        var forwarded = request
        if forwarded.httpBody == nil, let stream = forwarded.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            forwarded.httpBody = data
        }
        let isWrite = request.url?.path.hasSuffix("/operations/inbox.add") == true
        plain.dataTask(with: forwarded) { data, response, error in
            if isWrite, error == nil {
                Self.writes.update { $0 += 1 }
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else if let response = response, let data = data {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } else {
                self.client?.urlProtocol(self, didFailWithError: error ?? URLError(.unknown))
            }
        }.resume()
    }
    override func stopLoading() {}
}
