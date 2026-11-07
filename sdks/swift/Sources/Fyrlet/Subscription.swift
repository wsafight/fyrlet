import Foundation

let protocolVersion = 1

/// The lifecycle of a subscription.
public enum Status: String {
    /// The initial connection.
    case connecting
    /// The subscription holds a current snapshot.
    case ready
    /// The previous `data` is retained while the connection is rebuilt.
    case recovering
    /// Terminal: `data` is cleared and `error` explains why.
    case error
    /// Terminal: the subscription or client was closed.
    case closed
}

/// What a listener sees. `data` is decoded JSON (arrays of dictionaries) and is never modified in place:
/// a later delta creates new containers.
public struct State {
    public var status: Status = .connecting
    public var data: Any? = nil
    public var error: APIError? = nil
    public var generation: String? = nil
    public var seq: Int = 0

    /// Decodes `data` into your own `Decodable` type.
    public func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        guard let data = data else { throw APIError(code: "NO_DATA", message: "The subscription has no data") }
        return try JSON.decode(type, from: data)
    }
}

struct Ack { let generation: String; let seq: Int }

enum Applied {
    case none
    case ack(Ack)
    case reconnect
}

final class Entry {
    let id: String
    let name: String
    let params: Any
    let wantDelta: Bool
    var state = State()
    var listeners: [Int: (State) -> Void] = [:]
    var nextListener = 0
    var connection: Connection?
    var joinFailures = 0
    var rejoin: DispatchWorkItem?
    private var deltaNegotiated = false

    init(id: String, name: String, params: Any, wantDelta: Bool) {
        self.id = id; self.name = name; self.params = params; self.wantDelta = wantDelta
    }

    var topic: String { "subscription:\(id)" }

    func applySnapshot(_ payload: [String: Any]?, identity: (project: String, subject: String)?, initial: Bool) throws -> Applied {
        guard let payload = payload, JSON.int(payload["protocol_version"]) == protocolVersion,
              payload["subscription_id"] as? String == id, let identity = identity,
              payload["project_id"] as? String == identity.project, payload["subject_id"] as? String == identity.subject,
              let generation = payload["generation"] as? String, let seq = JSON.int(payload["seq"]), seq >= 1,
              let data = payload["data"] else {
            throw APIError(code: "PROTOCOL_ERROR", message: "Invalid subscription snapshot")
        }
        if !initial && generation != state.generation { return .none }
        if initial { deltaNegotiated = payload["delivery"] as? String == "delta-v1" }
        if initial || seq > state.seq {
            state = State(status: .ready, data: data, error: nil, generation: generation, seq: seq)
        }
        return .ack(Ack(generation: generation, seq: seq))
    }

    func applyDelta(_ payload: [String: Any]) throws -> Applied {
        guard payload["g"] as? String == state.generation else { return .none }
        guard deltaNegotiated, let seq = JSON.int(payload["s"]), let base = JSON.int(payload["b"]),
              seq >= 2, base >= 1, seq == base + 1, let generation = state.generation else {
            throw APIError(code: "PROTOCOL_ERROR", message: "Invalid subscription delta sequence")
        }
        if seq <= state.seq { return .ack(Ack(generation: generation, seq: seq)) }
        if base != state.seq { return .reconnect }
        guard let data = applyDeltaPatch(state.data, payload["p"]) else {
            throw APIError(code: "PROTOCOL_ERROR", message: "Invalid subscription delta")
        }
        state = State(status: .ready, data: data, error: nil, generation: generation, seq: seq)
        return .ack(Ack(generation: generation, seq: seq))
    }
}

/// A handle to one realtime subscription. All members are safe to use from any thread.
public final class Subscription {
    private let client: Client
    let entry: Entry

    init(client: Client, entry: Entry) { self.client = client; self.entry = entry }

    /// The current state.
    public var state: State { client.withLock { entry.state } }

    /// Registers a listener. It receives the current state first, then every change, serially on a
    /// dedicated queue, so it may call back into the client. Call the returned closure to remove it.
    @discardableResult
    public func onChange(_ listener: @escaping (State) -> Void) -> () -> Void {
        client.addListener(entry, listener)
    }

    /// Asks the server for a fresh snapshot. Returns once the server accepted the request; the data arrives
    /// through `onChange`.
    public func refresh() async throws { try await client.refresh(entry) }

    /// Ends this subscription. Safe to call more than once.
    public func unsubscribe() { client.unsubscribe(entry) }
}
