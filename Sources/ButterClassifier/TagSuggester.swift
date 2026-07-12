import Foundation

/// One auto-generated tag suggestion (stored separately from confirmed user tags).
struct TagSuggestionItem: Codable, Hashable, Identifiable {
    var tag: String
    var confidence: Double
    var source: String

    var id: String { tag }
}

/// Suggests descriptive tags (instrument, family, feeling, energy) from filenames,
/// audio analysis, and Tag Zone scalars. Never suggests tempo, key, or pack names.
enum TagSuggester {
    enum SuggestMode {
        /// Filename + folder tokens only — cheap enough to run during library scan.
        case metadataOnly
        /// Filename, folder, audio heuristics, and Tag Zone axes.
        case full
    }

    private struct TokenRules: Decodable {
        var tokens: [String: [String]]
        var folderTokens: [String: [String]]?
        var excludedFolderTokens: [String]?
    }

    private struct ScoredTag {
        var tag: String
        var confidence: Double
        var sources: Set<String>

        var sourceLabel: String {
            sources.sorted().joined(separator: "+")
        }
    }

    static let minConfidence = 0.55
    static let maxSuggestions = 6
    static let autoApplyConfidence = 0.88
    private static let agreementBoost = 0.08
    private static let maxBoostedConfidence = 0.98

    private static let keyPattern = try! NSRegularExpression(
        pattern: #"^(?:[A-G](?:#|b)?(?:m|min|maj|major|minor)?|[A-G](?:#|b)?(?:m|min)?|[A-G])$"#,
        options: [.caseInsensitive]
    )
    private static let camelCasePattern = try! NSRegularExpression(
        pattern: #"([a-z])([A-Z])"#
    )
    private static let letterDigitPattern = try! NSRegularExpression(
        pattern: #"([a-zA-Z])(\d)"#
    )
    private static let digitLetterPattern = try! NSRegularExpression(
        pattern: #"(\d)([a-zA-Z])"#
    )

    private static let drumNumberTokens = Set(["808", "909", "606", "707", "303"])
    private static var cachedTokenRules: TokenRules?

    // MARK: - Public

    static func suggest(
        for sample: SampleFile,
        analysis: AnalysisResult?,
        preset: TagZonePreset,
        userVocabulary: [String] = [],
        mode: SuggestMode = .full
    ) -> [TagSuggestionItem] {
        let vocabulary = buildVocabulary(preset: preset, userVocabulary: userVocabulary)
        var scored: [String: ScoredTag] = [:]

        merge(&scored, fromFilename(sample: sample, vocabulary: vocabulary))
        merge(&scored, fromFolders(sample: sample, vocabulary: vocabulary))

        if mode == .full {
            if let analysis {
                merge(&scored, fromAudio(sample: sample, analysis: analysis, vocabulary: vocabulary))
            }
            if sample.libPitch != nil {
                merge(&scored, fromTagZones(sample: sample, preset: preset, vocabulary: vocabulary))
            }
        }

        let existing = Set(sample.tags.map { $0.lowercased() })
        return finalizeScored(scored, excludingLowercased: existing)
    }

    /// Tags safe to auto-apply without user review (high-confidence filename matches).
    static func autoApplyCandidates(from suggestions: [TagSuggestionItem]) -> [String] {
        suggestions
            .filter { item in
                item.confidence >= autoApplyConfidence
                    && item.source.split(separator: "+").contains(where: { $0 == "filename" })
            }
            .map(\.tag)
    }

    static func isMetadataSource(_ source: String) -> Bool {
        let parts = source.split(separator: "+").map(String.init)
        return !parts.isEmpty && parts.allSatisfy { $0 == "filename" || $0 == "folder" }
    }

    static func mergeStoredSuggestions(
        kept: [TagSuggestionItem],
        incoming: [TagSuggestionItem],
        existingTags: [String],
        preset: TagZonePreset,
        userVocabulary: [String] = []
    ) -> [TagSuggestionItem] {
        let vocabulary = buildVocabulary(preset: preset, userVocabulary: userVocabulary)
        var byTag: [String: TagSuggestionItem] = [:]
        for item in kept + incoming {
            if let existing = byTag[item.tag] {
                if item.confidence > existing.confidence {
                    byTag[item.tag] = item
                }
            } else {
                byTag[item.tag] = item
            }
        }
        let existing = Set(existingTags.compactMap { canonicalTag($0, vocabulary: vocabulary) })
        return byTag.values
            .filter { $0.confidence >= minConfidence && !existing.contains($0.tag) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxSuggestions)
            .map { $0 }
    }

