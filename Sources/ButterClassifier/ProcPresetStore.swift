import Foundation

@MainActor
final class ProcPresetStore: ObservableObject {
    @Published var presets: [ProcPreset] = []
    @Published var selectedIndex: Int = 0

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ButterClassifier", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("proc-presets.json")
        load()
    }

    var selected: ProcPreset? {
        guard !presets.isEmpty else { return nil }
        return presets[min(max(0, selectedIndex), presets.count - 1)]
    }

    func preset(id: UUID) -> ProcPreset? {
        presets.first { $0.id == id }
    }

    func index(of id: UUID) -> Int? {
        presets.firstIndex { $0.id == id }
    }

    func load() {
        let bundled = Self.loadBundledDefault() ?? []
        let loaded: [ProcPreset] = {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let decoded = try? JSONDecoder().decode([ProcPreset].self, from: data) else {
                return []
            }
            return decoded
        }()

        presets = Self.mergePresets(loaded: loaded, bundled: bundled)
        selectedIndex = 0
        scheduleSave()
    }

    /// Bundled presets win on id/name conflicts; duplicate ids are reassigned.
    private static func mergePresets(loaded: [ProcPreset], bundled: [ProcPreset]) -> [ProcPreset] {
        guard !bundled.isEmpty else {
            return dedupeIDs(loaded)
        }

        var bundledByID = Dictionary(uniqueKeysWithValues: bundled.map { ($0.id, $0) })
        var bundledNames = Set(bundled.map(\.name))
        var usedIDs = Set(bundled.map(\.id))
        var merged = bundled

        for var preset in loaded {
            if bundledByID[preset.id] != nil { continue }
            if bundledNames.contains(preset.name) { continue }

            if usedIDs.contains(preset.id) {
                preset.id = UUID()
            }
            usedIDs.insert(preset.id)
            merged.append(preset)
        }

        return dedupeIDs(merged)
    }

    private static func dedupeIDs(_ presets: [ProcPreset]) -> [ProcPreset] {
        var used = Set<UUID>()
        return presets.map { preset in
            var copy = preset
            if used.contains(copy.id) {
                copy.id = UUID()
            }
            used.insert(copy.id)
            return copy
        }
    }

    func selectPreset(at index: Int) {
        guard index >= 0, index < presets.count else { return }
        selectedIndex = index
    }

    func selectPreset(id: UUID) {
        guard let index = index(of: id) else { return }
        selectedIndex = index
    }

    func addPreset(cloning index: Int? = nil) {
        let base = index.map { presets[$0] } ?? selected ?? ProcPreset(name: "Chain", steps: [])
        var copy = base
        copy.id = UUID()
        copy.name = uniqueName("\(base.name) copy")
        presets.append(copy)
        selectedIndex = presets.count - 1
        scheduleSave()
    }

    func updateSelectedScript(_ text: String) throws {
        let steps = try ProcScriptParser.parse(text)
        guard !presets.isEmpty else { return }
        presets[selectedIndex].steps = steps
        scheduleSave()
    }

    func renameSelected(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !presets.isEmpty else { return }
        presets[selectedIndex].name = uniqueName(trimmed, excluding: selectedIndex)
        scheduleSave()
    }

    func deleteSelected() {
        guard presets.count > 1 else { return }
        presets.remove(at: selectedIndex)
        selectedIndex = min(selectedIndex, presets.count - 1)
        scheduleSave()
    }

    private func uniqueName(_ base: String, excluding: Int? = nil) -> String {
        var name = base
        var n = 2
        while presets.enumerated().contains(where: { $0.offset != excluding && $0.element.name == name }) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = presets
        let url = fileURL
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func loadBundledDefault() -> [ProcPreset]? {
        guard let url = Bundle.main.url(forResource: "default-proc-presets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let presets = try? JSONDecoder().decode([ProcPreset].self, from: data) else {
            return nil
        }
        return presets
    }
}
