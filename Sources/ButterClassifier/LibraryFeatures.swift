import Foundation

/// Compact scalars + glyph frames for the Library finder (LUP feature index subset).
enum LibraryFeatures {
    static let glyphFrameCount = 16

    struct GlyphFrame {
        var radius: Double
        var pitch: Double
    }

    static func apply(to sample: SampleFile, from result: AnalysisResult) {
        let dur = result.duration ?? 0
        sample.libDurN = min(1, dur / 12)
        sample.libPitch = pitchScalar(result)
        sample.libBright = brightnessScalar(result)
        sample.libEnergy = energyScalar(result)

        let glyphs = computeGlyphs(result)
        sample.glyphRadii = glyphs.map(\.radius)
        sample.glyphPitch = glyphs.map(\.pitch)
    }

    static func pitchScalar(_ r: AnalysisResult) -> Double {
        if let ps = r.pitchSalience, ps > 0 {
            return min(1, max(0, ps / 100))
        }
        if let k = r.kickiness {
            return min(1, max(0, 1 - k / 100))
        }
        return 0.5
    }

    static func brightnessScalar(_ r: AnalysisResult) -> Double {
        guard !r.spectralCentroids.isEmpty else { return 0.5 }
        let mean = r.spectralCentroids.reduce(0, +) / Double(r.spectralCentroids.count)
        // Map ~200–8000 Hz centroid to 0–1
        let norm = (log(max(1, mean)) - log(200)) / (log(8000) - log(200))
        return min(1, max(0, norm))
    }

    static func energyScalar(_ r: AnalysisResult) -> Double {
        if !r.rms.isEmpty {
            let mean = r.rms.reduce(0, +) / Double(r.rms.count)
            return min(1, max(0, mean * 4))
        }
        if let lufs = r.loudnessLUFS {
            return min(1, max(0, (lufs + 40) / 40))
        }
        return 0.3
    }

    static func computeGlyphs(_ r: AnalysisResult) -> [GlyphFrame] {
        let n = glyphFrameCount
        let rms = r.rms
        let cents = r.spectralCentroids
        guard !rms.isEmpty else {
            return (0..<n).map { _ in GlyphFrame(radius: 0.15, pitch: pitchScalar(r)) }
        }

        let step = max(1, rms.count / n)
        var frames: [GlyphFrame] = []
        frames.reserveCapacity(n)
        var maxR: Double = 0.001

        for i in 0..<n {
            let start = min(i * step, rms.count - 1)
            let end = min(start + step, rms.count)
            let slice = rms[start..<end]
            let rVal = slice.max() ?? slice.first ?? 0
            maxR = max(maxR, rVal)

            let cStart = min(i * step, max(0, cents.count - 1))
            let cEnd = min(cStart + step, cents.count)
            let cSlice = cents.isEmpty ? [] : Array(cents[cStart..<cEnd])
            let cMean = cSlice.isEmpty ? 2000 : cSlice.reduce(0, +) / Double(cSlice.count)
            let pVal = min(1, max(0, (log(max(1, cMean)) - log(200)) / (log(8000) - log(200))))

            frames.append(GlyphFrame(radius: rVal, pitch: pVal))
        }

        return frames.map { f in
            GlyphFrame(radius: min(1, max(0.05, f.radius / maxR)), pitch: f.pitch)
        }
    }

    /// Neutral index for files without analysis YAML (still shown in the library).
    static func applyDefaults(to sample: SampleFile) {
        let dur = sample.duration ?? 0
        sample.libDurN = dur > 0 ? min(1, dur / 12) : 0.5
        sample.libPitch = 0.5
        sample.libBright = 0.5
        sample.libEnergy = 0.35
        sample.glyphRadii = Array(repeating: 0.22, count: glyphFrameCount)
        sample.glyphPitch = Array(repeating: 0.5, count: glyphFrameCount)
    }

    static func ensureIndexed(_ samples: [SampleFile]) {
        for sample in samples where needsIndexing(sample) {
            ensureIndexedSync(sample)
        }
    }

    static func ensureIndexed(_ sample: SampleFile) {
        guard needsIndexing(sample) else { return }
        ensureIndexedSync(sample)
    }

    static func ensureIndexedAsync(_ samples: [SampleFile]) async {
        var processed = 0
        for sample in samples {
            guard needsIndexing(sample) else { continue }
            if sample.isAnalyzed {
                let yamlURL = sample.yamlURL
                let loaded = await Task.detached(priority: .utility) {
                    AnalysisResult.load(from: yamlURL, mode: .index)
                }.value
                if let result = loaded {
                    await MainActor.run {
                        apply(to: sample, from: result)
                    }
                }
            } else {
                await MainActor.run {
                    applyDefaults(to: sample)
                }
            }
            processed += 1
            if processed.isMultiple(of: 10) {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }

    private static func needsIndexing(_ sample: SampleFile) -> Bool {
        sample.glyphRadii.count != glyphFrameCount || sample.libPitch == nil
    }

    private static func ensureIndexedSync(_ sample: SampleFile) {
        if sample.isAnalyzed, let result = AnalysisResult.load(from: sample.yamlURL, mode: .index) {
            apply(to: sample, from: result)
        } else {
            applyDefaults(to: sample)
        }
    }

    /// oklch hue from normalized pitch (LUP Tj coloring).
    static func color(forPitch pitch: Double, grey: Bool = false) -> (red: Double, green: Double, blue: Double) {
        if grey { return (0.55, 0.55, 0.55) }
        let hue = 250 - 220 * min(1, max(0, pitch))
        return hslToRgb(h: hue / 360, s: 0.15, l: 0.72)
    }

    private static func hslToRgb(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue2rgb(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1/6 { return p + (q - p) * 6 * t }
            if t < 1/2 { return q }
            if t < 2/3 { return p + (q - p) * (2/3 - t) * 6 }
            return p
        }
        return (hue2rgb(h + 1/3), hue2rgb(h), hue2rgb(h - 1/3))
    }
}
