import SwiftUI

/// Multi-stop colormap for Mel spectrogram amplitude (0 = quiet, 1 = peak).
struct SpectrogramColormap: Equatable {
    struct Stop: Equatable {
        var t: Double
        var r: Double
        var g: Double
        var b: Double
    }

    var stops: [Stop]

    func rgb(at t: Double) -> (red: Double, green: Double, blue: Double) {
        let t = min(1, max(0, t))
        guard let first = stops.first else { return (0, 0, 0) }
        guard stops.count > 1 else { return (first.r, first.g, first.b) }
        if t <= first.t { return (first.r, first.g, first.b) }
        for i in 1..<stops.count {
            let a = stops[i - 1]
            let b = stops[i]
            if t <= b.t {
                let span = max(b.t - a.t, 0.0001)
                let u = (t - a.t) / span
                return (
                    a.r + (b.r - a.r) * u,
                    a.g + (b.g - a.g) * u,
                    a.b + (b.b - a.b) * u
                )
            }
        }
        let last = stops[stops.count - 1]
        return (last.r, last.g, last.b)
    }
}

/// Resolved palette used when drawing the waveform editor.
struct ResolvedWaveformTheme: Equatable {
    var background: Color
    var waveFill: Color
    var waveStroke: Color
    var waveFillOpacity: Double
    var waveStrokeOpacity: Double
    var supersampleFillOpacity: Double
    var supersampleStrokeOpacity: Double
    var supersampleStrokeWidth: CGFloat
    var showCenterLine: Bool
    var centerLineOpacity: Double
    var selectionFill: Color
    var selectionEdge: Color
    var loopFill: Color
    var loopEdge: Color
    var playhead: Color
    var playheadOnOnset: Color
    var onset: Color
    var onsetActive: Color
    var onsetPlayhead: Color
    var onsetActiveGlow: Color
    var onsetActiveCore: Color
    var glassTintOpacity: Double
    var spectrogramColormap: SpectrogramColormap
}

struct WaveformColorTheme: Identifiable, Equatable {
    let id: String
    let name: String
    private let spec: ThemeSpec

    static let storageKey = "waveformColorTheme"

    static let all: [WaveformColorTheme] = [
        .system,
        .snapper,
        .snapperWarm,
        .homebrew,
        .pro,
        .ocean,
        .solarized,
        .manuscript,
        .butter,
        .neonTokyo,
        .synthwave,
        .magma,
        .aurora,
        .iceCave,
        .toxic,
        .midnightJazz,
        .bloodOrange,
        .vapor,
        .ember,
        .ultraviolet,
        .coralReef,
        .noir,
        .plasma,
        .forest,
    ]

    static func theme(id: String) -> WaveformColorTheme {
        all.first { $0.id == id } ?? .system
    }

    func resolved() -> ResolvedWaveformTheme {
        spec.resolved()
    }

    // MARK: - Presets

    static let system = WaveformColorTheme(
        id: "system",
        name: "System",
        spec: .system
    )

    /// Audio Ease Snapper — dark chrome, bright green wave, blue selection, green playhead.
    static let snapper = WaveformColorTheme(
        id: "snapper",
        name: "Snapper",
        spec: ThemeSpec(
            background: .rgb(0.11, 0.11, 0.12),
            wave: .rgb(0.42, 0.86, 0.48),
            waveFillOpacity: 0.42,
            waveStrokeOpacity: 0.95,
            supersampleFillOpacity: 0.22,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.85,
            showCenterLine: true,
            centerLineOpacity: 0.14,
            selectionFill: .rgb(0.22, 0.48, 0.82, opacity: 0.35),
            selectionEdge: .rgb(0.35, 0.62, 0.96),
            loopFill: .rgb(0.42, 0.86, 0.48, opacity: 0.14),
            loopEdge: .rgb(0.42, 0.86, 0.48, opacity: 0.88),
            playhead: .rgb(0.42, 0.86, 0.48),
            playheadOnOnset: .rgb(0.98, 0.78, 0.18),
            onset: .rgb(0.98, 0.78, 0.18, opacity: 0.72),
            onsetActive: .rgb(0.98, 0.78, 0.18, opacity: 0.95),
            onsetPlayhead: .rgb(0.98, 0.78, 0.18),
            onsetActiveGlow: .rgb(0.98, 0.78, 0.18, opacity: 0.5),
            onsetActiveCore: .rgb(1.0, 0.92, 0.45),
            glassTintOpacity: 0.32,
            spectrogram: .stops([
                (0.00, 0.08, 0.08, 0.09),
                (0.22, 0.06, 0.22, 0.14),
                (0.45, 0.18, 0.55, 0.28),
                (0.70, 0.42, 0.86, 0.48),
                (0.88, 0.78, 0.95, 0.42),
                (1.00, 0.98, 0.96, 0.72),
            ])
        )
    )

    /// Snapper-style with warmer background and amber playhead.
    static let snapperWarm = WaveformColorTheme(
        id: "snapper-warm",
        name: "Snapper Warm",
        spec: ThemeSpec(
            background: .rgb(0.14, 0.12, 0.10),
            wave: .rgb(0.55, 0.90, 0.52),
            waveFillOpacity: 0.44,
            waveStrokeOpacity: 0.92,
            supersampleFillOpacity: 0.24,
            supersampleStrokeOpacity: 0.98,
            supersampleStrokeWidth: 0.85,
            showCenterLine: true,
            centerLineOpacity: 0.12,
            selectionFill: .rgb(0.82, 0.55, 0.18, opacity: 0.28),
            selectionEdge: .rgb(0.96, 0.68, 0.24),
            loopFill: .rgb(0.55, 0.90, 0.52, opacity: 0.12),
            loopEdge: .rgb(0.55, 0.90, 0.52, opacity: 0.85),
            playhead: .rgb(0.96, 0.68, 0.24),
            playheadOnOnset: .rgb(0.98, 0.42, 0.22),
            onset: .rgb(0.96, 0.68, 0.24, opacity: 0.7),
            onsetActive: .rgb(0.98, 0.42, 0.22, opacity: 0.95),
            onsetPlayhead: .rgb(0.98, 0.42, 0.22),
            onsetActiveGlow: .rgb(0.98, 0.42, 0.22, opacity: 0.45),
            onsetActiveCore: .rgb(1.0, 0.72, 0.38),
            glassTintOpacity: 0.34,
            spectrogram: .stops([
                (0.00, 0.10, 0.08, 0.06),
                (0.25, 0.18, 0.28, 0.10),
                (0.48, 0.35, 0.62, 0.28),
                (0.68, 0.55, 0.90, 0.52),
                (0.85, 0.96, 0.72, 0.28),
                (1.00, 1.00, 0.88, 0.62),
            ])
        )
    )

