import Foundation
import AVFoundation

/// Mel-scaled spectrogram computed with the Resonate resonator bank
/// (François, ICMC 2025 — EWMA resonators, no FFT buffering).
struct SpectrogramData: Equatable {
    var duration: Double
    var sampleRate: Double
    var bandCount: Int
    var frameCount: Int
    var hopSamples: Int
    /// Power in dB, row-major `[frame * bandCount + band]`. Band 0 = lowest Mel.
    var powersDB: [Float]
    var minDB: Float
    var maxDB: Float

    static let empty = SpectrogramData(
        duration: 0,
        sampleRate: 44_100,
        bandCount: 0,
        frameCount: 0,
        hopSamples: 512,
        powersDB: [],
        minDB: -80,
        maxDB: 0
    )

    var isEmpty: Bool { frameCount == 0 || bandCount == 0 || powersDB.isEmpty }

    func powerDB(frame: Int, band: Int) -> Float {
        guard frame >= 0, frame < frameCount, band >= 0, band < bandCount else { return minDB }
        return powersDB[frame * bandCount + band]
    }
}

enum ResonateSpectrogram {
    /// Mel bands across the audible range (paper used ~84–112 geometric resonators).
    static let defaultBandCount = 96
    /// Native hop before display upsampling (~5.8 ms at 44.1 kHz).
    static let defaultHopSamples = 256
    /// Coarser hop for long clips; still upsampled for drawing.
    static let longFileHopSamples = 512
    static let longFileSeconds: Double = 90
    static let fMinHz: Double = 32.7
    static let fMaxCapHz: Double = 16_000
    /// Floor relative to peak power when converting to dB.
    static let dynamicRangeDB: Float = 80
    /// Match chroma/glass temporal density for zoom.
    static let displayFrames = WaveformLoader.canonicalBins

    static func compute(url: URL) throws -> SpectrogramData {
        let decoded = try decodeMono(url: url)
        guard decoded.frameCount > 0 else { return .empty }

        let duration = Double(decoded.frameCount) / decoded.sampleRate
        let hop = duration > longFileSeconds ? longFileHopSamples : defaultHopSamples
        let fMax = min(fMaxCapHz, decoded.sampleRate * 0.5 * 0.98)
        let frequencies = melFrequencies(
            count: defaultBandCount,
            fMin: fMinHz,
            fMax: fMax
        )
        let native = resonate(
            samples: decoded.samples,
            sampleRate: decoded.sampleRate,
            frequencies: frequencies,
            hopSamples: hop
        )
        return upsample(native, to: displayFrames)
    }

    /// Linearly upsample time axis so zoom has chroma-like density.
    static func upsample(_ data: SpectrogramData, to targetFrames: Int) -> SpectrogramData {
        guard !data.isEmpty, targetFrames > 1 else { return data }
        if data.frameCount >= targetFrames { return data }

        let bands = data.bandCount
        let sourceFrames = data.frameCount
        var powers = [Float](repeating: data.minDB, count: targetFrames * bands)

        for frame in 0..<targetFrames {
            let pos = Double(frame) / Double(targetFrames - 1) * Double(sourceFrames - 1)
            let i0 = min(sourceFrames - 2, max(0, Int(floor(pos))))
            let i1 = i0 + 1
            let frac = Float(pos - Double(i0))
            let base0 = i0 * bands
            let base1 = i1 * bands
            let out = frame * bands
            for band in 0..<bands {
                let a = data.powersDB[base0 + band]
                let b = data.powersDB[base1 + band]
                powers[out + band] = a + frac * (b - a)
            }
        }

        return SpectrogramData(
            duration: data.duration,
            sampleRate: data.sampleRate,
            bandCount: bands,
            frameCount: targetFrames,
            hopSamples: data.hopSamples,
            powersDB: powers,
            minDB: data.minDB,
            maxDB: data.maxDB
        )
    }

    // MARK: - Mel scale (HTK)

    static func hzToMel(_ hz: Double) -> Double {
        2595.0 * log10(1.0 + hz / 700.0)
    }

    static func melToHz(_ mel: Double) -> Double {
        700.0 * (pow(10.0, mel / 2595.0) - 1.0)
    }

