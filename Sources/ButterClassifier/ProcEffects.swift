import Foundation
import AVFoundation
import Accelerate

/// Cecilia5-inspired offline processors for PROC (fixed parameters, no automation).
enum ProcEffects {
    enum EffectError: LocalizedError {
        case emptyFile
        case bufferAllocation

        var errorDescription: String? {
            switch self {
            case .emptyFile: return "The audio file is empty."
            case .bufferAllocation: return "Could not allocate audio buffers."
            }
        }
    }

    // MARK: - Tier 1

    @discardableResult
    static func degrade(url: URL, bits: Double, rateRatio: Double, mirror: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EffectError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let wet = Float(max(0, min(1, mix)))
        let dry = 1 - wet
        let levels = Float(pow(2.0, max(2, min(16, bits))))
        let hold = max(1, Int(round(1.0 / max(0.02, min(1, rateRatio)))))
        let mirrorT = Float(max(0.05, min(1, mirror)))

        for ch in 0..<channels {
            var degraded = [Float](repeating: 0, count: frames)
            var held: Float = data[ch][0]
            for i in 0..<frames {
                if i % hold == 0 { held = data[ch][i] }
                var s = round(held * levels) / levels
                if s > mirrorT { s = mirrorT * 2 - s }
                else if s < -mirrorT { s = -mirrorT * 2 - s }
                degraded[i] = s
            }
            for i in 0..<frames {
                data[ch][i] = data[ch][i] * dry + degraded[i] * wet
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_degrade%.0f", bits))
    }

    @discardableResult
    static func phaser(url: URL, baseFreq: Double, q: Double, spread: Double, stages: Double, feedback: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EffectError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let wet = Float(max(0, min(1, mix)))
        let dry = 1 - wet
        let stageCount = max(1, min(12, Int(stages)))
        let fb = Float(max(0, min(0.95, feedback)))

        for ch in 0..<channels {
            let drySamples = Array(UnsafeBufferPointer(start: data[ch], count: frames))
            var phased = drySamples
            for stage in 0..<stageCount {
                let freq = max(40, baseFreq + Double(stage) * spread)
                phased = allpassBiquad(phased, sampleRate: sr, freq: freq, q: max(0.1, q))
            }
            if fb > 0 {
                // Offline approximation of feedback: run the allpass chain once more
                // over the phased signal and blend it back in.
                var fbPass = phased
                for stage in 0..<stageCount {
                    let freq = max(40, baseFreq + Double(stage) * spread)
                    fbPass = allpassBiquad(fbPass, sampleRate: sr, freq: freq, q: max(0.1, q))
                }
                for i in 0..<frames { phased[i] += fbPass[i] * fb }
            }
            for i in 0..<frames {
                data[ch][i] = drySamples[i] * dry + phased[i] * wet
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_phaser%.0f", baseFreq))
    }

    @discardableResult
    static func freqShift(url: URL, shiftHz: Double, feedback: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EffectError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let wet = Float(max(0, min(1, mix)))
        let dry = 1 - wet
        let fb = Float(max(0, min(0.9, feedback)))

        let fbDelayFrames = max(1, Int(0.12 * sr))
        for ch in 0..<channels {
            let drySamples = Array(UnsafeBufferPointer(start: data[ch], count: frames))
            let hilbert = hilbertTransform(drySamples)
            var shifted = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                let phase = 2 * Double.pi * shiftHz * Double(i) / sr
                shifted[i] = drySamples[i] * Float(cos(phase)) + hilbert[i] * Float(sin(phase))
            }
            if fb > 0 {
                for i in fbDelayFrames..<frames {
                    shifted[i] += shifted[i - fbDelayFrames] * fb
                }
            }
            for i in 0..<frames {
                data[ch][i] = drySamples[i] * dry + shifted[i] * wet
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_fshift%.0f", shiftHz))
    }

    @discardableResult
    static func waveShape(url: URL, drive: Double, preCutoff: Double, postCutoff: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EffectError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let wet = Float(max(0, min(1, mix)))
        let dry = 1 - wet
        let gain = Float(pow(10.0, drive / 20.0))
        let norm = tanh(gain)

        for ch in 0..<channels {
            var samples = Array(UnsafeBufferPointer(start: data[ch], count: frames))
            samples = onePoleLowPass(samples, sampleRate: sr, cutoff: preCutoff)
            for i in 0..<frames { samples[i] = tanh(samples[i] * gain) / norm }
            samples = onePoleLowPass(samples, sampleRate: sr, cutoff: postCutoff)
            for i in 0..<frames {
                data[ch][i] = data[ch][i] * dry + samples[i] * wet
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_wshape%.0f", drive))
    }

    @discardableResult
    static func paramEQ(url: URL, freq: Double, q: Double, gainDb: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EffectError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate

        for ch in 0..<channels {
            var samples = Array(UnsafeBufferPointer(start: data[ch], count: frames))
            samples = peakingEQ(samples, sampleRate: sr, freq: freq, q: max(0.1, q), gainDb: gainDb)
            for i in 0..<frames { data[ch][i] = samples[i] }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_peq%.0f", freq))
    }

    @discardableResult
    static func stateVar(url: URL, cutoff: Double, q: Double, mode: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EffectError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let wet = Float(max(0, min(1, mix)))
        let dry = 1 - wet
        let filterMode = Int(max(0, min(2, mode.rounded())))

        for ch in 0..<channels {
            let drySamples = Array(UnsafeBufferPointer(start: data[ch], count: frames))
            let filtered = stateVariableFilter(drySamples, sampleRate: sr, cutoff: cutoff, q: max(0.1, q), mode: filterMode)
            for i in 0..<frames {
                data[ch][i] = drySamples[i] * dry + filtered[i] * wet
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_svf%.0f", cutoff))
    }

    @discardableResult
    static func granulate(url: URL, position: Double, grainMs: Double, density: Double, pitchJitter: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EffectError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let grainFrames = max(1, Int(grainMs / 1000.0 * sr))
        let maxStart = max(0, frames - grainFrames)
        guard maxStart > 0 else { throw EffectError.emptyFile }

        let center = max(0, min(1, position))
        let grainCount = max(1, Int(density * Double(frames) / Double(grainFrames)))
        let jitterCents = pitchJitter

        var window = [Float](repeating: 0, count: grainFrames)
        vDSP_hann_window(&window, vDSP_Length(grainFrames), Int32(vDSP_HANN_NORM))

        var wet = Array(repeating: [Float](repeating: 0, count: frames), count: channels)
        var norm = [Float](repeating: 0, count: frames)
        let wetMix = Float(max(0, min(1, mix)))
        let dryMix = 1 - wetMix

        for _ in 0..<grainCount {
            let bias = Int(Double(maxStart) * center)
            let spread = max(1, maxStart / 4)
            let srcStart = min(maxStart, max(0, bias + Int.random(in: -spread...spread)))
            let dstStart = Int.random(in: 0...maxStart)
            let ratio = Float(pow(2.0, Double.random(in: -jitterCents...jitterCents) / 1200.0))

            for ch in 0..<channels {
                for i in 0..<grainFrames {
                    let srcPos = Float(i) / ratio
                    let i0 = Int(srcPos)
                    let frac = srcPos - Float(i0)
                    let s0 = srcStart + min(i0, grainFrames - 1)
                    let s1 = min(srcStart + grainFrames - 1, s0 + 1)
                    let sample = data[ch][s0] * (1 - frac) + data[ch][s1] * frac
                    let dstIdx = dstStart + i
                    guard dstIdx < frames else { break }
                    let w = window[i]
                    wet[ch][dstIdx] += sample * w
                    if ch == 0 { norm[dstIdx] += w * w }
                }
            }
        }

        for ch in 0..<channels {
            for i in 0..<frames {
                let wetSample = norm[i] > 1e-6 ? wet[ch][i] / norm[i] : 0
                data[ch][i] = data[ch][i] * dryMix + wetSample * wetMix
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_granulate%.0f", grainMs))
    }

    // MARK: - Tier 2

    @discardableResult
    static func vocoder(url: URL, bands: Double, baseFreq: Double, spread: Double, q: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EffectError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let wet = Float(max(0, min(1, mix)))
        let dry = 1 - wet
        let bandCount = max(4, min(24, Int(bands)))

        for ch in 0..<channels {
            let drySamples = Array(UnsafeBufferPointer(start: data[ch], count: frames))
            var output = [Float](repeating: 0, count: frames)
            for b in 0..<bandCount {
                let freq = baseFreq * pow(max(1.01, spread), Double(b))
                let lo = freq / sqrt(max(0.1, q))
                let hi = freq * sqrt(max(0.1, q))
                var analysis = bandPass(drySamples, sampleRate: sr, low: lo, high: hi)
                let carrier = bandPass(drySamples, sampleRate: sr, low: lo * 0.9, high: hi * 1.1)
                envelopeFollow(&analysis, sampleRate: sr, attack: 0.003, release: 0.05)
                for i in 0..<frames { output[i] += carrier[i] * analysis[i] }
            }
            let peak = output.map(abs).max() ?? 1
            let norm = peak > 0 ? 1 / peak : 1
            for i in 0..<frames {
                data[ch][i] = drySamples[i] * dry + output[i] * norm * wet
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_voc%.0f", baseFreq))
    }

    @discardableResult
    static func harmonizer(url: URL, voice1: Double, voice2: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EffectError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let wet = Float(max(0, min(1, mix)))
        let dry = 1 - wet

        for ch in 0..<channels {
            let drySamples = Array(UnsafeBufferPointer(start: data[ch], count: frames))
            let v1 = pitchShift(drySamples, semitones: voice1)
            let v2 = pitchShift(drySamples, semitones: voice2)
            for i in 0..<frames {
                let harmony = (v1[i] + v2[i]) * 0.5
                data[ch][i] = drySamples[i] * dry + harmony * wet
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: "_harm")
    }

    @discardableResult
    static func spectralGate(url: URL, thresholdDB: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EffectError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let wet = Float(max(0, min(1, mix)))
        let dry = 1 - wet

        for ch in 0..<channels {
            let drySamples = Array(UnsafeBufferPointer(start: data[ch], count: frames))
            // Raw STFT magnitudes scale with FFT size, so the threshold has to be
            // relative to the loudest bin of the file rather than an absolute level.
            var globalMax: Float = 0
            _ = try stftProcess(drySamples) { mag, _ in
                if let m = mag.max(), m > globalMax { globalMax = m }
                return mag
            }
            let gateLevel = globalMax * Float(pow(10.0, thresholdDB / 20.0))
            let gated = try stftProcess(drySamples) { mag, _ in
                mag.map { $0 < gateLevel ? $0 * 0.03 : $0 }
            }
            for i in 0..<frames {
                data[ch][i] = drySamples[i] * dry + gated[i] * wet
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_sgate%.0f", thresholdDB))
    }

    @discardableResult
    static func spectralDelay(url: URL, timeMs: Double, feedback: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EffectError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let wet = Float(max(0, min(1, mix)))
        let dry = 1 - wet
        // stftProcess uses a 512-sample hop; the delay is measured in STFT frames.
        let delayFrames = max(1, Int(timeMs / 1000.0 * sr / 512.0))
        let fb = Float(max(0, min(0.95, feedback)))

        for ch in 0..<channels {
            let drySamples = Array(UnsafeBufferPointer(start: data[ch], count: frames))
            var history: [[Float]] = []
            let processed = try stftProcess(drySamples) { mag, _ in
                var m = mag
                if history.count >= delayFrames {
                    let past = history[history.count - delayFrames]
                    for i in 0..<m.count { m[i] += past[i] * fb }
                }
                history.append(m)
                if history.count > delayFrames {
                    history.removeFirst(history.count - delayFrames)
                }
                return m
            }
            for i in 0..<frames {
                data[ch][i] = drySamples[i] * dry + processed[i] * wet
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_sdly%.0f", timeMs))
    }

    @discardableResult
    static func spectralShift(url: URL, shiftHz: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EffectError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let wet = Float(max(0, min(1, mix)))
        let dry = 1 - wet
        let binShift = Int(shiftHz / (sr / 2048.0))

        for ch in 0..<channels {
            let drySamples = Array(UnsafeBufferPointer(start: data[ch], count: frames))
            let shifted = try stftProcess(drySamples) { mag, _ in
                var m = [Float](repeating: 0, count: mag.count)
                for i in 0..<mag.count {
                    let dst = i + binShift
                    if dst >= 0 && dst < mag.count {
                        m[dst] = mag[i]
                    }
                }
                return m
            }
            for i in 0..<frames {
                data[ch][i] = drySamples[i] * dry + shifted[i] * wet
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_sshift%.0f", shiftHz))
    }

    @discardableResult
    static func resonators(url: URL, baseFreq: Double, detune: Double, decay: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EffectError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let wet = Float(max(0, min(1, mix)))
        let dry = 1 - wet
        let freqs = (0..<6).map { i in
            baseFreq * pow(2.0, Double(i) / 6.0) * (1 + detune * Double(i - 3) * 0.01)
        }

        let decayF = Float(max(0.5, min(0.995, decay)))
        for ch in 0..<channels {
            let drySamples = Array(UnsafeBufferPointer(start: data[ch], count: frames))
            // Sum only the ringing tails (comb output minus the direct signal),
            // otherwise the dry passthrough of six combs drowns the resonance.
            var resonant = [Float](repeating: 0, count: frames)
            for freq in freqs {
                let delay = max(1, Int(sr / max(30, freq)))
                var comb = [Float](repeating: 0, count: frames)
                for i in 0..<frames {
                    let fbSample = i >= delay ? comb[i - delay] * decayF : 0
                    comb[i] = drySamples[i] + fbSample
                }
                for i in 0..<frames { resonant[i] += comb[i] - drySamples[i] }
            }
            let dryPeak = drySamples.map(abs).max() ?? 1
            let wetPeak = resonant.map(abs).max() ?? 1
            let norm = wetPeak > 0 ? dryPeak / wetPeak : 1
            for i in 0..<frames {
                data[ch][i] = drySamples[i] * dry + resonant[i] * norm * wet
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_reso%.0f", baseFreq))
    }

    @discardableResult
    static func particle(url: URL, grainMs: Double, density: Double, posRand: Double, pitchRand: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EffectError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let baseGrain = max(1, Int(grainMs / 1000.0 * sr))
        let maxStart = max(0, frames - baseGrain * 2)
        guard maxStart > 0 else { throw EffectError.emptyFile }

        let grainCount = max(1, Int(density * Double(frames) / Double(baseGrain)))
        let posSpread = max(1, Int(Double(maxStart) * max(0, min(1, posRand))))
        let wetMix = Float(max(0, min(1, mix)))
        let dryMix = 1 - wetMix

        var wet = Array(repeating: [Float](repeating: 0, count: frames), count: channels)
        var norm = [Float](repeating: 0, count: frames)

        for _ in 0..<grainCount {
            let grainFrames = max(1, baseGrain + Int.random(in: -baseGrain / 3...baseGrain / 3))
            let srcStart = min(maxStart, max(0, Int.random(in: 0...maxStart) + Int.random(in: -posSpread...posSpread)))
            let dstStart = Int.random(in: 0...max(0, frames - grainFrames))
            let ratio = Float(pow(2.0, Double.random(in: -pitchRand...pitchRand) / 1200.0))

            var window = [Float](repeating: 0, count: grainFrames)
            vDSP_hann_window(&window, vDSP_Length(grainFrames), Int32(vDSP_HANN_NORM))

            for ch in 0..<channels {
                for i in 0..<grainFrames {
                    let srcPos = Float(i) / ratio
                    let i0 = Int(srcPos)
                    let frac = srcPos - Float(i0)
                    let s0 = min(frames - 1, srcStart + i0)
                    let s1 = min(frames - 1, s0 + 1)
                    let sample = data[ch][s0] * (1 - frac) + data[ch][s1] * frac
                    let dstIdx = dstStart + i
                    guard dstIdx < frames else { break }
                    let w = window[i]
                    wet[ch][dstIdx] += sample * w
                    if ch == 0 { norm[dstIdx] += w * w }
                }
            }
        }

        for ch in 0..<channels {
            for i in 0..<frames {
                let wetSample = norm[i] > 1e-6 ? wet[ch][i] / norm[i] : 0
                data[ch][i] = data[ch][i] * dryMix + wetSample * wetMix
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_particle%.0f", grainMs))
    }

    // MARK: - DSP helpers

    private static func readAll(_ url: URL) throws -> (AVAudioPCMBuffer, AVAudioFormat) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { throw EffectError.emptyFile }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw EffectError.bufferAllocation
        }
        try file.read(into: buffer)
        return (buffer, format)
    }

    private static func writeNextToSource(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat, source: URL, suffix: String) throws -> URL {
        let base = source.deletingPathExtension().lastPathComponent + suffix
        let outURL = AudioEditor.uniqueURL(inFolder: source.deletingLastPathComponent(), baseName: base)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outFile = try AVAudioFile(forWriting: outURL, settings: settings)
        try outFile.write(from: buffer)
        return outURL
    }

    private static func onePoleLowPass(_ samples: [Float], sampleRate: Double, cutoff: Double) -> [Float] {
        var out = samples
        let rc = 1.0 / (2.0 * Double.pi * max(20, cutoff))
        let alpha = Float((1.0 / sampleRate) / (rc + (1.0 / sampleRate)))
        var y: Float = samples.first ?? 0
        for i in 0..<out.count {
            y += alpha * (out[i] - y)
            out[i] = y
        }
        return out
    }

    private static func bandPass(_ samples: [Float], sampleRate: Double, low: Double, high: Double) -> [Float] {
        var out = samples
        let rcH = 1.0 / (2.0 * Double.pi * max(20, low))
        let alphaH = Float(rcH / (rcH + (1.0 / sampleRate)))
        var yPrev: Float = 0
        var xPrev = out.first ?? 0
        for i in 0..<out.count {
            let x = out[i]
            let y = alphaH * (yPrev + x - xPrev)
            out[i] = y
            yPrev = y
            xPrev = x
        }
        return onePoleLowPass(out, sampleRate: sampleRate, cutoff: high)
    }

    private static func allpassBiquad(_ samples: [Float], sampleRate: Double, freq: Double, q: Double) -> [Float] {
        var out = samples
        // RBJ allpass: b0 = 1-alpha, b2 = 1+alpha (swapping them yields identity).
        let w0 = 2 * Double.pi * min(freq, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw0 = cos(w0)
        let a0 = Float(1 + alpha)
        let b0 = Float(1 - alpha) / a0
        let b1 = Float(-2 * cosw0) / a0
        let b2 = Float(1 + alpha) / a0
        let a1 = Float(-2 * cosw0) / a0
        let a2 = Float(1 - alpha) / a0

        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in 0..<out.count {
            let x0 = out[i]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            out[i] = y0
            x2 = x1; x1 = x0; y2 = y1; y1 = y0
        }
        return out
    }

    private static func peakingEQ(_ samples: [Float], sampleRate: Double, freq: Double, q: Double, gainDb: Double) -> [Float] {
        var out = samples
        let a = pow(10.0, gainDb / 40.0)
        let w0 = 2 * Double.pi * freq / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw0 = cos(w0)
        let a0 = Float(1 + alpha / a)
        let b0 = Float(1 + alpha * a) / a0
        let b1 = Float(-2 * cosw0) / a0
        let b2 = Float(1 - alpha * a) / a0
        let a1n = Float(-2 * cosw0) / a0
        let a2n = Float(1 - alpha / a) / a0

        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in 0..<out.count {
            let x0 = out[i]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1n * y1 - a2n * y2
            out[i] = y0
            x2 = x1; x1 = x0; y2 = y1; y1 = y0
        }
        return out
    }

    private static func stateVariableFilter(_ samples: [Float], sampleRate: Double, cutoff: Double, q: Double, mode: Int) -> [Float] {
        var out = [Float](repeating: 0, count: samples.count)
        let f = Float(2 * sin(Double.pi * min(0.49, cutoff / sampleRate)))
        let qInv = Float(1 / max(0.1, q))
        var low: Float = 0, band: Float = 0
        for i in 0..<samples.count {
            let input = samples[i]
            low += f * band
            let high = input - low - qInv * band
            band += f * high
            switch mode {
            case 1: out[i] = high
            case 2: out[i] = band
            default: out[i] = low
            }
        }
        return out
    }

    /// Windowed FIR Hilbert transformer, output aligned with the input (the kernel
    /// is centered, so no group-delay compensation is needed by the caller).
    private static func hilbertTransform(_ x: [Float], taps: Int = 257) -> [Float] {
        guard !x.isEmpty else { return x }
        let m = taps / 2
        var h = [Float](repeating: 0, count: taps)
        for n in 0..<taps {
            let k = n - m
            guard k % 2 != 0 else { continue }
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(taps - 1))
            h[n] = Float(2.0 / (Double.pi * Double(k)) * window)
        }
        var padded = [Float](repeating: 0, count: x.count + taps - 1)
        for i in 0..<x.count { padded[i + m] = x[i] }
        var out = [Float](repeating: 0, count: x.count)
        vDSP_conv(padded, 1, h, 1, &out, 1, vDSP_Length(x.count), vDSP_Length(taps))
        return out
    }

    private static func pitchShift(_ samples: [Float], semitones: Double) -> [Float] {
        let ratio = pow(2.0, semitones / 12.0)
        var out = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let src = Double(i) / ratio
            let i0 = Int(src)
            let frac = Float(src - Double(i0))
            if i0 + 1 < samples.count {
                out[i] = samples[i0] * (1 - frac) + samples[i0 + 1] * frac
            } else if i0 < samples.count {
                out[i] = samples[i0]
            }
        }
        return out
    }

    private static func envelopeFollow(_ samples: inout [Float], sampleRate: Double, attack: Double, release: Double) {
        let aA = Float(exp(-1 / (attack * sampleRate)))
        let aR = Float(exp(-1 / (release * sampleRate)))
        var env: Float = 0
        for i in 0..<samples.count {
            let target = abs(samples[i])
            env = target > env ? aA * env + (1 - aA) * target : aR * env + (1 - aR) * target
            samples[i] = env
        }
    }

    private static func stftProcess(_ samples: [Float], magnitudeMap: ([Float], [Float]) -> [Float]) throws -> [Float] {
        let frames = samples.count
        guard frames > 0 else { return samples }

        let fftSize = 2048
        let hop = 512
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw EffectError.bufferAllocation
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var output = [Float](repeating: 0, count: frames)
        var norm = [Float](repeating: 0, count: frames)
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)

        var pos = 0
        while pos < frames {
            var frame = [Float](repeating: 0, count: fftSize)
            let end = min(pos + fftSize, frames)
            let len = end - pos
            for i in 0..<len { frame[i] = samples[pos + i] * window[i] }

            real.withUnsafeMutableBufferPointer { realBuf in
                imag.withUnsafeMutableBufferPointer { imagBuf in
                    frame.withUnsafeMutableBufferPointer { frameBuf in
                        frameBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                            var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                    }
                    var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                    var mag = [Float](repeating: 0, count: fftSize / 2)
                    var phase = [Float](repeating: 0, count: fftSize / 2)
                    for i in 0..<fftSize / 2 {
                        let r = realBuf[i]
                        let im = imagBuf[i]
                        mag[i] = sqrt(r * r + im * im)
                        phase[i] = atan2(im, r)
                    }
                    let newMag = magnitudeMap(mag, phase)
                    for i in 0..<fftSize / 2 {
                        realBuf[i] = newMag[i] * cos(phase[i])
                        imagBuf[i] = newMag[i] * sin(phase[i])
                    }

                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    var scale = Float(1.0 / Float(fftSize))
                    vDSP_vsmul(realBuf.baseAddress!, 1, &scale, realBuf.baseAddress!, 1, vDSP_Length(fftSize / 2))
                    vDSP_vsmul(imagBuf.baseAddress!, 1, &scale, imagBuf.baseAddress!, 1, vDSP_Length(fftSize / 2))
                }
            }

            var reconstructed = [Float](repeating: 0, count: fftSize)
            real.withUnsafeMutableBufferPointer { realBuf in
                imag.withUnsafeMutableBufferPointer { imagBuf in
                    reconstructed.withUnsafeMutableBufferPointer { outBuf in
                        outBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                            var splitOut = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                            vDSP_ztoc(&splitOut, 1, complexPtr, 2, vDSP_Length(fftSize / 2))
                        }
                    }
                }
            }

            for i in 0..<fftSize where pos + i < frames {
                output[pos + i] += reconstructed[i] * window[i]
                norm[pos + i] += window[i] * window[i]
            }
            pos += hop
        }

        for i in 0..<frames where norm[i] > 1e-6 { output[i] /= norm[i] }
        return output
    }
}