    static let homebrew = WaveformColorTheme(
        id: "homebrew",
        name: "Homebrew",
        spec: ThemeSpec(
            background: .rgb(0, 0, 0),
            wave: .rgb(0.20, 0.98, 0.20),
            waveFillOpacity: 0.38,
            waveStrokeOpacity: 0.92,
            supersampleFillOpacity: 0.18,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.75,
            showCenterLine: true,
            centerLineOpacity: 0.10,
            selectionFill: .rgb(0.20, 0.98, 0.20, opacity: 0.22),
            selectionEdge: .rgb(0.20, 0.98, 0.20),
            loopFill: .rgb(0.20, 0.98, 0.20, opacity: 0.10),
            loopEdge: .rgb(0.20, 0.98, 0.20, opacity: 0.8),
            playhead: .rgb(0.95, 0.95, 0.95),
            playheadOnOnset: .rgb(0.20, 0.98, 0.20),
            onset: .rgb(0.95, 0.95, 0.95, opacity: 0.55),
            onsetActive: .rgb(0.20, 0.98, 0.20, opacity: 0.95),
            onsetPlayhead: .rgb(0.20, 0.98, 0.20),
            onsetActiveGlow: .rgb(0.20, 0.98, 0.20, opacity: 0.45),
            onsetActiveCore: .rgb(0.75, 1.0, 0.75),
            glassTintOpacity: 0.30,
            spectrogram: .stops([
                (0.00, 0.00, 0.00, 0.00),
                (0.20, 0.00, 0.18, 0.02),
                (0.42, 0.04, 0.55, 0.08),
                (0.62, 0.18, 0.88, 0.12),
                (0.82, 0.72, 0.98, 0.22),
                (1.00, 0.98, 1.00, 0.72),
            ])
        )
    )

    static let pro = WaveformColorTheme(
        id: "pro",
        name: "Pro",
        spec: ThemeSpec(
            background: .rgb(0.12, 0.12, 0.12),
            wave: .rgb(0.99, 0.59, 0.13),
            waveFillOpacity: 0.40,
            waveStrokeOpacity: 0.94,
            supersampleFillOpacity: 0.22,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.85,
            showCenterLine: true,
            centerLineOpacity: 0.12,
            selectionFill: .rgb(0.99, 0.59, 0.13, opacity: 0.24),
            selectionEdge: .rgb(0.99, 0.59, 0.13),
            loopFill: .rgb(0.66, 0.78, 0.98, opacity: 0.14),
            loopEdge: .rgb(0.66, 0.78, 0.98, opacity: 0.85),
            playhead: .rgb(0.98, 0.98, 0.98),
            playheadOnOnset: .rgb(0.99, 0.59, 0.13),
            onset: .rgb(0.98, 0.98, 0.98, opacity: 0.55),
            onsetActive: .rgb(0.99, 0.59, 0.13, opacity: 0.95),
            onsetPlayhead: .rgb(0.99, 0.59, 0.13),
            onsetActiveGlow: .rgb(0.99, 0.59, 0.13, opacity: 0.45),
            onsetActiveCore: .rgb(1.0, 0.78, 0.42),
            glassTintOpacity: 0.32,
            spectrogram: .stops([
                (0.00, 0.08, 0.08, 0.08),
                (0.22, 0.22, 0.12, 0.28),
                (0.48, 0.72, 0.28, 0.12),
                (0.70, 0.99, 0.59, 0.13),
                (0.88, 1.00, 0.82, 0.42),
                (1.00, 1.00, 0.96, 0.88),
            ])
        )
    )

    static let ocean = WaveformColorTheme(
        id: "ocean",
        name: "Ocean",
        spec: ThemeSpec(
            background: .rgb(0.04, 0.09, 0.16),
            wave: .rgb(0.31, 0.82, 0.77),
            waveFillOpacity: 0.42,
            waveStrokeOpacity: 0.94,
            supersampleFillOpacity: 0.24,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.8,
            showCenterLine: true,
            centerLineOpacity: 0.14,
            selectionFill: .rgb(0.20, 0.55, 0.95, opacity: 0.30),
            selectionEdge: .rgb(0.35, 0.68, 0.98),
            loopFill: .rgb(0.31, 0.82, 0.77, opacity: 0.12),
            loopEdge: .rgb(0.31, 0.82, 0.77, opacity: 0.85),
            playhead: .rgb(0.95, 0.45, 0.55),
            playheadOnOnset: .rgb(0.31, 0.82, 0.77),
            onset: .rgb(0.95, 0.45, 0.55, opacity: 0.65),
            onsetActive: .rgb(0.31, 0.82, 0.77, opacity: 0.95),
            onsetPlayhead: .rgb(0.31, 0.82, 0.77),
            onsetActiveGlow: .rgb(0.31, 0.82, 0.77, opacity: 0.45),
            onsetActiveCore: .rgb(0.72, 0.98, 0.94),
            glassTintOpacity: 0.34,
            spectrogram: .stops([
                (0.00, 0.02, 0.05, 0.10),
                (0.22, 0.04, 0.18, 0.38),
                (0.45, 0.08, 0.45, 0.62),
                (0.68, 0.31, 0.82, 0.77),
                (0.85, 0.72, 0.55, 0.78),
                (1.00, 0.98, 0.72, 0.82),
            ])
        )
    )

