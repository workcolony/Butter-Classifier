import Foundation
import Accelerate

/// Mel spectrogram via windowed STFT (Accelerate vDSP) + triangular Mel filterbank.
/// Defaults align with ROADMAP #13: FFT 2048, Blackman, 4× overlap, Mel scale.
enum STFTSpectrogram {
    static let fftSize = 2048
    /// 4× time overlap → hop = fftSize / 4.
    static let defaultHopSamples = 512
    /// Coarser hop for long clips; still upsampled for drawing.
    static let longFileHopSamples = 1024
    static let longFileSeconds: Double = 90
    static let defaultBandCount = 96
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
        let native = stftMel(
            samples: decoded.samples,
            sampleRate: decoded.sampleRate,
            hopSamples: hop,
            bandCount: defaultBandCount,
            fMin: fMinHz,
            fMax: fMax
        )
        return SpectrogramSupport.upsample(native, to: SpectrogramSupport.displayFrames)
    }

    // MARK: - STFT + Mel

    private static func stftMel(
        samples: [Float],
        sampleRate: Double,
        hopSamples: Int,
        bandCount: Int,
        fMin: Double,
        fMax: Double
    ) -> SpectrogramData {
        let frameCount = samples.count
        let hop = max(1, hopSamples)
        guard frameCount > 0, bandCount > 0, sampleRate > 0 else { return .empty }

        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return .empty
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_blkman_window(&window, vDSP_Length(fftSize), 0)

        let nBins = fftSize / 2 + 1
        let filterbank = melFilterbank(
            sampleRate: sampleRate,
            nFFT: fftSize,
            nMels: bandCount,
            fMin: fMin,
            fMax: fMax
        )

        let outFrames = max(1, (frameCount + hop - 1) / hop)
        var powers = [Float](repeating: 0, count: outFrames * bandCount)

        var frame = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var spectrum = [Float](repeating: 0, count: nBins)
        var melRow = [Float](repeating: 0, count: bandCount)

        var globalMax: Float = 1e-20
        var outFrame = 0
        var pos = 0

        while pos < frameCount && outFrame < outFrames {
            for i in 0..<fftSize { frame[i] = 0 }
            let end = min(pos + fftSize, frameCount)
            let len = end - pos
            for i in 0..<len {
                frame[i] = samples[pos + i] * window[i]
            }

            real.withUnsafeMutableBufferPointer { realBuf in
                imag.withUnsafeMutableBufferPointer { imagBuf in
                    frame.withUnsafeMutableBufferPointer { frameBuf in
                        frameBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                            var split = DSPSplitComplex(
                                realp: realBuf.baseAddress!,
                                imagp: imagBuf.baseAddress!
                            )
                            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                    }
                    var split = DSPSplitComplex(
                        realp: realBuf.baseAddress!,
                        imagp: imagBuf.baseAddress!
                    )
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                    // Packed real FFT: real[0]=DC, imag[0]=Nyquist.
                    spectrum[0] = realBuf[0] * realBuf[0]
                    spectrum[fftSize / 2] = imagBuf[0] * imagBuf[0]
                    for i in 1..<(fftSize / 2) {
                        let r = realBuf[i]
                        let im = imagBuf[i]
                        spectrum[i] = r * r + im * im
                    }
                }
            }

            // Scale to power spectral density-ish (window energy); relative peak dB later.
            let scale = 1.0 / Float(fftSize)
            for i in 0..<nBins {
                spectrum[i] *= scale
            }

            for m in 0..<bandCount {
                var sum: Float = 0
                let row = filterbank[m]
                for k in 0..<nBins where row[k] > 0 {
                    sum += row[k] * spectrum[k]
                }
                melRow[m] = sum
                if sum > globalMax { globalMax = sum }
            }

            let base = outFrame * bandCount
            for m in 0..<bandCount {
                powers[base + m] = melRow[m]
            }

            outFrame += 1
            pos += hop
        }

        let peak = max(globalMax, 1e-20)
        let minDB = -dynamicRangeDB
        var maxDB: Float = minDB
        for i in 0..<(outFrame * bandCount) {
            let db = 10 * log10(Double(powers[i] / peak) + 1e-20)
            let clipped = Float(max(Double(minDB), min(0, db)))
            powers[i] = clipped
            if clipped > maxDB { maxDB = clipped }
        }
        if maxDB <= minDB { maxDB = 0 }

        return SpectrogramData(
            duration: Double(frameCount) / sampleRate,
            sampleRate: sampleRate,
            bandCount: bandCount,
            frameCount: outFrame,
            hopSamples: hop,
            powersDB: Array(powers.prefix(outFrame * bandCount)),
            minDB: minDB,
            maxDB: maxDB
        )
    }

    /// Triangular Mel filterbank weights `[band][fftBin]`.
    private static func melFilterbank(
        sampleRate: Double,
        nFFT: Int,
        nMels: Int,
        fMin: Double,
        fMax: Double
    ) -> [[Float]] {
        let nBins = nFFT / 2 + 1
        let edges = SpectrogramSupport.melFrequencies(count: nMels + 2, fMin: fMin, fMax: fMax)
        guard edges.count == nMels + 2 else {
            return Array(repeating: Array(repeating: Float(0), count: nBins), count: nMels)
        }

        let fftFreqs = (0..<nBins).map { Double($0) * sampleRate / Double(nFFT) }
        var weights = Array(
            repeating: [Float](repeating: 0, count: nBins),
            count: nMels
        )

        for m in 0..<nMels {
            let left = edges[m]
            let center = edges[m + 1]
            let right = edges[m + 2]
            let rise = max(center - left, 1e-12)
            let fall = max(right - center, 1e-12)
            for k in 0..<nBins {
                let f = fftFreqs[k]
                if f >= left && f <= center {
                    weights[m][k] = Float((f - left) / rise)
                } else if f > center && f <= right {
                    weights[m][k] = Float((right - f) / fall)
                }
            }
        }
        return weights
    }
}
