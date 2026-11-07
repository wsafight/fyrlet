import Foundation

let maxItems = 100

/// Applies a compact `delta-v1` patch. The input view is never modified; returns nil if the patch is invalid.
func applyDeltaPatch(_ data: Any?, _ patch: Any?) -> [[String: Any]]? {
    guard let view = data as? [[String: Any]], view.count <= maxItems, let changes = patch as? [String: Any],
          changes.keys.allSatisfy({ ["a", "c", "r", "o"].contains($0) }) else { return nil }
    var records: [String: [String: Any]] = [:]
    var ids: [String] = []
    for entry in view {
        guard let id = entry["id"] as? String, records[id] == nil else { return nil }
        records[id] = entry
        ids.append(id)
    }
    var touched = Set<String>()
    func touch(_ id: String) -> Bool { touched.insert(id).inserted }
    func list(_ key: String) -> [Any]? {
        guard let value = changes[key] else { return [] }
        guard let array = value as? [Any], array.count <= maxItems else { return nil }
        return array
    }

    guard let removed = list("r"), let added = list("a"), let updates = list("c") else { return nil }
    for value in removed {
        guard let id = value as? String, records[id] != nil, touch(id) else { return nil }
        records[id] = nil
    }
    for value in added {
        guard let record = value as? [String: Any], let id = record["id"] as? String, records[id] == nil, touch(id) else { return nil }
        records[id] = record
    }
    for change in updates {
        guard let parts = change as? [Any], parts.count == 2 || parts.count == 3, let id = parts[0] as? String,
              let fields = parts[1] as? [String: Any], fields["id"] == nil, var record = records[id], touch(id) else { return nil }
        var cleared: [String] = []
        if parts.count == 3 {
            guard let names = parts[2] as? [String], Set(names).count == names.count,
                  names.allSatisfy({ $0 != "id" && fields[$0] == nil }) else { return nil }
            cleared = names
        }
        for (key, value) in fields { record[key] = value }
        for key in cleared { record[key] = nil }
        records[id] = record
    }
    var order = ids
    if changes["o"] != nil {
        guard let explicit = list("o") as? [String] else { return nil }
        order = explicit
    }
    guard records.count <= maxItems, order.count == records.count, Set(order).count == order.count,
          order.allSatisfy({ records[$0] != nil }) else { return nil }
    return order.compactMap { records[$0] }
}