    static let solarized = WaveformColorTheme(
        id: "solarized",
        name: "Solarized",
        spec: ThemeSpec(
            background: .rgb(0.0, 0.17, 0.21),
            wave: .rgb(0.52, 0.60, 0.0),
            waveFillOpacity: 0.44,
            waveStrokeOpacity: 0.92,
            supersampleFillOpacity: 0.24,
            supersampleStrokeOpacity: 0.98,
            supersampleStrokeWidth: 0.8,
            showCenterLine: true,
            centerLineOpacity: 0.16,
            selectionFill: .rgb(0.15, 0.55, 0.82, opacity: 0.28),
            selectionEdge: .rgb(0.15, 0.55, 0.82),
            loopFill: .rgb(0.52, 0.60, 0.0, opacity: 0.12),
            loopEdge: .rgb(0.71, 0.54, 0.0, opacity: 0.85),
            playhead: .rgb(0.86, 0.20, 0.18),
            playheadOnOnset: .rgb(0.71, 0.54, 0.0),
            onset: .rgb(0.83, 0.32, 0.0, opacity: 0.65),
            onsetActive: .rgb(0.71, 0.54, 0.0, opacity: 0.95),
            onsetPlayhead: .rgb(0.71, 0.54, 0.0),
            onsetActiveGlow: .rgb(0.71, 0.54, 0.0, opacity: 0.45),
            onsetActiveCore: .rgb(0.93, 0.78, 0.32),
            glassTintOpacity: 0.32,
            spectrogram: .stops([
                (0.00, 0.00, 0.17, 0.21),
                (0.25, 0.07, 0.35, 0.38),
                (0.48, 0.42, 0.48, 0.05),
                (0.68, 0.71, 0.54, 0.00),
                (0.85, 0.86, 0.35, 0.12),
                (1.00, 0.99, 0.91, 0.65),
            ])
        )
    )

    static let manuscript = WaveformColorTheme(
        id: "manuscript",
        name: "Manuscript",
        spec: ThemeSpec(
            background: .rgb(0.96, 0.94, 0.90),
            wave: .rgb(0.22, 0.36, 0.58),
            waveFillOpacity: 0.36,
            waveStrokeOpacity: 0.88,
            supersampleFillOpacity: 0.20,
            supersampleStrokeOpacity: 0.95,
            supersampleStrokeWidth: 0.9,
            showCenterLine: true,
            centerLineOpacity: 0.10,
            selectionFill: .rgb(0.22, 0.36, 0.58, opacity: 0.18),
            selectionEdge: .rgb(0.22, 0.36, 0.58),
            loopFill: .rgb(0.18, 0.52, 0.42, opacity: 0.12),
            loopEdge: .rgb(0.18, 0.52, 0.42, opacity: 0.80),
            playhead: .rgb(0.82, 0.24, 0.18),
            playheadOnOnset: .rgb(0.18, 0.52, 0.42),
            onset: .rgb(0.82, 0.24, 0.18, opacity: 0.55),
            onsetActive: .rgb(0.18, 0.52, 0.42, opacity: 0.92),
            onsetPlayhead: .rgb(0.18, 0.52, 0.42),
            onsetActiveGlow: .rgb(0.18, 0.52, 0.42, opacity: 0.35),
            onsetActiveCore: .rgb(0.45, 0.78, 0.62),
            glassTintOpacity: 0.28,
            spectrogram: .stops([
                (0.00, 0.92, 0.90, 0.86),
                (0.22, 0.72, 0.78, 0.86),
                (0.45, 0.42, 0.55, 0.72),
                (0.68, 0.22, 0.36, 0.58),
                (0.85, 0.18, 0.48, 0.42),
                (1.00, 0.72, 0.28, 0.22),
            ])
        )
    )

    /// Warm cream field, golden wave — house blend.
    static let butter = WaveformColorTheme(
        id: "butter",
        name: "Butter",
        spec: ThemeSpec(
            background: .rgb(0.12, 0.09, 0.05),
            wave: .rgb(0.98, 0.82, 0.28),
            waveFillOpacity: 0.44,
            waveStrokeOpacity: 0.94,
            supersampleFillOpacity: 0.24,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.85,
            showCenterLine: true,
            centerLineOpacity: 0.12,
            selectionFill: .rgb(0.98, 0.72, 0.22, opacity: 0.28),
            selectionEdge: .rgb(1.00, 0.88, 0.42),
            loopFill: .rgb(0.98, 0.82, 0.28, opacity: 0.12),
            loopEdge: .rgb(0.98, 0.82, 0.28, opacity: 0.88),
            playhead: .rgb(1.00, 0.95, 0.78),
            playheadOnOnset: .rgb(0.98, 0.48, 0.18),
            onset: .rgb(0.98, 0.48, 0.18, opacity: 0.68),
            onsetActive: .rgb(0.98, 0.48, 0.18, opacity: 0.95),
            onsetPlayhead: .rgb(0.98, 0.48, 0.18),
            onsetActiveGlow: .rgb(0.98, 0.48, 0.18, opacity: 0.48),
            onsetActiveCore: .rgb(1.00, 0.78, 0.42),
            glassTintOpacity: 0.34,
            spectrogram: .stops([
                (0.00, 0.08, 0.06, 0.03),
                (0.20, 0.32, 0.10, 0.06),
                (0.40, 0.72, 0.32, 0.08),
                (0.58, 0.98, 0.68, 0.18),
                (0.78, 1.00, 0.62, 0.48),
                (1.00, 1.00, 0.94, 0.82),
            ])
        )
    )

    /// Hot pink + electric cyan on ink black — Shibuya nights.
    static let neonTokyo = WaveformColorTheme(
        id: "neon-tokyo",
        name: "Neon Tokyo",
        spec: ThemeSpec(
            background: .rgb(0.04, 0.02, 0.08),
            wave: .rgb(0.22, 0.98, 0.92),
            waveFillOpacity: 0.40,
            waveStrokeOpacity: 0.96,
            supersampleFillOpacity: 0.20,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.8,
            showCenterLine: true,
            centerLineOpacity: 0.14,
            selectionFill: .rgb(0.98, 0.18, 0.62, opacity: 0.32),
            selectionEdge: .rgb(1.00, 0.35, 0.72),
            loopFill: .rgb(0.22, 0.98, 0.92, opacity: 0.12),
            loopEdge: .rgb(0.22, 0.98, 0.92, opacity: 0.88),
            playhead: .rgb(1.00, 0.28, 0.68),
            playheadOnOnset: .rgb(0.22, 0.98, 0.92),
            onset: .rgb(1.00, 0.28, 0.68, opacity: 0.70),
            onsetActive: .rgb(0.22, 0.98, 0.92, opacity: 0.95),
            onsetPlayhead: .rgb(0.22, 0.98, 0.92),
            onsetActiveGlow: .rgb(0.22, 0.98, 0.92, opacity: 0.50),
            onsetActiveCore: .rgb(0.72, 1.00, 0.96),
            glassTintOpacity: 0.36,
            spectrogram: .stops([
                (0.00, 0.03, 0.01, 0.06),
                (0.20, 0.18, 0.04, 0.38),
                (0.42, 0.88, 0.12, 0.55),
                (0.62, 0.98, 0.28, 0.72),
                (0.82, 0.22, 0.95, 0.98),
                (1.00, 0.88, 1.00, 0.98),
            ])
        )
    )