    // MARK: - Filename tokens

    private static func fromFilename(sample: SampleFile, vocabulary: [String: String]) -> [ScoredTag] {
        let stem = (sample.name as NSString).deletingPathExtension
        let tokens = tokenize(stem)
        var out: [ScoredTag] = []
        let rules = loadTokenRules().tokens

        for token in tokens {
            guard !isExcludedToken(token) else { continue }
            if let tag = matchToken(token, rules: rules, vocabulary: vocabulary) {
                out.append(ScoredTag(tag: tag, confidence: 0.90, sources: ["filename"]))
            }
        }
        return out
    }

    private static func fromFolders(sample: SampleFile, vocabulary: [String: String]) -> [ScoredTag] {
        let tokenRules = loadTokenRules()
        let rules = tokenRules.folderTokens ?? tokenRules.tokens
        let excluded = Set(tokenRules.excludedFolderTokens?.map { $0.lowercased() } ?? defaultExcludedFolderTokens)
        let folderBits = tokenize(sample.folderPath.replacingOccurrences(of: "/", with: " "))
        var out: [ScoredTag] = []

        for token in folderBits {
            guard !isExcludedToken(token), !excluded.contains(token) else { continue }
            if let tag = matchToken(token, rules: rules, vocabulary: vocabulary) {
                out.append(ScoredTag(tag: tag, confidence: 0.72, sources: ["folder"]))
            }
        }
        return out
    }

    // MARK: - Audio heuristics

    private static func fromAudio(
        sample: SampleFile,
        analysis: AnalysisResult,
        vocabulary: [String: String]
    ) -> [ScoredTag] {
        var out: [ScoredTag] = []
        let kickiness = analysis.kickiness ?? sample.kickiness ?? 0
        let pitch = analysis.pitchSalience ?? sample.pitchSalience ?? 0
        let duration = analysis.duration ?? sample.duration ?? 0
        let onsetCount = analysis.onsetTimes.count
        let bright = sample.libBright ?? 0.5
        let energy = sample.libEnergy ?? 0.3

        if kickiness > 70 {
            add(&out, tag: "kik", confidence: 0.82, source: "audio", vocabulary: vocabulary)
        } else if kickiness > 45 {
            add(&out, tag: "bass", confidence: 0.68, source: "audio", vocabulary: vocabulary)
        }

        if let band = dominantBand(in: analysis.onsetInfos) {
            switch band {
            case 0:
                add(&out, tag: kickiness > 55 ? "kik" : "bass", confidence: 0.75, source: "audio", vocabulary: vocabulary)
            case 1:
                add(&out, tag: "snare", confidence: 0.78, source: "audio", vocabulary: vocabulary)
                add(&out, tag: "drums", confidence: 0.62, source: "audio", vocabulary: vocabulary)
            case 2:
                add(&out, tag: "snare", confidence: 0.65, source: "audio", vocabulary: vocabulary)
                add(&out, tag: "top", confidence: 0.72, source: "audio", vocabulary: vocabulary)
            case 3:
                add(&out, tag: "top", confidence: 0.80, source: "audio", vocabulary: vocabulary)
            default:
                break
            }
        }

        if pitch > 55 && duration > 0.4 {
            add(&out, tag: "melody", confidence: 0.58, source: "audio", vocabulary: vocabulary)
            if pitch > 70 {
                add(&out, tag: "synth", confidence: 0.60, source: "audio", vocabulary: vocabulary)
            }
        }

        if pitch < 25 && duration < 1.2 {
            add(&out, tag: "percussive", confidence: 0.65, source: "audio", vocabulary: vocabulary)
        }

        if duration < 0.35 && onsetCount <= 2 {
            add(&out, tag: "stab", confidence: 0.60, source: "audio", vocabulary: vocabulary)
        }

        if duration > 3 && onsetCount >= 4 {
            add(&out, tag: "repetitive", confidence: 0.58, source: "audio", vocabulary: vocabulary)
        }

        if bright > 0.78 && energy > 0.55 {
            add(&out, tag: "top", confidence: 0.55, source: "audio", vocabulary: vocabulary)
        }

        if bright < 0.28 && energy > 0.6 {
            add(&out, tag: "industrial", confidence: 0.58, source: "audio", vocabulary: vocabulary)
        }

        if bright < 0.35 && energy < 0.35 && duration > 2 {
            add(&out, tag: "ambient", confidence: 0.62, source: "audio", vocabulary: vocabulary)
        }

        if energy > 0.75 && bright > 0.5 {
            add(&out, tag: "distorted", confidence: 0.55, source: "audio", vocabulary: vocabulary)
        }

        return out
    }

