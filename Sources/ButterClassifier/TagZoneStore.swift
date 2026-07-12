import Foundation

/// Persists global Tag Zone presets (LUP `/api/tagzone-presets` equivalent).
@MainActor
final class TagZoneStore: ObservableObject {
    @Published private(set) var presets: [TagZonePreset] = []
    @Published var selectedIndex: Int = 0

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ButterClassifier", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("tagzone-presets.json")
        load()
    }

    var selected: TagZonePreset {
        get {
            guard !presets.isEmpty else { return TagZonePreset(name: "everything") }
            return presets[min(max(0, selectedIndex), presets.count - 1)]
        }
        set {
            guard !presets.isEmpty else { return }
            presets[min(max(0, selectedIndex), presets.count - 1)] = newValue
            scheduleSave()
        }
    }

    func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([TagZonePreset].self, from: data),
           !decoded.isEmpty {
            presets = decoded
            selectedIndex = 0
            return
        }
        if let bundled = Self.loadBundledDefault() {
            presets = [bundled]
        } else {
            presets = [TagZonePreset(name: "everything")]
        }
        selectedIndex = 0
        scheduleSave()
    }

    func updateSelected(_ mutate: (inout TagZonePreset) -> Void) {
        guard !presets.isEmpty else { return }
        var p = selected
        mutate(&p)
        presets[selectedIndex] = p
        scheduleSave()
    }

    func selectPreset(at index: Int) {
        guard index >= 0, index < presets.count else { return }
        selectedIndex = index
    }

    func addPreset(cloning index: Int? = nil) {
        let base = index.map { presets[$0] } ?? presets.first ?? TagZonePreset(name: "everything")
        var copy = base
        copy.id = UUID()
        copy.name = uniqueName(base.name == "everything" ? "preset" : "\(base.name) copy")
        copy.zones = base.zones.map { z in
            var z = z
            z.id = UUID()
            return z
        }
        presets.append(copy)
        selectedIndex = presets.count - 1
        scheduleSave()
    }

    func renameSelected(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "everything" || selectedIndex == 0 else { return }
        updateSelected { $0.name = uniqueName(trimmed, excluding: selectedIndex) }
    }

    func deleteSelected() {
        guard presets.count > 1, presets[selectedIndex].name != "everything" else { return }
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

    private static func loadBundledDefault() -> TagZonePreset? {
        guard let url = Bundle.main.url(forResource: "default-tagzone-preset", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let preset = try? JSONDecoder().decode(TagZonePreset.self, from: data) else {
            return nil
        }
        return preset
    }
}