    static func melFrequencies(count: Int, fMin: Double, fMax: Double) -> [Double] {
        guard count > 0, fMax > fMin else { return [] }
        let melMin = hzToMel(fMin)
        let melMax = hzToMel(fMax)
        if count == 1 { return [melToHz((melMin + melMax) * 0.5)] }
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            return melToHz(melMin + t * (melMax - melMin))
        }
    }

    // MARK: - Resonate bank

    /// Per-sample resonator update from François Eq. 5 + smoothing Eq. 8.
    private static func resonate(
        samples: [Float],
        sampleRate: Double,
        frequencies: [Double],
        hopSamples: Int
    ) -> SpectrogramData {
        let n = frequencies.count
        let frameCount = samples.count
        guard n > 0, frameCount > 0, sampleRate > 0 else { return .empty }

        let hop = max(1, hopSamples)
        let outFrames = (frameCount + hop - 1) / hop
        let dt = 1.0 / sampleRate

        var pr = [Float](repeating: 1, count: n) // phasor real (starts at e^0 = 1)
        var pi = [Float](repeating: 0, count: n)
        var rr = [Float](repeating: 0, count: n) // R real
        var ri = [Float](repeating: 0, count: n)
        var sr = [Float](repeating: 0, count: n) // smoothed R̃ real
        var si = [Float](repeating: 0, count: n)

        var alpha = [Float](repeating: 0, count: n)
        var cosD = [Float](repeating: 0, count: n)
        var sinD = [Float](repeating: 0, count: n)
        var oneMinus = [Float](repeating: 0, count: n)

        for k in 0..<n {
            let f = max(1.0, frequencies[k])
            // τ_f = ln(1+f)/f  →  α = 1 − e^{−Δt/τ}
            let tau = log(1.0 + f) / f
            let a = Float(1.0 - exp(-dt / tau))
            alpha[k] = a
            oneMinus[k] = 1 - a
            let theta = 2.0 * Double.pi * f * dt
            cosD[k] = Float(cos(theta))
            sinD[k] = Float(sin(theta))
        }

        var powers = [Float](repeating: 0, count: outFrames * n)
        var hopSum = [Float](repeating: 0, count: n)
        var hopCount = 0
        var globalMax: Float = 1e-20
        var outFrame = 0

        for t in 0..<frameCount {
            let x = samples[t]
            for k in 0..<n {
                // P ← P · e^{−iωΔt}
                let pre = pr[k]
                let pim = pi[k]
                let c = cosD[k]
                let s = sinD[k]
                let npre = pre * c + pim * s
                let npim = pim * c - pre * s
                pr[k] = npre
                pi[k] = npim

                // R ← (1−α)R + α x P
                let a = alpha[k]
                let om = oneMinus[k]
                let nrr = om * rr[k] + a * x * npre
                let nri = om * ri[k] + a * x * npim
                rr[k] = nrr
                ri[k] = nri

                // R̃ ← (1−α)R̃ + α R
                sr[k] = om * sr[k] + a * nrr
                si[k] = om * si[k] + a * nri

                // Accumulate linear power over the hop (mean), not a single snapshot.
                // Instantaneous |R̃|² flashes broadband on every transient and paints
                // false vertical bands compared to a windowed Mel STFT.
                hopSum[k] += sr[k] * sr[k] + si[k] * si[k]
            }
            hopCount += 1

            if hopCount == hop || t == frameCount - 1 {
                let base = outFrame * n
                let inv = 1.0 / Float(max(hopCount, 1))
                for k in 0..<n {
                    let p = hopSum[k] * inv
                    powers[base + k] = p
                    if p > globalMax { globalMax = p }
                    hopSum[k] = 0
                }
                hopCount = 0
                outFrame += 1
                if outFrame >= outFrames { break }
            }
        }

        // Convert linear power → dB relative to peak (paper spectrogram convention).
        let peak = max(globalMax, 1e-20)
        let minDB = -dynamicRangeDB
        var maxDB: Float = minDB
        for i in 0..<outFrame * n {
            let db = 10 * log10(Double(powers[i] / peak) + 1e-20)
            let clipped = Float(max(Double(minDB), min(0, db)))
            powers[i] = clipped
            if clipped > maxDB { maxDB = clipped }
        }
        if maxDB <= minDB { maxDB = 0 }

        // Light temporal smooth per band (3-tap) to calm residual hop-edge striping
        // without erasing real rhythmic structure.
        if outFrame >= 3 {
            var smoothed = [Float](repeating: minDB, count: outFrame * n)
            for k in 0..<n {
                smoothed[k] = powers[k]
                smoothed[(outFrame - 1) * n + k] = powers[(outFrame - 1) * n + k]
            }
            for f in 1..<(outFrame - 1) {
                let prev = (f - 1) * n
                let cur = f * n
                let next = (f + 1) * n
                for k in 0..<n {
                    smoothed[cur + k] = 0.25 * powers[prev + k]
                        + 0.50 * powers[cur + k]
                        + 0.25 * powers[next + k]
                }
            }
            powers = smoothed
            maxDB = powers.prefix(outFrame * n).max() ?? 0
        }

        return SpectrogramData(
            duration: Double(frameCount) / sampleRate,
            sampleRate: sampleRate,
            bandCount: n,
            frameCount: outFrame,
            hopSamples: hop,
            powersDB: Array(powers.prefix(outFrame * n)),
            minDB: minDB,
            maxDB: maxDB
        )
    }

    // MARK: - Decode

    private struct DecodedMono {
        var samples: [Float]
        var frameCount: Int
        var sampleRate: Double
    }

    private static func decodeMono(url: URL) throws -> DecodedMono {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            return DecodedMono(samples: [], frameCount: 0, sampleRate: format.sampleRate)
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            return DecodedMono(samples: [], frameCount: 0, sampleRate: format.sampleRate)
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)

        if channelCount == 1 {
            memcpy(&mono, channels[0], frameCount * MemoryLayout<Float>.size)
        } else {
            let scale = 1.0 / Float(channelCount)
            for frame in 0..<frameCount {
                var sample: Float = 0
                for ch in 0..<channelCount {
                    sample += channels[ch][frame]
                }
                mono[frame] = sample * scale
            }
        }

        return DecodedMono(samples: mono, frameCount: frameCount, sampleRate: format.sampleRate)
    }
}
