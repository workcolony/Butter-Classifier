import Foundation
import SwiftData

/// Scans watched folders for audio files and syncs them (plus any analysis
/// YAML data) into the SwiftData index.
enum LibraryScanner {
    static let audioExtensions: Set<String> = ["wav", "mp3", "aif", "aiff"]
    private static let scanYieldInterval = 25

    private struct DiscoveredFile: Sendable {
        var path: String
        var name: String
        var folderPath: String
        var watchedFolderPath: String
        var modifiedAt: Date
        var fileSize: Int64
    }

    @MainActor
    static func scanAll(
        context: ModelContext,
        tagPreset: TagZonePreset? = nil,
        userVocabulary: [String] = [],
        onProgress: ((Int, Int) -> Void)? = nil
    ) async {
        let preset = tagPreset ?? TagZonePreset(name: "everything")
        let folders = (try? context.fetch(FetchDescriptor<WatchedFolder>())) ?? []
        let existing = (try? context.fetch(FetchDescriptor<SampleFile>())) ?? []
        var byPath = Dictionary(uniqueKeysWithValues: existing.map { ($0.path, $0) })
        let folderPaths = folders.map { (path: $0.path, url: $0.url) }

        let discovered = await Task.detached(priority: .utility) {
            discoverFiles(in: folderPaths)
        }.value

        let total = discovered.count
        onProgress?(0, total)

        var seen = Set<String>()
        var processed = 0

        for file in discovered {
            seen.insert(file.path)

            if let existingSample = byPath[file.path], existingSample.modifiedAt == file.modifiedAt {
                purgeHeavyCachedFields(existingSample)
                if needsMetadataSuggestions(for: existingSample) {
                    refreshMetadataSuggestions(
                        for: existingSample,
                        preset: preset,
                        userVocabulary: userVocabulary
                    )
                }
                processed += 1
                onProgress?(processed, total)
                if processed.isMultiple(of: scanYieldInterval) {
                    await yieldToUI()
                }
                continue
            }

            let sample: SampleFile
            if let s = byPath[file.path] {
                sample = s
                sample.modifiedAt = file.modifiedAt
                sample.fileSize = file.fileSize
            } else {
                sample = SampleFile(
                    path: file.path,
                    name: file.name,
                    folderPath: file.folderPath,
                    watchedFolderPath: file.watchedFolderPath,
                    modifiedAt: file.modifiedAt,
                    fileSize: file.fileSize
                )
                context.insert(sample)
                byPath[file.path] = sample
            }

            await refreshAnalysis(for: sample)
            refreshTags(for: sample)
            refreshEdits(for: sample)
            refreshMetadataSuggestions(for: sample, preset: preset, userVocabulary: userVocabulary)

            processed += 1
            onProgress?(processed, total)
            if processed.isMultiple(of: scanYieldInterval) {
                try? context.save()
                await yieldToUI()
            }
        }

        onProgress?(total, total)

        let watchedPaths = Set(folders.map(\.path))
        for (path, sample) in byPath {
            if !seen.contains(path) || !watchedPaths.contains(sample.watchedFolderPath) {
                context.delete(sample)
            }
        }

        try? context.save()
    }

    private static func discoverFiles(in folders: [(path: String, url: URL)]) -> [DiscoveredFile] {
        let fm = FileManager.default
        var out: [DiscoveredFile] = []
        out.reserveCapacity(4096)

        for folder in folders {
            guard let enumerator = fm.enumerator(
                at: folder.url,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            ) else { continue }

            for case let url as URL in enumerator {
                guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                guard let values = try? url.resourceValues(forKeys: [
                    .contentModificationDateKey, .fileSizeKey, .isRegularFileKey
                ]), values.isRegularFile == true else { continue }

                out.append(DiscoveredFile(
                    path: url.path,
                    name: url.lastPathComponent,
                    folderPath: url.deletingLastPathComponent().path,
                    watchedFolderPath: folder.path,
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    fileSize: Int64(values.fileSize ?? 0)
                ))
            }
        }
        return out
    }

    /// Re-reads the sample's YAML sidecar if it changed since we last parsed it.
    @MainActor
    @discardableResult
    static func refreshAnalysis(for sample: SampleFile) async -> Bool {
        let fm = FileManager.default
        let yamlPath = sample.path + ".yaml"

        guard fm.fileExists(atPath: yamlPath) else {
            if sample.isAnalyzed {
                sample.isAnalyzed = false
                sample.yamlModifiedAt = nil
            }
            LibraryFeatures.applyDefaults(to: sample)
            return false
        }

        let yamlModified = (try? fm.attributesOfItem(atPath: yamlPath)[.modificationDate] as? Date) ?? nil
        if sample.isAnalyzed, let cached = sample.yamlModifiedAt, cached == yamlModified {
            return false
        }

        let yamlURL = sample.yamlURL
        let result = await Task.detached(priority: .utility) {
            AnalysisResult.load(from: yamlURL, mode: .index)
        }.value

        guard let result else { return false }
        applyAnalysisResult(result, yamlModified: yamlModified, to: sample)
        return true
    }

