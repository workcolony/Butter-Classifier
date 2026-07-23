import Foundation
import AVFoundation

/// Mel-scaled spectrogram power grid for waveform display.
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

enum SpectrogramSupport {
    /// Match chroma/glass temporal density for zoom.
    static let displayFrames = WaveformLoader.canonicalBins

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

    // MARK: - Decode

    struct DecodedMono {
        var samples: [Float]
        var frameCount: Int
        var sampleRate: Double
    }

    static func decodeMono(url: URL) throws -> DecodedMono {
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