    /// Purple haze, magenta crest, sunset playhead — Outrun forever.
    static let synthwave = WaveformColorTheme(
        id: "synthwave",
        name: "Synthwave",
        spec: ThemeSpec(
            background: .rgb(0.08, 0.04, 0.14),
            wave: .rgb(0.92, 0.28, 0.82),
            waveFillOpacity: 0.42,
            waveStrokeOpacity: 0.95,
            supersampleFillOpacity: 0.22,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.85,
            showCenterLine: true,
            centerLineOpacity: 0.14,
            selectionFill: .rgb(0.42, 0.22, 0.92, opacity: 0.34),
            selectionEdge: .rgb(0.62, 0.42, 1.00),
            loopFill: .rgb(0.92, 0.28, 0.82, opacity: 0.14),
            loopEdge: .rgb(0.92, 0.28, 0.82, opacity: 0.88),
            playhead: .rgb(1.00, 0.62, 0.22),
            playheadOnOnset: .rgb(0.42, 0.92, 1.00),
            onset: .rgb(1.00, 0.62, 0.22, opacity: 0.68),
            onsetActive: .rgb(0.42, 0.92, 1.00, opacity: 0.95),
            onsetPlayhead: .rgb(0.42, 0.92, 1.00),
            onsetActiveGlow: .rgb(0.42, 0.92, 1.00, opacity: 0.48),
            onsetActiveCore: .rgb(0.78, 0.98, 1.00),
            glassTintOpacity: 0.36,
            spectrogram: .stops([
                (0.00, 0.06, 0.02, 0.12),
                (0.20, 0.18, 0.06, 0.48),
                (0.42, 0.72, 0.12, 0.82),
                (0.62, 0.98, 0.28, 0.72),
                (0.82, 1.00, 0.58, 0.28),
                (1.00, 1.00, 0.92, 0.72),
            ])
        )
    )

    /// Charcoal crust, molten orange core.
    static let magma = WaveformColorTheme(
        id: "magma",
        name: "Magma",
        spec: ThemeSpec(
            background: .rgb(0.06, 0.03, 0.02),
            wave: .rgb(1.00, 0.42, 0.08),
            waveFillOpacity: 0.44,
            waveStrokeOpacity: 0.96,
            supersampleFillOpacity: 0.24,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.85,
            showCenterLine: true,
            centerLineOpacity: 0.12,
            selectionFill: .rgb(0.92, 0.22, 0.08, opacity: 0.30),
            selectionEdge: .rgb(1.00, 0.48, 0.18),
            loopFill: .rgb(1.00, 0.72, 0.18, opacity: 0.14),
            loopEdge: .rgb(1.00, 0.72, 0.18, opacity: 0.88),
            playhead: .rgb(1.00, 0.92, 0.55),
            playheadOnOnset: .rgb(1.00, 0.28, 0.08),
            onset: .rgb(1.00, 0.72, 0.18, opacity: 0.70),
            onsetActive: .rgb(1.00, 0.28, 0.08, opacity: 0.95),
            onsetPlayhead: .rgb(1.00, 0.28, 0.08),
            onsetActiveGlow: .rgb(1.00, 0.28, 0.08, opacity: 0.50),
            onsetActiveCore: .rgb(1.00, 0.72, 0.42),
            glassTintOpacity: 0.34,
            spectrogram: .stops([
                (0.00, 0.04, 0.02, 0.01),
                (0.20, 0.32, 0.04, 0.08),
                (0.40, 0.82, 0.08, 0.18),
                (0.60, 1.00, 0.38, 0.06),
                (0.80, 1.00, 0.72, 0.12),
                (1.00, 1.00, 0.96, 0.72),
            ])
        )
    )

    /// Northern lights wash — teal ribbons, violet sky.
    static let aurora = WaveformColorTheme(
        id: "aurora",
        name: "Aurora",
        spec: ThemeSpec(
            background: .rgb(0.03, 0.06, 0.10),
            wave: .rgb(0.35, 0.95, 0.62),
            waveFillOpacity: 0.42,
            waveStrokeOpacity: 0.94,
            supersampleFillOpacity: 0.22,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.8,
            showCenterLine: true,
            centerLineOpacity: 0.14,
            selectionFill: .rgb(0.48, 0.32, 0.92, opacity: 0.32),
            selectionEdge: .rgb(0.68, 0.52, 1.00),
            loopFill: .rgb(0.35, 0.95, 0.62, opacity: 0.12),
            loopEdge: .rgb(0.35, 0.95, 0.62, opacity: 0.88),
            playhead: .rgb(0.82, 0.55, 1.00),
            playheadOnOnset: .rgb(0.35, 0.95, 0.62),
            onset: .rgb(0.82, 0.55, 1.00, opacity: 0.68),
            onsetActive: .rgb(0.35, 0.95, 0.62, opacity: 0.95),
            onsetPlayhead: .rgb(0.35, 0.95, 0.62),
            onsetActiveGlow: .rgb(0.35, 0.95, 0.62, opacity: 0.48),
            onsetActiveCore: .rgb(0.72, 1.00, 0.85),
            glassTintOpacity: 0.34,
            spectrogram: .stops([
                (0.00, 0.02, 0.04, 0.08),
                (0.20, 0.08, 0.12, 0.42),
                (0.42, 0.12, 0.55, 0.48),
                (0.62, 0.22, 0.92, 0.55),
                (0.82, 0.72, 0.55, 0.98),
                (1.00, 0.95, 0.92, 1.00),
            ])
        )
    )

    /// Frozen blue glass, pale cyan crest.
    static let iceCave = WaveformColorTheme(
        id: "ice-cave",
        name: "Ice Cave",
        spec: ThemeSpec(
            background: .rgb(0.04, 0.08, 0.14),
            wave: .rgb(0.62, 0.92, 1.00),
            waveFillOpacity: 0.40,
            waveStrokeOpacity: 0.94,
            supersampleFillOpacity: 0.22,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.8,
            showCenterLine: true,
            centerLineOpacity: 0.16,
            selectionFill: .rgb(0.28, 0.62, 0.95, opacity: 0.30),
            selectionEdge: .rgb(0.55, 0.82, 1.00),
            loopFill: .rgb(0.62, 0.92, 1.00, opacity: 0.12),
            loopEdge: .rgb(0.62, 0.92, 1.00, opacity: 0.88),
            playhead: .rgb(1.00, 0.95, 0.98),
            playheadOnOnset: .rgb(0.42, 0.78, 1.00),
            onset: .rgb(0.78, 0.92, 1.00, opacity: 0.62),
            onsetActive: .rgb(0.42, 0.78, 1.00, opacity: 0.95),
            onsetPlayhead: .rgb(0.42, 0.78, 1.00),
            onsetActiveGlow: .rgb(0.42, 0.78, 1.00, opacity: 0.45),
            onsetActiveCore: .rgb(0.88, 0.98, 1.00),
            glassTintOpacity: 0.32,
            spectrogram: .stops([
                (0.00, 0.02, 0.05, 0.10),
                (0.20, 0.06, 0.18, 0.42),
                (0.42, 0.08, 0.48, 0.78),
                (0.62, 0.28, 0.82, 0.95),
                (0.82, 0.72, 0.88, 0.55),
                (1.00, 0.98, 0.95, 0.88),
            ])
        )
    )

