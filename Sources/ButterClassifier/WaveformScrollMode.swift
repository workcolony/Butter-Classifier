import Foundation

/// Horizontal waveform pan behavior when zoomed in.
enum WaveformScrollMode: String, CaseIterable, Identifiable {
    case none
    case page
    case continuous

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .page: return "Page"
        case .continuous: return "Continuous"
        }
    }

    /// Fraction of total scroll range per ◀ / ▶ click (or one wheel notch in page mode).
    func step(zoom: Double) -> Double {
        switch self {
        case .none: return 0.01
        case .page:
            guard zoom > 1.01 else { return 0 }
            // One viewport width worth of scroll.
            return 1.0 / max(1, zoom - 1)
        case .continuous:
            return max(0.05, 1.0 / max(1, zoom))
        }
    }

    /// Snap scroll position to page boundaries.
    func snapFraction(_ fraction: Double, zoom: Double) -> Double {
        guard self == .page, zoom > 1.01 else { return fraction }
        let page = step(zoom: zoom)
        guard page > 0 else { return fraction }
        let pages = (fraction / page).rounded()
        return min(1, max(0, pages * page))
    }
}
