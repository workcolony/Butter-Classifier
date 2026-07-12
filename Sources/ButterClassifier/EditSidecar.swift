import Foundation
import Yams

/// User classification overrides in `sample.wav_edits.yaml` (Phase 4).
struct SampleEdits: Equatable {
    var onsetTimes: [Double]?
    var loopStart: Double?
    var loopEnd: Double?
    var bpmOverride: Double?
    var keyOverride: String?

    static let empty = SampleEdits()

    var hasLoop: Bool {
        guard let start = loopStart, let end = loopEnd else { return false }
        return end > start
    }

    var loopRange: ClosedRange<Double>? {
        guard let start = loopStart, let end = loopEnd, end > start else { return nil }
        return start...end
    }

    func effectiveOnsets(fallback analyzed: [Double]) -> [Double] {
        onsetTimes ?? analyzed
    }
}

enum EditSidecar {
    static func url(forAudioPath path: String) -> URL {
        URL(fileURLWithPath: path + "_edits.yaml")
    }

    static func load(fromAudioPath path: String) -> SampleEdits {
        let fileURL = url(forAudioPath: path)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              let root = try? Yams.load(yaml: text) as? [String: Any] else {
            return .empty
        }

        func num(_ key: String) -> Double? {
            YAMLValues.double(root[key])
        }
        func numArray(_ value: Any?) -> [Double] {
            YAMLValues.doubleArray(value)
        }

        var edits = SampleEdits()
        let onsets = numArray(root["onset_times"]).sorted()
        if !onsets.isEmpty { edits.onsetTimes = onsets }
        edits.loopStart = num("loop_start")
        edits.loopEnd = num("loop_end")
        edits.bpmOverride = num("bpm_override")
        edits.keyOverride = root["key"] as? String
        return edits
    }

    static func save(_ edits: SampleEdits, audioPath path: String) throws {
        var lines: [String] = []
        if let onsets = edits.onsetTimes, !onsets.isEmpty {
            lines.append("onset_times:")
            for t in onsets.sorted() {
                lines.append("- \(format(t))")
            }
        }
        if let start = edits.loopStart { lines.append("loop_start: \(format(start))") }
        if let end = edits.loopEnd { lines.append("loop_end: \(format(end))") }
        if let bpm = edits.bpmOverride { lines.append("bpm_override: \(format(bpm))") }
        if let key = edits.keyOverride?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
            lines.append("key: \(key)")
        }
        if lines.isEmpty {
            try? FileManager.default.removeItem(at: url(forAudioPath: path))
            return
        }
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(to: url(forAudioPath: path), atomically: true, encoding: .utf8)
    }

    static func modificationDate(forAudioPath path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url(forAudioPath: path).path)[.modificationDate] as? Date
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6g", value)
    }
}
