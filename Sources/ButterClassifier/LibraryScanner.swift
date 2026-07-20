import Foundation
import SwiftData

/// Scans watched folders for audio files and syncs them into the SwiftData index.
///
/// Library load is intentionally **index-only** (path / mtime / size / yaml-exists).
/// Sidecar parsing (analysis YAML, tags, edits) happens in a separate hydrate pass
/// so adding folders stays fast.
enum LibraryScanner {
    static let audioExtensions: Set<String> = ["wav", "mp3", "aif", "aiff"]
    private static let scanYieldInterval = 100
    private static let hydrateBatchSize = 64
    private static let hydrateSaveInterval = 128

    private struct DiscoveredFile: Sendable {
        var path: String
        var name: String
        var folderPath: String
        var watchedFolderPath: String
        var modifiedAt: Date
        var fileSize: Int64
    }

    /// Snapshot of cached sidecar mtimes for off-main hydrate I/O.
    private struct HydrateJob: Sendable {
        var path: String
        var isAnalyzed: Bool
        var yamlModifiedAt: Date?
        var tagsModifiedAt: Date?
        var editsModifiedAt: Date?
    }

    private struct AnalysisCache: Sendable {
        var yamlModified: Date?
        var duration: Double?
        var bpm: Double?
        var loudnessLUFS: Double?
        var kickiness: Double?
        var swing8th: Double?
        var swing16th: Double?
        var pitchSalience: Double?
        var sampleRate: Int?
        var libPitch: Double
        var libBright: Double
        var libEnergy: Double
        var libDurN: Double
        var glyphRadii: [Double]
        var glyphPitch: [Double]
    }

    private enum AnalysisUpdate: Sendable {
        case unchanged
        case missing
        case applied(AnalysisCache)
    }

    private enum TagsUpdate: Sendable {
        case unchanged
        case missing
        case applied(tags: [String], modified: Date?)
    }

    private enum EditsUpdate: Sendable {
        case unchanged
        case missing
        case applied(
            modified: Date,
            bpmOverride: Double?,
            keyOverride: String?,
            loopStart: Double?,
            loopEnd: Double?
        )
    }

    private struct HydrateUpdate: Sendable {
        var path: String
        var analysis: AnalysisUpdate
        var tags: TagsUpdate
        var edits: EditsUpdate
    }

