import Foundation
import SwiftData

@Model
final class WatchedFolder {
    @Attribute(.unique) var path: String
    var dateAdded: Date

    init(path: String) {
        self.path = path
        self.dateAdded = Date()
    }

    var name: String { (path as NSString).lastPathComponent }
    var url: URL { FolderURLResolver.resolve(URL(fileURLWithPath: path)) }
}

@Model
final class SampleFile {
    @Attribute(.unique) var path: String
    var name: String
    var folderPath: String
    var watchedFolderPath: String
    var modifiedAt: Date
    var fileSize: Int64

    var isAnalyzed: Bool
    /// Modification date of the YAML we last parsed, to detect stale caches.
    var yamlModifiedAt: Date?

    // Headline metrics cached from the analysis YAML.
    var duration: Double?
    var bpm: Double?
    var loudnessLUFS: Double?
    var kickiness: Double?
    var swing8th: Double?
    var swing16th: Double?
    var pitchSalience: Double?
    var sampleRate: Int?
    var onsetTimes: [Double]

    /// User tags from `sample.wav_tags.yaml`.
    var tags: [String]
    var tagsModifiedAt: Date?
    /// Auto-suggested tags (separate from confirmed tags in the sidecar).
    var suggestedTagNames: [String] = []
    var suggestedTagConfidences: [Double] = []
    var suggestedTagSources: [String] = []

    /// User classification overrides from `sample.wav_edits.yaml`.
    var editsModifiedAt: Date?
    var editBpmOverride: Double?
    var editKeyOverride: String?
    var editLoopStart: Double?
    var editLoopEnd: Double?
    var editOnsetTimes: [Double] = []

    /// Library finder scalars (from analysis YAML).
    var libPitch: Double?
    var libBright: Double?
    var libEnergy: Double?
    var libDurN: Double?
    /// 16 mini-waveform strips for the library canvas.
    var glyphRadii: [Double]
    var glyphPitch: [Double]

    init(path: String, name: String, folderPath: String, watchedFolderPath: String,
         modifiedAt: Date, fileSize: Int64) {
        self.path = path
        self.name = name
        self.folderPath = folderPath
        self.watchedFolderPath = watchedFolderPath
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
        self.isAnalyzed = false
        self.onsetTimes = []
        self.tags = []
        self.editOnsetTimes = []
        self.glyphRadii = []
        self.glyphPitch = []
    }

    var tagsURL: URL { URL(fileURLWithPath: path + "_tags.yaml") }
    /// Cached waveform peaks — `sample.wav.wfc` alongside the audio + YAML.
    var waveformCacheURL: URL { URL(fileURLWithPath: path + ".wfc") }
    /// Cached supersample peaks — `sample.wav.wfx` alongside the audio + YAML.
    var supersampleCacheURL: URL { URL(fileURLWithPath: path + ".wfx") }
    /// Cached upsampled spectral data — `sample.wav.sfc` alongside the audio + YAML.
    var spectralCacheURL: URL { URL(fileURLWithPath: path + ".sfc") }

    var url: URL { URL(fileURLWithPath: path) }
    var yamlURL: URL { URL(fileURLWithPath: path + ".yaml") }
    var editsURL: URL { EditSidecar.url(forAudioPath: path) }

    var effectiveBpm: Double? { editBpmOverride ?? bpm }
    var effectiveKey: String? {
        let k = editKeyOverride?.trimmingCharacters(in: .whitespaces)
        return (k?.isEmpty == false) ? k : nil
    }
    var hasClassificationEdits: Bool { editsModifiedAt != nil }

    var tagSuggestions: [TagSuggestionItem] {
        guard suggestedTagNames.count == suggestedTagConfidences.count,
              suggestedTagNames.count == suggestedTagSources.count else {
            return []
        }
        return zip(zip(suggestedTagNames, suggestedTagConfidences), suggestedTagSources).map { pair, source in
            TagSuggestionItem(tag: pair.0, confidence: pair.1, source: source)
        }
    }

    func setTagSuggestions(_ items: [TagSuggestionItem]) {
        suggestedTagNames = items.map(\.tag)
        suggestedTagConfidences = items.map(\.confidence)
        suggestedTagSources = items.map(\.source)
    }

    // Non-optional sort keys for Table comparators.
    var durationSort: Double { duration ?? -1 }
    var bpmSort: Double { effectiveBpm ?? -1 }
    var loudnessSort: Double { loudnessLUFS ?? -999 }
    var kickinessSort: Double { kickiness ?? -1 }
    var swing8Sort: Double { swing8th ?? -1 }
    var swing16Sort: Double { swing16th ?? -1 }
}
