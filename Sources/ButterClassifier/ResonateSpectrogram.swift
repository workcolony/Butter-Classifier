import Foundation

// MOTHBALLED 2026-07-23 — kept for reference while Mel STFT is the live path.
// Active compute: `STFTSpectrogram.compute`. Do not wire this back into WaveformCache
// unless intentionally A/B testing against François ICMC 2025 Resonate.
// Paper: docs/FrancoisARJ-ICMC2025.pdf

/// Mel-scaled spectrogram computed with the Resonate resonator bank
/// (François, ICMC 2025 — EWMA resonators, no FFT buffering).
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

    static func compute(url: URL) throws -> SpectrogramData {
        let decoded = try SpectrogramSupport.decodeMono(url: url)
        guard decoded.frameCount > 0 else { return .empty }

        let duration = Double(decoded.frameCount) / decoded.sampleRate
        let hop = duration > longFileSeconds ? longFileHopSamples : defaultHopSamples
        let fMax = min(fMaxCapHz, decoded.sampleRate * 0.5 * 0.98)
        let frequencies = SpectrogramSupport.melFrequencies(
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
        return SpectrogramSupport.upsample(native, to: SpectrogramSupport.displayFrames)
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
}