    /// Fast folder → SampleFile sync. No YAML parsing, no tag suggestion writes.
    /// Returns paths that were inserted or whose audio mtime changed (need sidecar hydrate).
    @MainActor
    @discardableResult
    static func scanAll(
        context: ModelContext,
        tagPreset: TagZonePreset? = nil,
        userVocabulary: [String] = [],
        onProgress: ((Int, Int) -> Void)? = nil
    ) async -> [String] {
        _ = tagPreset
        _ = userVocabulary
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
        var dirtyPaths: [String] = []
        let fm = FileManager.default

        for file in discovered {
            seen.insert(file.path)

            if let existingSample = byPath[file.path], existingSample.modifiedAt == file.modifiedAt {
                // Unchanged — leave cached metrics alone; do not touch disk sidecars.
                processed += 1
                // Still yield so large "nothing changed" rescans don't freeze the UI.
                if processed.isMultiple(of: scanYieldInterval) {
                    onProgress?(processed, total)
                    await yieldToUI()
                }
                continue
            }

            let sample: SampleFile
            if let s = byPath[file.path] {
                sample = s
                sample.modifiedAt = file.modifiedAt
                sample.fileSize = file.fileSize
                // Audio changed — drop stale analysis cache so hydrate re-reads.
                sample.yamlModifiedAt = nil
                sample.tagsModifiedAt = nil
                sample.editsModifiedAt = nil
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

            // Cheap existence check only — no YAML parse, no sidecar reads/writes.
            let hasYAML = fm.fileExists(atPath: file.path + ".yaml")
            sample.isAnalyzed = hasYAML
            if !hasYAML {
                LibraryFeatures.applyDefaults(to: sample)
            }

            dirtyPaths.append(file.path)
            processed += 1
            onProgress?(processed, total)
            if dirtyPaths.count.isMultiple(of: scanYieldInterval) {
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
        return dirtyPaths
    }

    /// Parse analysis / tags / edits sidecars for the given samples (or all if nil).
    /// Skips sidecars whose cached mtimes are still valid.
    /// File I/O and YAML parsing run off the main actor in batches so the UI stays responsive.
    @MainActor
    static func hydrateSidecars(
        context: ModelContext,
        paths: [String]? = nil,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async {
        let samples: [SampleFile]
        if let paths, !paths.isEmpty {
            let wanted = Set(paths)
            let all = (try? context.fetch(FetchDescriptor<SampleFile>())) ?? []
            samples = all.filter { wanted.contains($0.path) }
        } else {
            samples = (try? context.fetch(FetchDescriptor<SampleFile>())) ?? []
        }
        let total = samples.count
        guard total > 0 else { return }
        onProgress?(0, total)

        let byPath = Dictionary(uniqueKeysWithValues: samples.map { ($0.path, $0) })
        let jobs = samples.map {
            HydrateJob(
                path: $0.path,
                isAnalyzed: $0.isAnalyzed,
                yamlModifiedAt: $0.yamlModifiedAt,
                tagsModifiedAt: $0.tagsModifiedAt,
                editsModifiedAt: $0.editsModifiedAt
            )
        }

        var processed = 0
        var sinceSave = 0
        var jobIndex = 0
        while jobIndex < jobs.count {
            let end = min(jobIndex + hydrateBatchSize, jobs.count)
            let batch = Array(jobs[jobIndex..<end])
            jobIndex = end

            let updates = await Task.detached(priority: .utility) {
                batch.map { loadHydrateUpdate(for: $0) }
            }.value

            for update in updates {
                guard let sample = byPath[update.path] else { continue }
                applyHydrateUpdate(update, to: sample)
            }

            processed = jobIndex
            sinceSave += batch.count
            onProgress?(processed, total)

            if sinceSave >= hydrateSaveInterval || processed == total {
                try? context.save()
                sinceSave = 0
                await yieldToUI()
            } else {
                await yieldToUI()
            }
        }

        try? context.save()
        onProgress?(total, total)
    }

    private static func loadHydrateUpdate(for job: HydrateJob) -> HydrateUpdate {
        HydrateUpdate(
            path: job.path,
            analysis: loadAnalysisUpdate(for: job),
            tags: loadTagsUpdate(for: job),
            edits: loadEditsUpdate(for: job)
        )
    }

    private static func loadAnalysisUpdate(for job: HydrateJob) -> AnalysisUpdate {
        let fm = FileManager.default
        let yamlPath = job.path + ".yaml"
        guard fm.fileExists(atPath: yamlPath) else { return .missing }

        let yamlModified = (try? fm.attributesOfItem(atPath: yamlPath)[.modificationDate] as? Date) ?? nil
        if job.isAnalyzed, let cached = job.yamlModifiedAt, cached == yamlModified {
            return .unchanged
        }

        guard let result = AnalysisResult.load(from: URL(fileURLWithPath: yamlPath), mode: .index) else {
            return .unchanged
        }

        let glyphs = LibraryFeatures.computeGlyphs(result)
        let dur = result.duration ?? 0
        return .applied(AnalysisCache(
            yamlModified: yamlModified,
            duration: result.duration,
            bpm: result.bpm,
            loudnessLUFS: result.loudnessLUFS,
            kickiness: result.kickiness,
            swing8th: result.swing8th,
            swing16th: result.swing16th,
            pitchSalience: result.pitchSalience,
            sampleRate: result.sampleRate,
            libPitch: LibraryFeatures.pitchScalar(result),
            libBright: LibraryFeatures.brightnessScalar(result),
            libEnergy: LibraryFeatures.energyScalar(result),
            libDurN: min(1, dur / 12),
            glyphRadii: glyphs.map(\.radius),
            glyphPitch: glyphs.map(\.pitch)
        ))
    }

    private static func loadTagsUpdate(for job: HydrateJob) -> TagsUpdate {
        let fm = FileManager.default
        let tagsPath = job.path + "_tags.yaml"
        guard fm.fileExists(atPath: tagsPath) else { return .missing }

        let modified = TagSidecar.modificationDate(forAudioPath: job.path)
        if let cached = job.tagsModifiedAt, cached == modified { return .unchanged }
        let doc = TagSidecar.loadDocument(fromAudioPath: job.path)
        return .applied(tags: doc.tags, modified: modified)
    }

    private static func loadEditsUpdate(for job: HydrateJob) -> EditsUpdate {
        guard let modified = EditSidecar.modificationDate(forAudioPath: job.path) else {
            return .missing
        }
        if let cached = job.editsModifiedAt, cached == modified { return .unchanged }
        let edits = EditSidecar.load(fromAudioPath: job.path)
        return .applied(
            modified: modified,
            bpmOverride: edits.bpmOverride,
            keyOverride: edits.keyOverride,
            loopStart: edits.loopStart,
            loopEnd: edits.loopEnd
        )
    }

    @MainActor
    private static func applyHydrateUpdate(_ update: HydrateUpdate, to sample: SampleFile) {
        switch update.analysis {
        case .unchanged:
            break
        case .missing:
            if sample.isAnalyzed {
                sample.isAnalyzed = false
                sample.yamlModifiedAt = nil
            }
            LibraryFeatures.applyDefaults(to: sample)
        case .applied(let cache):
            sample.isAnalyzed = true
            sample.yamlModifiedAt = cache.yamlModified
            sample.duration = cache.duration
            sample.bpm = cache.bpm
            sample.loudnessLUFS = cache.loudnessLUFS
            sample.kickiness = cache.kickiness
            sample.swing8th = cache.swing8th
            sample.swing16th = cache.swing16th
            sample.pitchSalience = cache.pitchSalience
            sample.sampleRate = cache.sampleRate
            if !sample.onsetTimes.isEmpty { sample.onsetTimes = [] }
            sample.libPitch = cache.libPitch
            sample.libBright = cache.libBright
            sample.libEnergy = cache.libEnergy
            sample.libDurN = cache.libDurN
            sample.glyphRadii = cache.glyphRadii
            sample.glyphPitch = cache.glyphPitch
        }

        switch update.tags {
        case .unchanged:
            break
        case .missing:
            if !sample.tags.isEmpty {
                sample.tags = []
                sample.tagsModifiedAt = nil
            }
            if !sample.suggestedTagNames.isEmpty {
                sample.setTagSuggestions([])
            }
        case .applied(let tags, let modified):
            sample.tags = tags
            if !sample.suggestedTagNames.isEmpty {
                sample.setTagSuggestions([])
            }
            sample.tagsModifiedAt = modified
        }

        switch update.edits {
        case .unchanged:
            break
        case .missing:
            guard sample.editsModifiedAt != nil else { break }
            sample.editsModifiedAt = nil
            sample.editBpmOverride = nil
            sample.editKeyOverride = nil
            sample.editLoopStart = nil
            sample.editLoopEnd = nil
            if !sample.editOnsetTimes.isEmpty { sample.editOnsetTimes = [] }
        case .applied(let modified, let bpm, let key, let loopStart, let loopEnd):
            sample.editsModifiedAt = modified
            sample.editBpmOverride = bpm
            sample.editKeyOverride = key
            sample.editLoopStart = loopStart
            sample.editLoopEnd = loopEnd
            if !sample.editOnsetTimes.isEmpty { sample.editOnsetTimes = [] }
        }
    }

    private static func discoverFiles(in folders: [(path: String, url: URL)]) -> [DiscoveredFile] {
        let fm = FileManager.default
        var out: [DiscoveredFile] = []
        out.reserveCapacity(4096)

        for folder in folders {
            guard let enumerator = fm.enumerator(
                at: folder.url,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                // Extension check before resourceValues to skip YAML/tag sidecars fast.
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

    /// Cheap filename/folder/comment suggestions — used by tag UI, not library scan.
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

    /// Recompute suggested tags from filename, comments, audio, and Tag Zones. Writes `suggested:` to the sidecar.
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

    private static func yieldToUI() async {
        await Task.yield()
    }
}
