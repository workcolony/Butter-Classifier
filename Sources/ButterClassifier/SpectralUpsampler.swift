import Foundation

enum SpectralUpsampler {
    static let displayFrames = WaveformLoader.canonicalBins

    static func upsample(_ raw: CachedSpectralData, duration: Double?) -> CachedSpectralData {
        let sourceFrames = max(
            raw.chroma.count,
            raw.rms.count,
            raw.spectralCentroids.count,
            raw.chromaSmooth.count
        )
        guard sourceFrames > 1 else { return raw }

        let target = displayFrames
        if sourceFrames >= target {
            return truncate(raw, to: target)
        }

        return CachedSpectralData(
            duration: duration ?? raw.duration,
            rms: upsample1D(raw.rms, sourceFrames: sourceFrames, to: target),
            spectralCentroids: upsample1D(raw.spectralCentroids, sourceFrames: sourceFrames, to: target),
            chroma: upsampleChroma(raw.chroma, sourceFrames: sourceFrames, to: target),
            chromaSmooth: upsampleSmooth(raw.chromaSmooth, sourceFrames: sourceFrames, to: target)
        )
    }

    private static func truncate(_ raw: CachedSpectralData, to count: Int) -> CachedSpectralData {
        CachedSpectralData(
            duration: raw.duration,
            rms: Array(raw.rms.prefix(count)),
            spectralCentroids: Array(raw.spectralCentroids.prefix(count)),
            chroma: Array(raw.chroma.prefix(count)),
            chromaSmooth: Array(raw.chromaSmooth.prefix(count))
        )
    }

    private static func upsample1D(_ values: [Double], sourceFrames: Int, to count: Int) -> [Double] {
        guard !values.isEmpty else { return Array(repeating: 0, count: count) }
        if values.count == 1 { return Array(repeating: values[0], count: count) }
        return (0..<count).map { sample(values, sourceFrames: sourceFrames, index: $0, target: count) }
    }

    private static func upsampleChroma(_ chroma: [[Double]], sourceFrames: Int, to count: Int) -> [[Double]] {
        guard !chroma.isEmpty else { return [] }
        let rows = 12
        return (0..<count).map { frame in
            (0..<rows).map { pitch in
                let source = chroma.map { row in
                    pitch < row.count ? row[pitch] : 0
                }
                return sample(source, sourceFrames: sourceFrames, index: frame, target: count)
            }
        }
    }

    private static func upsampleSmooth(
        _ frames: [(hue: Double, saturation: Double, lightness: Double)],
        sourceFrames: Int,
        to count: Int
    ) -> [(hue: Double, saturation: Double, lightness: Double)] {
        guard !frames.isEmpty else { return [] }
        if frames.count == 1 {
            return Array(repeating: frames[0], count: count)
        }
        return (0..<count).map { i in
            let pos = Double(i) / Double(max(1, count - 1)) * Double(sourceFrames - 1)
            let idx = min(Int(pos), sourceFrames - 2)
            let frac = pos - Double(idx)
            let a = frames[idx]
            let b = frames[min(idx + 1, frames.count - 1)]
            return (
                hue: a.hue * (1 - frac) + b.hue * frac,
                saturation: a.saturation * (1 - frac) + b.saturation * frac,
                lightness: a.lightness * (1 - frac) + b.lightness * frac
            )
        }
    }

    private static func sample(_ values: [Double], sourceFrames: Int, index: Int, target: Int) -> Double {
        let pos = Double(index) / Double(max(1, target - 1)) * Double(sourceFrames - 1)
        let idx = min(Int(pos), values.count - 2)
        let frac = pos - Double(idx)
        return values[idx] * (1 - frac) + values[idx + 1] * frac
    }
}
