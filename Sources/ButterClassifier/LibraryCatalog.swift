import Foundation

enum LibraryXAxis: String, CaseIterable, Identifiable {
    case pitch, bright, dur, energy, name, date

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pitch: return "PITCH"
        case .bright: return "BRIGHT"
        case .dur: return "LENGTH"
        case .energy: return "ENERGY"
        case .name: return "NAME"
        case .date: return "DATE"
        }
    }

    var lowLabel: String {
        switch self {
        case .pitch: return "LOW"
        case .bright: return "DARK"
        case .dur: return "SHORT"
        case .energy: return "QUIET"
        case .name: return "A"
        case .date: return "OLD"
        }
    }

    var highLabel: String {
        switch self {
        case .pitch: return "HIGH"
        case .bright: return "BRIGHT"
        case .dur: return "LONG"
        case .energy: return "LOUD"
        case .name: return "Z"
        case .date: return "NEW"
        }
    }
}

enum LibraryYAxis: String, CaseIterable, Identifiable {
    case sort, pitch, bright, dur, energy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sort: return "SORT"
        case .pitch: return "PITCH"
        case .bright: return "BRIGHT"
        case .dur: return "LENGTH"
        case .energy: return "ENERGY"
        }
    }
}

/// Runtime view-model row for the library canvas (LUP crate entry).
struct LibraryEntry: Identifiable {
    let sample: SampleFile
    let nameRank: Double
    let dateRank: Double

    var id: String { sample.path }

    var pitch: Double { sample.libPitch ?? 0.5 }
    var bright: Double { sample.libBright ?? 0.5 }
    var energy: Double { sample.libEnergy ?? 0.3 }
    var durN: Double { sample.libDurN ?? min(1, (sample.duration ?? 0) / 12) }

    func xScalar(_ axis: LibraryXAxis) -> Double {
        switch axis {
        case .pitch: return pitch
        case .bright: return bright
        case .dur: return durN
        case .energy: return energy
        case .name: return nameRank
        case .date: return dateRank
        }
    }

    func yScalar(_ axis: LibraryYAxis, xAxis: LibraryXAxis) -> Double {
        switch axis {
        case .sort: return xScalar(xAxis)
        case .pitch: return pitch
        case .bright: return bright
        case .dur: return durN
        case .energy: return energy
        }
    }

    var glyphRadii: [Double] {
        let r = sample.glyphRadii
        if r.count == LibraryFeatures.glyphFrameCount { return r }
        return (0..<LibraryFeatures.glyphFrameCount).map { _ in 0.2 }
    }

    var glyphPitch: [Double] {
        let p = sample.glyphPitch
        if p.count == LibraryFeatures.glyphFrameCount { return p }
        return (0..<LibraryFeatures.glyphFrameCount).map { _ in pitch }
    }
}

enum LibraryCatalog {
    static func build(from samples: [SampleFile]) -> [LibraryEntry] {
        let sorted = samples.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let byDate = samples.sorted { $0.modifiedAt < $1.modifiedAt }
        let nameDenom = max(1, sorted.count - 1)
        let dateDenom = max(1, byDate.count - 1)

        var nameRank: [String: Double] = [:]
        for (i, s) in sorted.enumerated() {
            nameRank[s.path] = Double(i) / Double(nameDenom)
        }
        var dateRank: [String: Double] = [:]
        for (i, s) in byDate.enumerated() {
            dateRank[s.path] = Double(i) / Double(dateDenom)
        }

        return samples.map {
            LibraryEntry(sample: $0, nameRank: nameRank[$0.path] ?? 0.5, dateRank: dateRank[$0.path] ?? 0.5)
        }
    }

    static func tagCounts(in samples: [SampleFile]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for s in samples {
            for tag in s.tags {
                counts[tag, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    static func matchesTags(_ sample: SampleFile, selected: Set<String>) -> Bool {
        guard !selected.isEmpty else { return true }
        return sample.tags.contains { selected.contains($0) }
    }
}
