import Foundation

struct ProcRecent: Codable, Identifiable, Hashable {
    let routineID: String
    let params: [String: Double]
    let usedAt: Date

    var id: String { "\(routineID)-\(usedAt.timeIntervalSince1970)" }
}

enum ProcRecentStore {
    private static let key = "procRecents"
    private static let limit = 8

    static func load() -> [ProcRecent] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let recents = try? JSONDecoder().decode([ProcRecent].self, from: data) else {
            return []
        }
        return recents
    }

    static func record(routineID: String, params: [String: Double]) {
        var recents = load().filter { $0.routineID != routineID }
        recents.insert(ProcRecent(routineID: routineID, params: params, usedAt: Date()), at: 0)
        if recents.count > limit {
            recents = Array(recents.prefix(limit))
        }
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