    private static func fromTagZones(
        sample: SampleFile,
        preset: TagZonePreset,
        vocabulary: [String: String]
    ) -> [ScoredTag] {
        guard let pitch = sample.libPitch else { return [] }
        let energy = sample.libEnergy ?? 0.5
        let bright = sample.libBright ?? 0.5
        let energyWin = preset.axisWindows["energy"] ?? TagAxisWindow()
        let brightWin = preset.axisWindows["bright"] ?? TagAxisWindow()
        var out: [ScoredTag] = []

        for zone in preset.zones {
            let pitchMatch = zone.contains(scrubY: pitch)
            let energyMatch = TagZoneMath.scalarInWindow(zone.y, origin: energy, window: energyWin)
            let brightMatch = TagZoneMath.scalarInWindow(zone.y, origin: bright, window: brightWin)

            guard pitchMatch || (energyMatch && brightMatch) else { continue }

            var confidence = pitchMatch ? 0.58 : 0.56
            if energyMatch { confidence += 0.04 }
            if brightMatch { confidence += 0.04 }
            confidence = min(0.74, confidence)

            for tag in zone.tags {
                add(&out, tag: tag, confidence: confidence, source: "zone", vocabulary: vocabulary)
            }
        }
        return out
    }

    // MARK: - Helpers

    private static func dominantBand(in infos: [AnalysisResult.OnsetInfo]) -> Int? {
        guard !infos.isEmpty else { return nil }
        var counts = [0, 0, 0, 0]
        for info in infos {
            for (i, flag) in info.bandBools.enumerated() where i < 4 && flag > 0 {
                counts[i] += 1
            }
        }
        guard let maxCount = counts.max(), maxCount > 0 else { return nil }
        return counts.firstIndex(of: maxCount)
    }

    private static func tokenize(_ text: String) -> [String] {
        let expanded = expandCompoundTokens(text)
        return expanded.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func expandCompoundTokens(_ text: String) -> String {
        var result = text
        let camelRange = NSRange(result.startIndex..., in: result)
        result = camelCasePattern.stringByReplacingMatches(in: result, range: camelRange, withTemplate: "$1 $2")
        let letterDigitRange = NSRange(result.startIndex..., in: result)
        result = letterDigitPattern.stringByReplacingMatches(in: result, range: letterDigitRange, withTemplate: "$1 $2")
        let digitLetterRange = NSRange(result.startIndex..., in: result)
        result = digitLetterPattern.stringByReplacingMatches(in: result, range: digitLetterRange, withTemplate: "$1 $2")
        return result
    }

    private static func isExcludedToken(_ token: String) -> Bool {
        if drumNumberTokens.contains(token) { return false }
        if token == "bpm" || token.hasSuffix("bpm") { return true }
        if let n = Double(token), (60...200).contains(n) { return true }
        let range = NSRange(token.startIndex..., in: token)
        if keyPattern.firstMatch(in: token, range: range) != nil { return true }
        let noise = Set(["wav", "mp3", "aif", "aiff", "sample", "samples", "audio", "one", "shot", "oneshot"])
        return noise.contains(token)
    }

    private static let defaultExcludedFolderTokens = [
        "splice", "loopmasters", "loopmaster", "cymatics", "native", "instruments",
        "kontakt", "pack", "packs", "sample", "samples", "library", "libraries",
        "download", "downloads", "desktop", "documents", "users", "volumes",
    ]

    private static func matchToken(
        _ token: String,
        rules: [String: [String]],
        vocabulary: [String: String]
    ) -> String? {
        if let hit = vocabulary[token.lowercased()] {
            return hit
        }
        for (tag, aliases) in rules {
            guard let canon = canonicalTag(tag, vocabulary: vocabulary) else { continue }
            if aliases.contains(where: { $0.lowercased() == token }) || tag.lowercased() == token {
                return canon
            }
        }
        return canonicalTag(token, vocabulary: vocabulary)
    }

    private static func buildVocabulary(preset: TagZonePreset, userVocabulary: [String]) -> [String: String] {
        var map: [String: String] = [:]
        func register(_ tag: String) {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            map[trimmed.lowercased()] = trimmed
        }

        for zone in preset.zones {
            for tag in zone.tags { register(tag) }
        }
        let rules = loadTokenRules()
        for (tag, aliases) in rules.tokens {
            register(tag)
            if let canon = map[tag.lowercased()] {
                for alias in aliases { map[alias.lowercased()] = canon }
            }
        }
        for tag in userVocabulary { register(tag) }
        return map
    }

    private static func canonicalTag(_ raw: String, vocabulary: [String: String]) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return vocabulary[trimmed.lowercased()]
    }

