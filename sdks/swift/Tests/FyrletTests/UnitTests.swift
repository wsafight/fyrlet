import XCTest
@testable import Fyrlet

private func json(_ text: String) -> Any { try! JSON.parse(Data(text.utf8)) }
private func ids(_ view: [[String: Any]]?) -> [String]? { view?.map { $0["id"] as! String } }

final class UnitTests: XCTestCase {
    func testDeltaChangesAndClearsWithoutMutatingInput() {
        let view = json(#"[{"id":"a","text":"x","note":"n"},{"id":"b","text":"y"}]"#)
        let out = applyDeltaPatch(view, json(#"{"c":[["a",{"text":"z"},["note"]]]}"#))!
        XCTAssertEqual(out[0]["text"] as? String, "z")
        XCTAssertNil(out[0]["note"])
        XCTAssertEqual((view as! [[String: Any]])[0]["note"] as? String, "n")
    }

    func testDeltaNullIsNotDeletion() {
        let out = applyDeltaPatch(json(#"[{"id":"a","t":1}]"#), json(#"{"c":[["a",{"t":null}]]}"#))!
        XCTAssertTrue(out[0]["t"] is NSNull)
        XCTAssertEqual(out[0].count, 2)
    }

    func testDeltaAddRemoveReorder() {
        let out = applyDeltaPatch(json(#"[{"id":"a"},{"id":"b"}]"#), json(#"{"r":["a"],"a":[{"id":"c"}],"o":["c","b"]}"#))
        XCTAssertEqual(ids(out), ["c", "b"])
    }

    func testDeltaRejectsInvalidPatches() {
        for patch in [#"{"x":[]}"#, #"{"r":["missing"],"o":["a"]}"#, #"{"a":[{"id":"a"}],"o":["a"]}"#, #"{"c":[["a",{"id":"a"}]]}"#,
                      #"{"c":[["a",{"t":1},["t"]]]}"#, #"{"c":[["a",{"t":1}],["a",{"t":2}]]}"#, #"{"r":["a"]}"#, #"{"c":[["zzz",{"t":1}]]}"#] {
            XCTAssertNil(applyDeltaPatch(json(#"[{"id":"a","t":0}]"#), json(patch)), patch)
        }
    }

    func testDecodeFrames() {
        let frame = #"[null,"1","t","e",{}]"#
        XCTAssertEqual(decodeFrames(Data(frame.utf8))?.count, 1)
        XCTAssertEqual(decodeFrames(Data(#"{"batch":[\#(frame),\#(frame)]}"#.utf8))?.count, 2)
        let many = Array(repeating: frame, count: 65).joined(separator: ",")
        for bad in ["[]", #"{"batch":[]}"#, #"{"batch":[\#(many)]}"#, #"{"batch":[\#(frame)],"x":1}"#, "[1,2]", #"[null,null,"t","e",[]]"#, "nope"] {
            XCTAssertNil(decodeFrames(Data(bad.utf8)), bad)
        }
    }

    func testSocketURLAndAuthProtocol() {
        XCTAssertEqual(socketURL(endpoint: "https://x.test", projectId: "p1")?.absoluteString, "wss://x.test/socket/websocket?project_id=p1&vsn=2.0.0")
        XCTAssertEqual(authProtocol("rts_abc"), "base64url.bearer.phx.cnRzX2FiYw")
    }

    func testEndpointValidation() throws {
        XCTAssertEqual(try endpointURL("http://localhost:4000/"), "http://localhost:4000")
        for bad in ["ftp://x", "http://u:p@x", "http://x?a=1", "http://x#f", "nope"] {
            XCTAssertThrowsError(try endpointURL(bad), bad)
        }
    }

    func testChannelErrorsAndIntegers() {
        let error = APIError.channel(json(#"{"error":{"code":"CONFLICT","message":"m"},"status":409}"#) as? [String: Any])
        XCTAssertEqual(error.code, "CONFLICT")
        XCTAssertEqual(error.status, 409)
        XCTAssertEqual(APIError.channel([:]).code, "PROTOCOL_ERROR")
        XCTAssertNil(JSON.int(true))  // booleans are not integers
        XCTAssertEqual(JSON.int(json("3")), 3)
        XCTAssertNil(JSON.int(json("1.5")))
    }

    private func snapshot(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = ["protocol_version": 1, "subscription_id": "s", "project_id": "p", "subject_id": "u",
                                   "generation": "g1", "seq": 1, "data": [["id": "a"]], "delivery": "delta-v1"]
        for (key, value) in overrides { base[key] = value }
        return base
    }

    func testEntrySnapshotAndDeltaFlow() throws {
        let entry = Entry(id: "s", name: "n", params: [:], wantDelta: true)
        let who = (project: "p", subject: "u")
        guard case .ack(let first) = try entry.applySnapshot(snapshot(), identity: who, initial: true) else { return XCTFail() }
        XCTAssertEqual(first.seq, 1)
        XCTAssertEqual(entry.state.status, .ready)
        guard case .ack(let second) = try entry.applyDelta(json(#"{"g":"g1","b":1,"s":2,"p":{"c":[["a",{"t":1}]]}}"#) as! [String: Any]) else { return XCTFail() }
        XCTAssertEqual(second.seq, 2)
        XCTAssertEqual(entry.state.seq, 2)
        guard case .ack = try entry.applyDelta(json(#"{"g":"g1","b":1,"s":2,"p":{}}"#) as! [String: Any]) else { return XCTFail("duplicate is re-acknowledged") }
        guard case .none = try entry.applyDelta(json(#"{"g":"old","b":1,"s":2,"p":{}}"#) as! [String: Any]) else { return XCTFail("old generation ignored") }
        guard case .reconnect = try entry.applyDelta(json(#"{"g":"g1","b":3,"s":4,"p":{}}"#) as! [String: Any]) else { return XCTFail("gap reconnects") }
    }

    func testEntryRejectsForeignSnapshotsAndUnnegotiatedDeltas() throws {
        let who = (project: "p", subject: "u")
        for override in [["subject_id": "other"], ["subscription_id": "x"], ["seq": 0], ["protocol_version": 2]] as [[String: Any]] {
            XCTAssertThrowsError(try Entry(id: "s", name: "n", params: [:], wantDelta: true).applySnapshot(snapshot(override), identity: who, initial: true))
        }
        let entry = Entry(id: "s", name: "n", params: [:], wantDelta: true)
        _ = try entry.applySnapshot(snapshot(["delivery": "snapshot"]), identity: who, initial: true)
        XCTAssertThrowsError(try entry.applyDelta(["g": "g1", "b": 1, "s": 2, "p": [String: Any]()]))
    }
}
