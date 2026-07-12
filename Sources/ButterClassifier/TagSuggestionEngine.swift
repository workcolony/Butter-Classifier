import Foundation

/// Computes tag suggestions for display — sidecar is persistence, not the sole source of truth.
enum TagSuggestionEngine {
    @MainActor
    static func loadOrCompute(
        for sample: SampleFile,
        preset: TagZonePreset,
        userVocabulary: [String],
        preferSidecar: Bool = true
    ) async -> [TagSuggestionItem] {
        if preferSidecar {
            let stored = TagSidecar.loadSuggested(fromAudioPath: sample.path)
            if !stored.isEmpty { return stored }
        }

        var analysis: AnalysisResult?
        if sample.isAnalyzed {
            let yamlURL = sample.yamlURL
            analysis = await Task.detached(priority: .utility) {
                AnalysisResult.load(from: yamlURL, mode: .tagging)
            }.value
        }

        let computed = TagSuggester.suggest(
            for: sample,
            analysis: analysis,
            preset: preset,
            userVocabulary: userVocabulary,
            mode: .full
        )

        if !computed.isEmpty {
            persist(computed, for: sample)
        }
        return computed
    }

    @MainActor
    static func refresh(
        for sample: SampleFile,
        preset: TagZonePreset,
        userVocabulary: [String]
    ) async -> [TagSuggestionItem] {
        await LibraryScanner.refreshTagSuggestions(
            for: sample,
            preset: preset,
            userVocabulary: userVocabulary
        )
        let stored = TagSidecar.loadSuggested(fromAudioPath: sample.path)
        if !stored.isEmpty { return stored }
        return TagSuggester.suggest(
            for: sample,
            analysis: nil,
            preset: preset,
            userVocabulary: userVocabulary,
            mode: .metadataOnly
        )
    }

    @MainActor
    private static func persist(_ suggestions: [TagSuggestionItem], for sample: SampleFile) {
        let doc = TagSidecar.loadDocument(fromAudioPath: sample.path)
        let tags = doc.tags.isEmpty ? sample.tags : doc.tags
        try? TagSidecar.save(
            tags: tags,
            suggested: suggestions,
            audioPath: sample.path,
            markSuggestedSection: true
        )
    }
}