    /// Acid lime on pitch — hazardous material.
    static let toxic = WaveformColorTheme(
        id: "toxic",
        name: "Toxic",
        spec: ThemeSpec(
            background: .rgb(0.04, 0.06, 0.02),
            wave: .rgb(0.78, 1.00, 0.12),
            waveFillOpacity: 0.42,
            waveStrokeOpacity: 0.96,
            supersampleFillOpacity: 0.22,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.8,
            showCenterLine: true,
            centerLineOpacity: 0.12,
            selectionFill: .rgb(0.62, 0.95, 0.08, opacity: 0.28),
            selectionEdge: .rgb(0.88, 1.00, 0.28),
            loopFill: .rgb(0.78, 1.00, 0.12, opacity: 0.12),
            loopEdge: .rgb(0.78, 1.00, 0.12, opacity: 0.88),
            playhead: .rgb(0.95, 0.22, 0.85),
            playheadOnOnset: .rgb(0.78, 1.00, 0.12),
            onset: .rgb(0.95, 0.22, 0.85, opacity: 0.68),
            onsetActive: .rgb(0.78, 1.00, 0.12, opacity: 0.95),
            onsetPlayhead: .rgb(0.78, 1.00, 0.12),
            onsetActiveGlow: .rgb(0.78, 1.00, 0.12, opacity: 0.48),
            onsetActiveCore: .rgb(0.92, 1.00, 0.55),
            glassTintOpacity: 0.34,
            spectrogram: .stops([
                (0.00, 0.02, 0.04, 0.01),
                (0.20, 0.08, 0.28, 0.04),
                (0.42, 0.35, 0.72, 0.08),
                (0.62, 0.78, 0.98, 0.12),
                (0.82, 0.95, 0.42, 0.88),
                (1.00, 1.00, 0.92, 0.98),
            ])
        )
    )

    /// Deep indigo club, brushed-gold markers.
    static let midnightJazz = WaveformColorTheme(
        id: "midnight-jazz",
        name: "Midnight Jazz",
        spec: ThemeSpec(
            background: .rgb(0.06, 0.05, 0.12),
            wave: .rgb(0.92, 0.78, 0.42),
            waveFillOpacity: 0.40,
            waveStrokeOpacity: 0.92,
            supersampleFillOpacity: 0.22,
            supersampleStrokeOpacity: 0.98,
            supersampleStrokeWidth: 0.85,
            showCenterLine: true,
            centerLineOpacity: 0.14,
            selectionFill: .rgb(0.42, 0.35, 0.82, opacity: 0.32),
            selectionEdge: .rgb(0.62, 0.55, 0.98),
            loopFill: .rgb(0.92, 0.78, 0.42, opacity: 0.12),
            loopEdge: .rgb(0.92, 0.78, 0.42, opacity: 0.85),
            playhead: .rgb(0.98, 0.92, 0.72),
            playheadOnOnset: .rgb(0.72, 0.48, 1.00),
            onset: .rgb(0.92, 0.78, 0.42, opacity: 0.65),
            onsetActive: .rgb(0.72, 0.48, 1.00, opacity: 0.95),
            onsetPlayhead: .rgb(0.72, 0.48, 1.00),
            onsetActiveGlow: .rgb(0.72, 0.48, 1.00, opacity: 0.45),
            onsetActiveCore: .rgb(0.92, 0.78, 1.00),
            glassTintOpacity: 0.34,
            spectrogram: .stops([
                (0.00, 0.04, 0.03, 0.10),
                (0.20, 0.18, 0.10, 0.42),
                (0.42, 0.42, 0.22, 0.72),
                (0.62, 0.78, 0.48, 0.55),
                (0.82, 0.98, 0.82, 0.32),
                (1.00, 1.00, 0.95, 0.78),
            ])
        )
    )

    /// Scorched citrus — tangerine wave, crimson hits.
    static let bloodOrange = WaveformColorTheme(
        id: "blood-orange",
        name: "Blood Orange",
        spec: ThemeSpec(
            background: .rgb(0.10, 0.05, 0.04),
            wave: .rgb(1.00, 0.48, 0.18),
            waveFillOpacity: 0.44,
            waveStrokeOpacity: 0.95,
            supersampleFillOpacity: 0.24,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.85,
            showCenterLine: true,
            centerLineOpacity: 0.12,
            selectionFill: .rgb(0.92, 0.28, 0.18, opacity: 0.30),
            selectionEdge: .rgb(1.00, 0.42, 0.28),
            loopFill: .rgb(1.00, 0.62, 0.22, opacity: 0.14),
            loopEdge: .rgb(1.00, 0.62, 0.22, opacity: 0.88),
            playhead: .rgb(1.00, 0.92, 0.72),
            playheadOnOnset: .rgb(0.92, 0.12, 0.22),
            onset: .rgb(1.00, 0.62, 0.22, opacity: 0.68),
            onsetActive: .rgb(0.92, 0.12, 0.22, opacity: 0.95),
            onsetPlayhead: .rgb(0.92, 0.12, 0.22),
            onsetActiveGlow: .rgb(0.92, 0.12, 0.22, opacity: 0.48),
            onsetActiveCore: .rgb(1.00, 0.55, 0.42),
            glassTintOpacity: 0.34,
            spectrogram: .stops([
                (0.00, 0.07, 0.03, 0.02),
                (0.20, 0.42, 0.04, 0.12),
                (0.40, 0.88, 0.12, 0.22),
                (0.58, 1.00, 0.38, 0.12),
                (0.78, 1.00, 0.72, 0.22),
                (1.00, 1.00, 0.94, 0.72),
            ])
        )
    )