    @MainActor
    static func refreshAnalysisSync(for sample: SampleFile) -> Bool {
        let fm = FileManager.default
        let yamlPath = sample.path + ".yaml"

        guard fm.fileExists(atPath: yamlPath) else {
            if sample.isAnalyzed {
                sample.isAnalyzed = false
                sample.yamlModifiedAt = nil
            }
            LibraryFeatures.applyDefaults(to: sample)
            return false
        }

        let yamlModified = (try? fm.attributesOfItem(atPath: yamlPath)[.modificationDate] as? Date) ?? nil
        if sample.isAnalyzed, let cached = sample.yamlModifiedAt, cached == yamlModified {
            return false
        }

        guard let result = AnalysisResult.load(from: sample.yamlURL, mode: .index) else { return false }
        applyAnalysisResult(result, yamlModified: yamlModified, to: sample)
        return true
    }

    @MainActor
    private static func applyAnalysisResult(_ result: AnalysisResult, yamlModified: Date?, to sample: SampleFile) {
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
        if !sample.onsetTimes.isEmpty { sample.onsetTimes = [] }
        LibraryFeatures.apply(to: sample, from: result)
    }

    @MainActor
    static func refreshTags(for sample: SampleFile) {
        let fm = FileManager.default
        let tagsPath = sample.path + "_tags.yaml"
        guard fm.fileExists(atPath: tagsPath) else {
            if !sample.tags.isEmpty {
                sample.tags = []
                sample.tagsModifiedAt = nil
            }
            if !sample.suggestedTagNames.isEmpty {
                sample.setTagSuggestions([])
            }
            return
        }
        let modified = TagSidecar.modificationDate(forAudioPath: sample.path)
        if let cached = sample.tagsModifiedAt, cached == modified { return }
        let doc = TagSidecar.loadDocument(fromAudioPath: sample.path)
        sample.tags = doc.tags
        if !sample.suggestedTagNames.isEmpty {
            sample.setTagSuggestions([])
        }
        sample.tagsModifiedAt = modified
    }

    /// Cheap filename/folder suggestions during scan — preserves audio/zone suggestions already stored.
    @MainActor
    static func refreshMetadataSuggestions(
        for sample: SampleFile,
        preset: TagZonePreset,
        userVocabulary: [String]
    ) {
        let incoming = TagSuggester.suggest(
            for: sample,
            analysis: nil,
            preset: preset,
            userVocabulary: userVocabulary,
            mode: .metadataOnly
        )
        guard !incoming.isEmpty else { return }

        let doc = TagSidecar.loadDocument(fromAudioPath: sample.path)
        let kept = (doc.suggested ?? []).filter { !TagSuggester.isMetadataSource($0.source) }
        let merged = TagSuggester.mergeStoredSuggestions(
            kept: kept,
            incoming: incoming,
            existingTags: doc.tags.isEmpty ? sample.tags : doc.tags,
            preset: preset,
            userVocabulary: userVocabulary
        )
        let tags = doc.tags.isEmpty ? sample.tags : doc.tags
        try? TagSidecar.save(
            tags: tags,
            suggested: merged,
            audioPath: sample.path,
            markSuggestedSection: true
        )
        sample.tagsModifiedAt = TagSidecar.modificationDate(forAudioPath: sample.path)
    }

    private static func needsMetadataSuggestions(for sample: SampleFile) -> Bool {
        TagSidecar.loadSuggested(fromAudioPath: sample.path).isEmpty
    }

    /// Recompute suggested tags from filename, audio, and Tag Zones. Writes `suggested:` to the sidecar.
    @MainActor
    static func refreshTagSuggestions(
        for sample: SampleFile,
        preset: TagZonePreset,
        userVocabulary: [String] = [],
        analysis: AnalysisResult? = nil
    ) async {
        let resolvedAnalysis: AnalysisResult?
        if let analysis {
            resolvedAnalysis = analysis
        } else if sample.isAnalyzed {
            let yamlURL = sample.yamlURL
            resolvedAnalysis = await Task.detached(priority: .utility) {
                AnalysisResult.load(from: yamlURL, mode: .tagging)
            }.value
        } else {
            resolvedAnalysis = nil
        }

        let incoming = TagSuggester.suggest(
            for: sample,
            analysis: resolvedAnalysis,
            preset: preset,
            userVocabulary: userVocabulary,
            mode: .full
        )
        let doc = TagSidecar.loadDocument(fromAudioPath: sample.path)
        let tags = doc.tags.isEmpty ? sample.tags : doc.tags
        let suggestions: [TagSuggestionItem]
        if incoming.isEmpty {
            suggestions = doc.suggested ?? []
        } else {
            suggestions = incoming
        }
        try? TagSidecar.save(
            tags: tags,
            suggested: suggestions,
            audioPath: sample.path,
            markSuggestedSection: true
        )
        sample.tagsModifiedAt = TagSidecar.modificationDate(forAudioPath: sample.path)
    }

