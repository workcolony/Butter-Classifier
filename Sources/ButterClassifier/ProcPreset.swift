import Foundation

struct ProcPreset: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var steps: [ProcScriptStep]

    init(id: UUID = UUID(), name: String, steps: [ProcScriptStep]) {
        self.id = id
        self.name = name
        self.steps = steps
    }
}