    /// Soft pastel mist over lilac dusk.
    static let vapor = WaveformColorTheme(
        id: "vapor",
        name: "Vapor",
        spec: ThemeSpec(
            background: .rgb(0.10, 0.08, 0.16),
            wave: .rgb(0.72, 0.88, 1.00),
            waveFillOpacity: 0.40,
            waveStrokeOpacity: 0.92,
            supersampleFillOpacity: 0.22,
            supersampleStrokeOpacity: 0.98,
            supersampleStrokeWidth: 0.8,
            showCenterLine: true,
            centerLineOpacity: 0.14,
            selectionFill: .rgb(0.95, 0.55, 0.82, opacity: 0.28),
            selectionEdge: .rgb(1.00, 0.72, 0.90),
            loopFill: .rgb(0.55, 0.92, 0.88, opacity: 0.14),
            loopEdge: .rgb(0.55, 0.92, 0.88, opacity: 0.85),
            playhead: .rgb(1.00, 0.72, 0.88),
            playheadOnOnset: .rgb(0.55, 0.92, 0.88),
            onset: .rgb(1.00, 0.72, 0.88, opacity: 0.65),
            onsetActive: .rgb(0.55, 0.92, 0.88, opacity: 0.95),
            onsetPlayhead: .rgb(0.55, 0.92, 0.88),
            onsetActiveGlow: .rgb(0.55, 0.92, 0.88, opacity: 0.45),
            onsetActiveCore: .rgb(0.85, 0.98, 0.96),
            glassTintOpacity: 0.34,
            spectrogram: .stops([
                (0.00, 0.08, 0.06, 0.14),
                (0.20, 0.28, 0.14, 0.48),
                (0.42, 0.42, 0.48, 0.92),
                (0.62, 0.55, 0.88, 0.95),
                (0.82, 0.98, 0.68, 0.88),
                (1.00, 1.00, 0.92, 0.95),
            ])
        )
    )

    /// Smoldering copper on ash.
    static let ember = WaveformColorTheme(
        id: "ember",
        name: "Ember",
        spec: ThemeSpec(
            background: .rgb(0.09, 0.07, 0.06),
            wave: .rgb(0.92, 0.48, 0.28),
            waveFillOpacity: 0.42,
            waveStrokeOpacity: 0.94,
            supersampleFillOpacity: 0.22,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.85,
            showCenterLine: true,
            centerLineOpacity: 0.12,
            selectionFill: .rgb(0.78, 0.38, 0.18, opacity: 0.28),
            selectionEdge: .rgb(0.98, 0.58, 0.32),
            loopFill: .rgb(0.92, 0.62, 0.32, opacity: 0.12),
            loopEdge: .rgb(0.92, 0.62, 0.32, opacity: 0.85),
            playhead: .rgb(0.98, 0.88, 0.72),
            playheadOnOnset: .rgb(1.00, 0.32, 0.12),
            onset: .rgb(0.98, 0.62, 0.28, opacity: 0.68),
            onsetActive: .rgb(1.00, 0.32, 0.12, opacity: 0.95),
            onsetPlayhead: .rgb(1.00, 0.32, 0.12),
            onsetActiveGlow: .rgb(1.00, 0.32, 0.12, opacity: 0.48),
            onsetActiveCore: .rgb(1.00, 0.72, 0.48),
            glassTintOpacity: 0.32,
            spectrogram: .stops([
                (0.00, 0.06, 0.04, 0.03),
                (0.20, 0.28, 0.06, 0.18),
                (0.40, 0.62, 0.18, 0.42),
                (0.58, 0.92, 0.42, 0.22),
                (0.78, 1.00, 0.68, 0.28),
                (1.00, 1.00, 0.92, 0.78),
            ])
        )
    )

    /// Deep violet void, electric violet crest.
    static let ultraviolet = WaveformColorTheme(
        id: "ultraviolet",
        name: "Ultraviolet",
        spec: ThemeSpec(
            background: .rgb(0.05, 0.02, 0.10),
            wave: .rgb(0.72, 0.35, 1.00),
            waveFillOpacity: 0.42,
            waveStrokeOpacity: 0.96,
            supersampleFillOpacity: 0.22,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.85,
            showCenterLine: true,
            centerLineOpacity: 0.14,
            selectionFill: .rgb(0.55, 0.22, 0.95, opacity: 0.34),
            selectionEdge: .rgb(0.78, 0.48, 1.00),
            loopFill: .rgb(0.42, 0.88, 1.00, opacity: 0.12),
            loopEdge: .rgb(0.42, 0.88, 1.00, opacity: 0.88),
            playhead: .rgb(0.42, 0.95, 1.00),
            playheadOnOnset: .rgb(0.92, 0.42, 1.00),
            onset: .rgb(0.42, 0.95, 1.00, opacity: 0.68),
            onsetActive: .rgb(0.92, 0.42, 1.00, opacity: 0.95),
            onsetPlayhead: .rgb(0.92, 0.42, 1.00),
            onsetActiveGlow: .rgb(0.92, 0.42, 1.00, opacity: 0.50),
            onsetActiveCore: .rgb(0.98, 0.78, 1.00),
            glassTintOpacity: 0.36,
            spectrogram: .stops([
                (0.00, 0.03, 0.01, 0.08),
                (0.20, 0.18, 0.04, 0.48),
                (0.42, 0.55, 0.12, 0.88),
                (0.62, 0.72, 0.28, 0.98),
                (0.82, 0.35, 0.82, 1.00),
                (1.00, 0.92, 0.95, 1.00),
            ])
        )
    )

