import SwiftUI

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
            glassTintOpacity: 0.32
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
            glassTintOpacity: 0.34
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
            glassTintOpacity: 0.30
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
            glassTintOpacity: 0.32
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
            glassTintOpacity: 0.34
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
            glassTintOpacity: 0.32
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
            glassTintOpacity: 0.28
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
            glassTintOpacity: 0.28
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
                glassTintOpacity: glassTintOpacity
            )
        }
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
        }
    }
}