    @MainActor
    @discardableResult
    static func refreshEdits(for sample: SampleFile) -> Bool {
        let modified = EditSidecar.modificationDate(forAudioPath: sample.path)
        guard let modified else {
            guard sample.editsModifiedAt != nil else { return false }
            sample.editsModifiedAt = nil
            sample.editBpmOverride = nil
            sample.editKeyOverride = nil
            sample.editLoopStart = nil
            sample.editLoopEnd = nil
            if !sample.editOnsetTimes.isEmpty { sample.editOnsetTimes = [] }
            return true
        }
        if let cached = sample.editsModifiedAt, cached == modified { return false }
        let edits = EditSidecar.load(fromAudioPath: sample.path)
        sample.editsModifiedAt = modified
        sample.editBpmOverride = edits.bpmOverride
        sample.editKeyOverride = edits.keyOverride
        sample.editLoopStart = edits.loopStart
        sample.editLoopEnd = edits.loopEnd
        if !sample.editOnsetTimes.isEmpty { sample.editOnsetTimes = [] }
        return true
    }

    @MainActor
    static func saveTags(_ tags: [String], for sample: SampleFile) throws {
        let doc = TagSidecar.loadDocument(fromAudioPath: sample.path)
        try TagSidecar.save(tags: tags, suggested: doc.suggested ?? [], audioPath: sample.path)
        sample.tags = tags
        sample.tagsModifiedAt = TagSidecar.modificationDate(forAudioPath: sample.path)
    }

    @MainActor
    static func applySuggestion(_ tag: String, for sample: SampleFile) throws {
        var tags = sample.tags
        if !tags.contains(tag) {
            tags.append(tag)
        }
        let doc = TagSidecar.loadDocument(fromAudioPath: sample.path)
        let remaining = (doc.suggested ?? []).filter { $0.tag != tag }
        try TagSidecar.save(tags: tags, suggested: remaining, audioPath: sample.path)
        sample.tags = tags
        sample.tagsModifiedAt = TagSidecar.modificationDate(forAudioPath: sample.path)
    }

    @MainActor
    static func applyAllSuggestions(for sample: SampleFile) throws {
        let doc = TagSidecar.loadDocument(fromAudioPath: sample.path)
        let toAdd = (doc.suggested ?? []).map(\.tag)
        guard !toAdd.isEmpty else { return }
        var tags = sample.tags
        for tag in toAdd where !tags.contains(tag) {
            tags.append(tag)
        }
        try TagSidecar.save(tags: tags, suggested: [], audioPath: sample.path)
        sample.tags = tags
        sample.tagsModifiedAt = TagSidecar.modificationDate(forAudioPath: sample.path)
    }

    @MainActor
    static func dismissSuggestion(_ tag: String, for sample: SampleFile) throws {
        let doc = TagSidecar.loadDocument(fromAudioPath: sample.path)
        let remaining = (doc.suggested ?? []).filter { $0.tag != tag }
        try TagSidecar.save(tags: sample.tags, suggested: remaining, audioPath: sample.path)
        sample.tagsModifiedAt = TagSidecar.modificationDate(forAudioPath: sample.path)
    }

    @MainActor
    static func addTags(_ newTags: [String], to samples: [SampleFile]) throws {
        let incoming = newTags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !incoming.isEmpty, !samples.isEmpty else { return }
        for sample in samples {
            var merged = sample.tags
            for tag in incoming where !merged.contains(tag) {
                merged.append(tag)
            }
            try saveTags(merged, for: sample)
        }
    }

    @MainActor
    static func removeTag(_ tag: String, from samples: [SampleFile]) throws {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        for sample in samples where sample.tags.contains(trimmed) {
            try saveTags(sample.tags.filter { $0 != trimmed }, for: sample)
        }
    }

    private static func purgeHeavyCachedFields(_ sample: SampleFile) {
        if !sample.onsetTimes.isEmpty { sample.onsetTimes = [] }
        if !sample.suggestedTagNames.isEmpty { sample.setTagSuggestions([]) }
        if !sample.editOnsetTimes.isEmpty { sample.editOnsetTimes = [] }
    }

    private static func yieldToUI() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}
