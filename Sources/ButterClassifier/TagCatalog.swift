import Foundation

/// Shared tag vocabulary and parsing (LUP-style comma tags + preset grid).
enum TagCatalog {
    /// Splits comma- or newline-separated tag input into trimmed unique tokens.
    static func parseTags(from text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let parts = text.split { $0 == "," || $0 == "\n" || $0 == ";" }
        for part in parts {
            let tag = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag).inserted else { continue }
            result.append(tag)
        }
        return result
    }

    /// Preset vocabulary first, then user-registered tags, then tags seen in the library.
    static func knownTags(
        preset: TagZonePreset,
        userVocabulary: [String],
        libraryTags: Set<String>
    ) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        let zoneOrdered = preset.zones
            .sorted { $0.y > $1.y }
            .flatMap(\.tags)
        for tag in zoneOrdered where seen.insert(tag.lowercased()).inserted {
            ordered.append(tag)
        }

        for tag in userVocabulary where seen.insert(tag.lowercased()).inserted {
            ordered.append(tag)
        }

        let extras = libraryTags
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        ordered.append(contentsOf: extras)
        return ordered
    }

    static func counts(in samples: [SampleFile]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: LibraryCatalog.tagCounts(in: samples))
    }

    static func libraryTagSet(in samples: [SampleFile]) -> Set<String> {
        Set(samples.flatMap(\.tags))
    }

    static func hasExactMatch(_ query: String, in vocabulary: [String]) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }
        return vocabulary.contains { $0.lowercased() == q }
    }

    static func canonicalMatch(_ query: String, in vocabulary: [String]) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        return vocabulary.first { $0.lowercased() == q }
    }
}
