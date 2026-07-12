import Foundation
import SwiftData

/// Lightweight row for the sample file table — avoids re-fetching heavy model fields while scrolling.
struct SampleFileRow: Identifiable, Hashable {
    var id: PersistentIdentifier
    var path: String
    var name: String
    var isAnalyzed: Bool
    var hasClassificationEdits: Bool
    var durationSort: Double
    var bpmSort: Double
    var loudnessSort: Double
    var kickinessSort: Double
    var hasBpmOverride: Bool
    var folderName: String
    /// First few tags, pre-joined for display — avoids loading tag arrays during table scroll.
    var tagsPreview: String

    init(_ sample: SampleFile) {
        id = sample.persistentModelID
        path = sample.path
        name = sample.name
        isAnalyzed = sample.isAnalyzed
        hasClassificationEdits = sample.hasClassificationEdits
        durationSort = sample.durationSort
        bpmSort = sample.bpmSort
        loudnessSort = sample.loudnessSort
        kickinessSort = sample.kickinessSort
        hasBpmOverride = sample.editBpmOverride != nil
        folderName = (sample.folderPath as NSString).lastPathComponent
        tagsPreview = Self.makeTagsPreview(from: sample.tags)
    }

    private static func makeTagsPreview(from tags: [String]) -> String {
        guard !tags.isEmpty else { return "" }
        let shown = tags.prefix(3)
        var preview = shown.joined(separator: " · ")
        if tags.count > shown.count {
            preview += " …"
        }
        return preview
    }
}

/// Builds and caches table rows separately from SwiftUI body updates.
enum SampleFileListCache {
    static func rows(
        from samples: [SampleFile],
        folderPath: String?,
        searchText: String,
        sortOrder: [KeyPathComparator<SampleFileRow>]
    ) -> [SampleFileRow] {
        var result = samples
        if let folderPath {
            result = result.filter { $0.watchedFolderPath == folderPath }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        var rows = result.map(SampleFileRow.init)
        rows.sort(using: sortOrder)
        return rows
    }

    static func lookup(from samples: [SampleFile]) -> [PersistentIdentifier: SampleFile] {
        Dictionary(uniqueKeysWithValues: samples.map { ($0.persistentModelID, $0) })
    }
}
