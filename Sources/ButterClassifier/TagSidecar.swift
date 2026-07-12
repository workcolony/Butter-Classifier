import Foundation
import Yams

/// Read/write `sample.wav_tags.yaml` sidecars (LUP / gold_snds format).
enum TagSidecar {
    static func url(forAudioPath path: String) -> URL {
        URL(fileURLWithPath: path + "_tags.yaml")
    }

    struct Document {
        var tags: [String]
        /// `nil` when the sidecar has no `suggested:` section yet.
        var suggested: [TagSuggestionItem]?
    }

    static func load(fromAudioPath path: String) -> [String] {
        loadDocument(fromAudioPath: path).tags
    }

    static func loadSuggested(fromAudioPath path: String) -> [TagSuggestionItem] {
        loadDocument(fromAudioPath: path).suggested ?? []
    }

    static func loadDocument(fromAudioPath path: String) -> Document {
        let url = url(forAudioPath: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let root = try? Yams.load(yaml: text) as? [String: Any] else {
            return Document(tags: [], suggested: nil)
        }

        let tags = (root["tags"] as? [Any])?
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []

        var suggested: [TagSuggestionItem]?
        if root.keys.contains("suggested") {
            suggested = []
            if let rows = root["suggested"] as? [Any] {
                for row in rows {
                    let dict: [String: Any]?
                    if let d = row as? [String: Any] {
                        dict = d
                    } else if let d = row as? NSDictionary {
                        dict = d as? [String: Any]
                    } else {
                        dict = nil
                    }
                    guard let dict,
                          let tag = dict["tag"] as? String else { continue }
                    let trimmed = tag.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    let confidence = YAMLValues.double(dict["confidence"]) ?? 0
                    let source = (dict["source"] as? String) ?? "auto"
                    suggested?.append(TagSuggestionItem(tag: trimmed, confidence: confidence, source: source))
                }
            }
        }

        return Document(tags: tags, suggested: suggested)
    }

    static func save(_ tags: [String], audioPath path: String) throws {
        let doc = loadDocument(fromAudioPath: path)
        try save(tags: tags, suggested: doc.suggested ?? [], audioPath: path)
    }

    static func saveSuggested(_ suggested: [TagSuggestionItem], audioPath path: String) throws {
        let doc = loadDocument(fromAudioPath: path)
        try save(tags: doc.tags, suggested: suggested, audioPath: path)
    }

    static func save(tags: [String], suggested: [TagSuggestionItem], audioPath path: String, markSuggestedSection: Bool = false) throws {
        let cleanedTags = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var lines = ["tags:"]
        if cleanedTags.isEmpty {
            lines = ["tags: []"]
        } else {
            for tag in cleanedTags {
                lines.append("- \(tag)")
            }
        }

        if markSuggestedSection || !suggested.isEmpty || hadSuggestedSection(at: path) {
            lines.append("suggested:")
            if suggested.isEmpty {
                lines.append("  []")
            } else {
                for item in suggested {
                    lines.append("  - tag: \(yamlScalar(item.tag))")
                    lines.append("    confidence: \(String(format: "%.2f", item.confidence))")
                    lines.append("    source: \(yamlScalar(item.source))")
                }
            }
        }

        let body = lines.joined(separator: "\n") + "\n"
        try body.write(to: url(forAudioPath: path), atomically: true, encoding: .utf8)
    }

    static func modificationDate(forAudioPath path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url(forAudioPath: path).path)[.modificationDate] as? Date
    }

    private static func hadSuggestedSection(at path: String) -> Bool {
        loadDocument(fromAudioPath: path).suggested != nil
    }

    private static func yamlScalar(_ value: String) -> String {
        if value.range(of: #"[:#\[\]{}+]"#, options: .regularExpression) != nil {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return value
    }
}
