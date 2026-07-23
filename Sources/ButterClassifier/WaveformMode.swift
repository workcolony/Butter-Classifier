import Foundation

/// LUP-style waveform renderers (Phase 3).
enum WaveformMode: String, CaseIterable, Identifiable {
    case original
    case supersample
    case glass
    case chromagram
    case ribbon
    case spectrogram

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original"
        case .supersample: return "Supersample"
        case .glass: return "Glass"
        case .chromagram: return "Chroma"
        case .ribbon: return "Ribbon"
        case .spectrogram: return "Spectrogram"
        }
    }

    /// Compact segmented-control labels (avoids toolbar wrap thrash).
    var shortLabel: String {
        switch self {
        case .original: return "Orig"
        case .supersample: return "Super"
        case .glass: return "Glass"
        case .chromagram: return "Chroma"
        case .ribbon: return "Ribbon"
        case .spectrogram: return "Spec"
        }
    }

    var needsAnalysis: Bool {
        switch self {
        case .original, .supersample, .spectrogram: return false
        case .glass, .chromagram, .ribbon: return true
        }
    }

    /// Mel spectrogram is computed on-demand from audio (Accelerate STFT), not from YAML.
    var needsSpectrogram: Bool {
        self == .spectrogram
    }

    var waveformBins: Int {
        switch self {
        case .original: return WaveformLoader.displayBins
        case .supersample: return WaveformLoader.canonicalBins
        default: return WaveformLoader.displayBins
        }
    }

    /// Original = subsampled view; supersample = full canonical resolution.
    var usesCanonicalWaveform: Bool {
        self == .original || self == .supersample
    }
}

struct WaveformDrawStats: Equatable {
    var chromaMax: Double = 1
    var rmsMax: Double = 1
    var centroidMin: Double = 0
    var centroidMax: Double = 1
}

/// Everything needed to draw any waveform mode for one sample.
struct WaveformRenderModel: Equatable {
    var duration: Double
    var waveform: WaveformData
    var rms: [Double]
    var spectralCentroids: [Double]
    /// One frame per analysis hop; each frame has 12 pitch-class values.
    var chroma: [[Double]]
    /// HSL tuples aligned with chroma frames (hue 0–360).
    var chromaSmooth: [(hue: Double, saturation: Double, lightness: Double)]
    var spectrogram: SpectrogramData
    var drawStats: WaveformDrawStats

    static let empty = WaveformRenderModel(
        duration: 0,
        waveform: .empty,
        rms: [],
        spectralCentroids: [],
        chroma: [],
        chromaSmooth: [],
        spectrogram: .empty,
        drawStats: WaveformDrawStats()
    )

    var hasSpectralData: Bool {
        !rms.isEmpty || !chroma.isEmpty
    }

    var hasSpectrogramData: Bool {
        !spectrogram.isEmpty
    }

    static func == (lhs: WaveformRenderModel, rhs: WaveformRenderModel) -> Bool {
        lhs.duration == rhs.duration
            && lhs.waveform == rhs.waveform
            && lhs.drawStats == rhs.drawStats
            && lhs.rms.count == rhs.rms.count
            && lhs.spectralCentroids.count == rhs.spectralCentroids.count
            && lhs.chroma.count == rhs.chroma.count
            && lhs.chromaSmooth.count == rhs.chromaSmooth.count
            && lhs.spectrogram.frameCount == rhs.spectrogram.frameCount
            && lhs.spectrogram.bandCount == rhs.spectrogram.bandCount
            && lhs.spectrogram.hopSamples == rhs.spectrogram.hopSamples
            && lhs.spectrogram.duration == rhs.spectrogram.duration
            && lhs.spectrogram.minDB == rhs.spectrogram.minDB
            && lhs.spectrogram.maxDB == rhs.spectrogram.maxDB
    }

    static func loadWaveformOnly(url: URL, mode: WaveformMode) async -> WaveformRenderModel {
        let waveform = await WaveformCache.shared.waveform(for: url, mode: mode)
        let duration = waveform.duration > 0 ? waveform.duration : 0
        return WaveformRenderModel(
            duration: duration,
            waveform: waveform,
            rms: [],
            spectralCentroids: [],
            chroma: [],
            chromaSmooth: [],
            spectrogram: .empty,
            drawStats: WaveformDrawStats()
        )
    }

    static func loadSpectrogram(url: URL) async -> WaveformRenderModel {
        async let waveformTask = WaveformCache.shared.waveform(for: url, mode: .spectrogram)
        async let spectrogramTask = WaveformCache.shared.spectrogram(for: url)
        let waveform = await waveformTask
        let spectrogram = await spectrogramTask ?? .empty
        let duration = waveform.duration > 0 ? waveform.duration : 0
        let resolvedDuration = spectrogram.duration > 0 ? spectrogram.duration : duration
        return WaveformRenderModel(
            duration: resolvedDuration,
            waveform: waveform,
            rms: [],
            spectralCentroids: [],
            chroma: [],
            chromaSmooth: [],
            spectrogram: spectrogram,
            drawStats: WaveformDrawStats()
        )
    }

    static func load(
        url: URL,
        yamlURL: URL,
        mode: WaveformMode,
        isAnalyzed: Bool
    ) async -> WaveformRenderModel {
        if mode == .spectrogram {
            return await loadSpectrogram(url: url)
        }

        let waveform = await WaveformCache.shared.waveform(for: url, mode: mode)
        let duration = waveform.duration > 0 ? waveform.duration : 0

        guard isAnalyzed, let spectral = await WaveformCache.shared.spectral(for: yamlURL, audioURL: url) else {
            return WaveformRenderModel(
                duration: duration,
                waveform: waveform,
                rms: [],
                spectralCentroids: [],
                chroma: [],
                chromaSmooth: [],
                spectrogram: .empty,
                drawStats: WaveformDrawStats()
            )
        }

        let resolvedDuration = spectral.duration ?? duration
        let drawStats = makeDrawStats(
            rms: spectral.rms,
            spectralCentroids: spectral.spectralCentroids,
            chroma: spectral.chroma
        )
        return WaveformRenderModel(
            duration: resolvedDuration,
            waveform: waveform,
            rms: spectral.rms,
            spectralCentroids: spectral.spectralCentroids,
            chroma: spectral.chroma,
            chromaSmooth: spectral.chromaSmooth,
            spectrogram: .empty,
            drawStats: drawStats
        )
    }

    private static func makeDrawStats(
        rms: [Double],
        spectralCentroids: [Double],
        chroma: [[Double]]
    ) -> WaveformDrawStats {
        var stats = WaveformDrawStats()
        stats.chromaMax = chroma.flatMap { $0 }.max() ?? 1
        stats.rmsMax = rms.max() ?? 1
        stats.centroidMin = spectralCentroids.min() ?? 0
        stats.centroidMax = spectralCentroids.max() ?? 1
        if stats.centroidMax <= stats.centroidMin {
            stats.centroidMax = stats.centroidMin + 1
        }
        return stats
    }
}
