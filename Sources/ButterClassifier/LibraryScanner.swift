import Foundation
import SwiftData

/// Scans watched folders for audio files and syncs them (plus any analysis
/// YAML data) into the SwiftData index.
@MainActor
enum LibraryScanner {
    static let audioExtensions: Set<String> = ["wav", "mp3"]

    static func scanAll(context: ModelContext) {
        let folders = (try? context.fetch(FetchDescriptor<WatchedFolder>())) ?? []
        let existing = (try? context.fetch(FetchDescriptor<SampleFile>())) ?? []
        var byPath = Dictionary(uniqueKeysWithValues: existing.map { ($0.path, $0) })
        var seen = Set<String>()
        let fm = FileManager.default

        for folder in folders {
            let base = folder.url
            guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) else { continue }
            for case let url as URL in enumerator {
                guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }

                let path = url.path
                seen.insert(path)
                let modified = values.contentModificationDate ?? .distantPast
                let size = Int64(values.fileSize ?? 0)

                let sample: SampleFile
                if let s = byPath[path] {
                    sample = s
                    if s.modifiedAt != modified {
                        s.modifiedAt = modified
                        s.fileSize = size
                    }
                } else {
                    sample = SampleFile(
                        path: path,
                        name: url.lastPathComponent,
                        folderPath: url.deletingLastPathComponent().path,
                        watchedFolderPath: folder.path,
                        modifiedAt: modified,
                        fileSize: size
                    )
                    context.insert(sample)
                    byPath[path] = sample
                }
                refreshAnalysis(for: sample)
            }
        }

        // Remove index entries for files that vanished (or whose folder was removed).
        let folderPaths = Set(folders.map(\.path))
        for (path, sample) in byPath {
            if !seen.contains(path) || !folderPaths.contains(sample.watchedFolderPath) {
                context.delete(sample)
            }
        }

        try? context.save()
    }

    /// Re-reads the sample's YAML sidecar if it changed since we last parsed it.
    static func refreshAnalysis(for sample: SampleFile) {
        let fm = FileManager.default
        let yamlPath = sample.path + ".yaml"

        guard fm.fileExists(atPath: yamlPath) else {
            if sample.isAnalyzed {
                sample.isAnalyzed = false
                sample.yamlModifiedAt = nil
            }
            return
        }

        let yamlModified = (try? fm.attributesOfItem(atPath: yamlPath)[.modificationDate] as? Date) ?? nil
        if sample.isAnalyzed, let cached = sample.yamlModifiedAt, cached == yamlModified {
            return
        }

        guard let result = AnalysisResult.load(from: sample.yamlURL) else { return }
        sample.isAnalyzed = true
        sample.yamlModifiedAt = yamlModified
        sample.duration = result.duration
        sample.bpm = result.bpm
        sample.loudnessLUFS = result.loudnessLUFS
        sample.kickiness = result.kickiness
        sample.swing8th = result.swing8th
        sample.swing16th = result.swing16th
        sample.pitchSalience = result.pitchSalience
        sample.sampleRate = result.sampleRate
        sample.onsetTimes = result.onsetTimes
    }
}
