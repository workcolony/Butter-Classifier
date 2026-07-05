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
    var url: URL { URL(fileURLWithPath: path) }
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
    }

    var url: URL { URL(fileURLWithPath: path) }
    var yamlURL: URL { URL(fileURLWithPath: path + ".yaml") }

    // Non-optional sort keys for Table comparators.
    var durationSort: Double { duration ?? -1 }
    var bpmSort: Double { bpm ?? -1 }
    var loudnessSort: Double { loudnessLUFS ?? -999 }
    var kickinessSort: Double { kickiness ?? -1 }
    var swing8Sort: Double { swing8th ?? -1 }
    var swing16Sort: Double { swing16th ?? -1 }
}