    /// Tropical teal wave, coral accents.
    static let coralReef = WaveformColorTheme(
        id: "coral-reef",
        name: "Coral Reef",
        spec: ThemeSpec(
            background: .rgb(0.03, 0.10, 0.12),
            wave: .rgb(0.18, 0.88, 0.78),
            waveFillOpacity: 0.42,
            waveStrokeOpacity: 0.94,
            supersampleFillOpacity: 0.22,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.8,
            showCenterLine: true,
            centerLineOpacity: 0.14,
            selectionFill: .rgb(1.00, 0.48, 0.42, opacity: 0.28),
            selectionEdge: .rgb(1.00, 0.62, 0.55),
            loopFill: .rgb(0.18, 0.88, 0.78, opacity: 0.12),
            loopEdge: .rgb(0.18, 0.88, 0.78, opacity: 0.88),
            playhead: .rgb(1.00, 0.55, 0.48),
            playheadOnOnset: .rgb(0.18, 0.88, 0.78),
            onset: .rgb(1.00, 0.55, 0.48, opacity: 0.68),
            onsetActive: .rgb(0.18, 0.88, 0.78, opacity: 0.95),
            onsetPlayhead: .rgb(0.18, 0.88, 0.78),
            onsetActiveGlow: .rgb(0.18, 0.88, 0.78, opacity: 0.48),
            onsetActiveCore: .rgb(0.62, 0.98, 0.92),
            glassTintOpacity: 0.34,
            spectrogram: .stops([
                (0.00, 0.02, 0.07, 0.09),
                (0.20, 0.04, 0.28, 0.42),
                (0.42, 0.08, 0.62, 0.58),
                (0.62, 0.18, 0.88, 0.72),
                (0.82, 0.98, 0.55, 0.42),
                (1.00, 1.00, 0.88, 0.72),
            ])
        )
    )

    /// High-contrast graphite with crimson hits.
    static let noir = WaveformColorTheme(
        id: "noir",
        name: "Noir",
        spec: ThemeSpec(
            background: .rgb(0.06, 0.06, 0.06),
            wave: .rgb(0.88, 0.88, 0.88),
            waveFillOpacity: 0.36,
            waveStrokeOpacity: 0.92,
            supersampleFillOpacity: 0.18,
            supersampleStrokeOpacity: 0.98,
            supersampleStrokeWidth: 0.75,
            showCenterLine: true,
            centerLineOpacity: 0.10,
            selectionFill: .rgb(0.85, 0.12, 0.18, opacity: 0.28),
            selectionEdge: .rgb(0.95, 0.22, 0.28),
            loopFill: .rgb(0.88, 0.88, 0.88, opacity: 0.10),
            loopEdge: .rgb(0.88, 0.88, 0.88, opacity: 0.80),
            playhead: .rgb(0.95, 0.18, 0.22),
            playheadOnOnset: .rgb(1.00, 0.92, 0.92),
            onset: .rgb(0.95, 0.18, 0.22, opacity: 0.68),
            onsetActive: .rgb(1.00, 0.92, 0.92, opacity: 0.95),
            onsetPlayhead: .rgb(1.00, 0.92, 0.92),
            onsetActiveGlow: .rgb(0.95, 0.18, 0.22, opacity: 0.45),
            onsetActiveCore: .rgb(1.00, 0.72, 0.72),
            glassTintOpacity: 0.30,
            spectrogram: .stops([
                (0.00, 0.04, 0.04, 0.04),
                (0.22, 0.18, 0.14, 0.14),
                (0.45, 0.42, 0.32, 0.32),
                (0.65, 0.72, 0.48, 0.48),
                (0.82, 0.95, 0.22, 0.28),
                (1.00, 1.00, 0.88, 0.88),
            ])
        )
    )

    /// Hot pink ↔ electric blue fusion.
    static let plasma = WaveformColorTheme(
        id: "plasma",
        name: "Plasma",
        spec: ThemeSpec(
            background: .rgb(0.05, 0.03, 0.10),
            wave: .rgb(1.00, 0.28, 0.72),
            waveFillOpacity: 0.42,
            waveStrokeOpacity: 0.96,
            supersampleFillOpacity: 0.22,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.85,
            showCenterLine: true,
            centerLineOpacity: 0.14,
            selectionFill: .rgb(0.28, 0.48, 1.00, opacity: 0.34),
            selectionEdge: .rgb(0.48, 0.68, 1.00),
            loopFill: .rgb(1.00, 0.28, 0.72, opacity: 0.14),
            loopEdge: .rgb(1.00, 0.28, 0.72, opacity: 0.88),
            playhead: .rgb(0.42, 0.82, 1.00),
            playheadOnOnset: .rgb(1.00, 0.55, 0.22),
            onset: .rgb(0.42, 0.82, 1.00, opacity: 0.68),
            onsetActive: .rgb(1.00, 0.55, 0.22, opacity: 0.95),
            onsetPlayhead: .rgb(1.00, 0.55, 0.22),
            onsetActiveGlow: .rgb(1.00, 0.55, 0.22, opacity: 0.48),
            onsetActiveCore: .rgb(1.00, 0.82, 0.48),
            glassTintOpacity: 0.36,
            spectrogram: .stops([
                (0.00, 0.04, 0.02, 0.08),
                (0.20, 0.18, 0.06, 0.55),
                (0.42, 0.55, 0.12, 0.92),
                (0.62, 0.98, 0.22, 0.72),
                (0.82, 0.42, 0.78, 1.00),
                (1.00, 0.95, 0.95, 1.00),
            ])
        )
    )

    /// Dense canopy greens, moss and leaf.
    static let forest = WaveformColorTheme(
        id: "forest",
        name: "Forest",
        spec: ThemeSpec(
            background: .rgb(0.04, 0.08, 0.05),
            wave: .rgb(0.42, 0.88, 0.48),
            waveFillOpacity: 0.42,
            waveStrokeOpacity: 0.94,
            supersampleFillOpacity: 0.22,
            supersampleStrokeOpacity: 1.0,
            supersampleStrokeWidth: 0.8,
            showCenterLine: true,
            centerLineOpacity: 0.12,
            selectionFill: .rgb(0.28, 0.62, 0.38, opacity: 0.30),
            selectionEdge: .rgb(0.48, 0.85, 0.55),
            loopFill: .rgb(0.72, 0.88, 0.32, opacity: 0.12),
            loopEdge: .rgb(0.72, 0.88, 0.32, opacity: 0.85),
            playhead: .rgb(0.95, 0.88, 0.42),
            playheadOnOnset: .rgb(0.42, 0.88, 0.48),
            onset: .rgb(0.95, 0.88, 0.42, opacity: 0.65),
            onsetActive: .rgb(0.42, 0.88, 0.48, opacity: 0.95),
            onsetPlayhead: .rgb(0.42, 0.88, 0.48),
            onsetActiveGlow: .rgb(0.42, 0.88, 0.48, opacity: 0.45),
            onsetActiveCore: .rgb(0.72, 0.98, 0.72),
            glassTintOpacity: 0.32,
            spectrogram: .stops([
                (0.00, 0.02, 0.05, 0.03),
                (0.20, 0.06, 0.22, 0.12),
                (0.42, 0.12, 0.55, 0.22),
                (0.62, 0.32, 0.82, 0.35),
                (0.82, 0.88, 0.92, 0.28),
                (1.00, 0.98, 0.95, 0.72),
            ])
        )
    )

