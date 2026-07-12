import Foundation

/// One horizontal band on the Tag Zones depth map. Tags are OR'd within a zone.
struct TagZone: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var tags: [String]
    /// Band center, 0 = bottom, 1 = top (LUP convention).
    var y: Double
    /// Band height, 0–1.
    var h: Double

    enum CodingKeys: String, CodingKey {
        case tags, y, h
    }

    init(tags: [String], y: Double, h: Double) {
        self.tags = tags
        self.y = min(1, max(0, y))
        self.h = min(1, max(0.01, h))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tags = try c.decode([String].self, forKey: .tags)
        y = try c.decode(Double.self, forKey: .y)
        h = try c.decode(Double.self, forKey: .h)
    }

    var bottom: Double { y - h / 2 }
    var top: Double { y + h / 2 }

    func contains(scrubY: Double) -> Bool {
        scrubY >= bottom && scrubY <= top
    }
}

struct TagAxisWindow: Codable, Hashable {
    var endW: Double = 0.05
    var midW: Double = 1.0
    var steepness: Double = 1.6
}

struct TagZonePreset: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var zones: [TagZone]
    var axisWindows: [String: TagAxisWindow]

    enum CodingKeys: String, CodingKey {
        case name, zones, axisWindows
    }

    init(name: String, zones: [TagZone] = [], axisWindows: [String: TagAxisWindow] = TagZonePreset.defaultAxisWindows) {
        self.name = name
        self.zones = zones
        self.axisWindows = axisWindows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        zones = try c.decode([TagZone].self, forKey: .zones)
        axisWindows = try c.decodeIfPresent([String: TagAxisWindow].self, forKey: .axisWindows)
            ?? TagZonePreset.defaultAxisWindows
    }

    static let axisKeys = ["energy", "fame", "date", "bright"]

    static var defaultAxisWindows: [String: TagAxisWindow] {
        Dictionary(uniqueKeysWithValues: axisKeys.map { ($0, TagAxisWindow()) })
    }

    /// Union of all tags in zones that contain scrubY.
    func tagsAtScrub(_ scrubY: Double) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for zone in zones where zone.contains(scrubY: scrubY) {
            for tag in zone.tags where seen.insert(tag).inserted {
                out.append(tag)
            }
        }
        return out
    }
}

enum TagZoneMath {
    /// LUP-style window: returns [low, high] for scalar at origin x.
    static func windowRange(origin: Double, window: TagAxisWindow) -> (Double, Double) {
        let mid = min(1, max(0, origin))
        let half = window.midW / 2
        var lo = mid - half
        var hi = mid + half
        let pad = window.endW
        lo = max(0, lo - pad)
        hi = min(1, hi + pad)
        return (lo, hi)
    }

    static func scalarInWindow(_ value: Double, origin: Double, window: TagAxisWindow) -> Bool {
        let (lo, hi) = windowRange(origin: origin, window: window)
        return value >= lo && value <= hi
    }
}