    private static func add(
        _ list: inout [ScoredTag],
        tag: String,
        confidence: Double,
        source: String,
        vocabulary: [String: String]
    ) {
        guard let canon = canonicalTag(tag, vocabulary: vocabulary) else { return }
        list.append(ScoredTag(tag: canon, confidence: confidence, sources: [source]))
    }

    private static func merge(_ scored: inout [String: ScoredTag], _ incoming: [ScoredTag]) {
        for item in incoming {
            if var existing = scored[item.tag] {
                let distinctNewSources = item.sources.subtracting(existing.sources)
                existing.sources.formUnion(item.sources)
                let peak = max(existing.confidence, item.confidence)
                if !distinctNewSources.isEmpty {
                    existing.confidence = min(
                        maxBoostedConfidence,
                        peak + agreementBoost * Double(distinctNewSources.count)
                    )
                } else {
                    existing.confidence = peak
                }
                scored[item.tag] = existing
            } else {
                scored[item.tag] = item
            }
        }
    }

    private static func finalizeScored(
        _ scored: [String: ScoredTag],
        excludingLowercased existing: Set<String>
    ) -> [TagSuggestionItem] {
        scored.values
            .filter { $0.confidence >= minConfidence && !existing.contains($0.tag.lowercased()) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxSuggestions)
            .map { TagSuggestionItem(tag: $0.tag, confidence: $0.confidence, source: $0.sourceLabel) }
    }

    private static func loadTokenRules() -> TokenRules {
        if let cachedTokenRules { return cachedTokenRules }

        var candidateURLs: [URL] = []
        if let url = Bundle.main.url(forResource: "tag-token-rules", withExtension: "json") {
            candidateURLs.append(url)
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidateURLs.append(resourceURL.appendingPathComponent("tag-token-rules.json"))
            candidateURLs.append(
                resourceURL
                    .appendingPathComponent("ButterClassifier_ButterClassifier.bundle")
                    .appendingPathComponent("tag-token-rules.json")
            )
        }

        for url in candidateURLs {
            guard let data = try? Data(contentsOf: url),
                  let rules = try? JSONDecoder().decode(TokenRules.self, from: data) else {
                continue
            }
            cachedTokenRules = rules
            return rules
        }

        cachedTokenRules = fallbackTokenRules()
        return cachedTokenRules!
    }

    private static func fallbackTokenRules() -> TokenRules {
        TokenRules(
            tokens: [
                "kik": ["kick", "kik", "bd"],
                "snare": ["snare", "snr", "sd", "clap"],
                "top": ["hat", "hihat", "hh", "oh", "ch"],
                "bass": ["bass", "808", "sub"],
                "drums": ["drum", "drums"],
                "synth": ["synth", "syn"],
                "vocal": ["vocal", "vox"],
                "sfx": ["sfx", "fx"],
            ],
            folderTokens: [
                "drums": ["drums", "drum"],
                "vocal": ["vocals", "vox"],
                "sfx": ["sfx", "fx"],
            ],
            excludedFolderTokens: defaultExcludedFolderTokens
        )
    }
}