    private init(id: String, name: String, spec: ThemeSpec) {
        self.id = id
        self.name = name
        self.spec = spec
    }

    // MARK: - Spec

    private struct ThemeSpec: Equatable {
        enum Background: Equatable {
            case system
            case rgb(Double, Double, Double)
        }

        enum Wave: Equatable {
            case accent
            case rgb(Double, Double, Double)
        }

        enum ColorRef: Equatable {
            case accent(opacity: Double = 1)
            case rgb(Double, Double, Double, opacity: Double = 1)

            func color(accent: Color) -> Color {
                switch self {
                case .accent(let opacity):
                    return accent.opacity(opacity)
                case .rgb(let r, let g, let b, let opacity):
                    return Color(red: r, green: g, blue: b, opacity: opacity)
                }
            }
        }

        var background: Background
        var wave: Wave
        var waveFillOpacity: Double
        var waveStrokeOpacity: Double
        var supersampleFillOpacity: Double
        var supersampleStrokeOpacity: Double
        var supersampleStrokeWidth: CGFloat
        var showCenterLine: Bool
        var centerLineOpacity: Double
        var selectionFill: ColorRef
        var selectionEdge: ColorRef
        var loopFill: ColorRef
        var loopEdge: ColorRef
        var playhead: ColorRef
        var playheadOnOnset: ColorRef
        var onset: ColorRef
        var onsetActive: ColorRef
        var onsetPlayhead: ColorRef
        var onsetActiveGlow: ColorRef
        var onsetActiveCore: ColorRef
        var glassTintOpacity: Double
        var spectrogram: SpectrogramColormap

        static let system = ThemeSpec(
            background: .system,
            wave: .accent,
            waveFillOpacity: 0.48,
            waveStrokeOpacity: 0.90,
            supersampleFillOpacity: 0.28,
            supersampleStrokeOpacity: 0.98,
            supersampleStrokeWidth: 0.75,
            showCenterLine: false,
            centerLineOpacity: 0,
            selectionFill: .accent(opacity: 0.22),
            selectionEdge: .accent(opacity: 0.9),
            loopFill: .rgb(0, 0.75, 0.2, opacity: 0.12),
            loopEdge: .rgb(0, 0.75, 0.2, opacity: 0.8),
            playhead: .rgb(0.95, 0.15, 0.15, opacity: 0.9),
            playheadOnOnset: .rgb(1, 0.55, 0, opacity: 1),
            onset: .rgb(1, 0.55, 0, opacity: 0.7),
            onsetActive: .rgb(1, 0.55, 0, opacity: 0.95),
            onsetPlayhead: .rgb(1, 0.55, 0, opacity: 1),
            onsetActiveGlow: .rgb(1, 0.55, 0, opacity: 0.55),
            onsetActiveCore: .rgb(1, 0.92, 0.45),
            glassTintOpacity: 0.28,
            spectrogram: .stops([
                (0.00, 0.06, 0.07, 0.10),
                (0.22, 0.08, 0.18, 0.42),
                (0.48, 0.18, 0.48, 0.78),
                (0.70, 0.45, 0.72, 0.95),
                (0.88, 0.85, 0.55, 0.82),
                (1.00, 0.98, 0.92, 0.95),
            ])
        )

        func resolved() -> ResolvedWaveformTheme {
            let accent = Color.accentColor
            let bg: Color = {
                switch background {
                case .system: return Color(nsColor: .textBackgroundColor)
                case .rgb(let r, let g, let b): return Color(red: r, green: g, blue: b)
                }
            }()
            let waveColor: Color = {
                switch wave {
                case .accent: return accent
                case .rgb(let r, let g, let b): return Color(red: r, green: g, blue: b)
                }
            }()

            return ResolvedWaveformTheme(
                background: bg,
                waveFill: waveColor,
                waveStroke: waveColor,
                waveFillOpacity: waveFillOpacity,
                waveStrokeOpacity: waveStrokeOpacity,
                supersampleFillOpacity: supersampleFillOpacity,
                supersampleStrokeOpacity: supersampleStrokeOpacity,
                supersampleStrokeWidth: supersampleStrokeWidth,
                showCenterLine: showCenterLine,
                centerLineOpacity: centerLineOpacity,
                selectionFill: selectionFill.color(accent: accent),
                selectionEdge: selectionEdge.color(accent: accent),
                loopFill: loopFill.color(accent: accent),
                loopEdge: loopEdge.color(accent: accent),
                playhead: playhead.color(accent: accent),
                playheadOnOnset: playheadOnOnset.color(accent: accent),
                onset: onset.color(accent: accent),
                onsetActive: onsetActive.color(accent: accent),
                onsetPlayhead: onsetPlayhead.color(accent: accent),
                onsetActiveGlow: onsetActiveGlow.color(accent: accent),
                onsetActiveCore: onsetActiveCore.color(accent: accent),
                glassTintOpacity: glassTintOpacity,
                spectrogramColormap: spectrogram
            )
        }
    }
}

extension SpectrogramColormap {
    static func stops(_ values: [(Double, Double, Double, Double)]) -> SpectrogramColormap {
        SpectrogramColormap(stops: values.map { Stop(t: $0.0, r: $0.1, g: $0.2, b: $0.3) })
    }
}

/// Small swatch for the theme picker menu.
struct WaveformThemeSwatch: View {
    let theme: WaveformColorTheme

    var body: some View {
        let resolved = theme.resolved()
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(resolved.background)
                .frame(width: 14, height: 10)
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                }
            RoundedRectangle(cornerRadius: 1)
                .fill(resolved.waveFill.opacity(resolved.waveFillOpacity + 0.3))
                .frame(width: 10, height: 10)
            spectrogramStrip(resolved.spectrogramColormap)
                .frame(width: 14, height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
        }
    }

    private func spectrogramStrip(_ map: SpectrogramColormap) -> some View {
        Canvas { ctx, size in
            let steps = max(1, Int(size.width))
            let w = size.width / CGFloat(steps)
            for i in 0..<steps {
                let t = Double(i) / Double(max(steps - 1, 1))
                let rgb = map.rgb(at: t)
                let rect = CGRect(x: CGFloat(i) * w, y: 0, width: w + 0.5, height: size.height)
                ctx.fill(Path(rect), with: .color(Color(red: rgb.red, green: rgb.green, blue: rgb.blue)))
            }
        }
    }
}
