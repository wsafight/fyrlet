// Copy into an executable target of your own package that depends on Fyrlet, then:
//   FYRLET_ENDPOINT=http://127.0.0.1:4000 FYRLET_PROJECT_ID=... FYRLET_SERVICE_KEY=rtk_... swift run inbox "First note"
//
// In a real application the SessionService runs on your backend and only the token reaches the client.
import Fyrlet
import Foundation

struct Item: Decodable { let id: String; let text: String }

@main
struct InboxExample {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        let service = try SessionService(endpoint: environment["FYRLET_ENDPOINT"]!, serviceKey: environment["FYRLET_SERVICE_KEY"]!)
        let client = try Client(Options(endpoint: environment["FYRLET_ENDPOINT"]!, projectId: environment["FYRLET_PROJECT_ID"]!) { _ in
            try await service.issueSession(externalSubject: "example-user", ttlSeconds: 600).token
        })
        defer { client.close() }

        let recent = try client.subscribe("inbox.recent", params: ["limit": 20])
        recent.onChange { state in
            let items = (try? state.decoded([Item].self)) ?? []
            print(state.status, items.map(\.text))
        }
        for text in CommandLine.arguments.dropFirst().isEmpty ? ["Hello from Swift"] : Array(CommandLine.arguments.dropFirst()) {
            try await client.call("inbox.add", ["text": text])
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)  // let the delta arrive before exiting
    }
}
