import Foundation
import AVFoundation

/// Min/max peak pairs for waveform display.
struct WaveformData: Equatable {
    var mins: [Float]
    var maxs: [Float]
    var duration: Double

    static let empty = WaveformData(mins: [], maxs: [], duration: 0)
}

enum WaveformLoader {
    /// Overview waveform for Original mode.
    static let displayBins = 1200
    /// Standard resolution for spectral overlays and caching.
    static let canonicalBins = 8192
    /// Full audio resolution for Supersample mode (decoded separately).
    static let supersampleBins = 32_768

    /// Decodes the file and reduces it to `bins` min/max pairs (mono).
    /// Uses a single global peak so different bin counts align visually.
    static func load(url: URL, bins: Int = 1200) throws -> WaveformData {
        let decoded = try decodeMono(url: url)
        guard decoded.frameCount > 0 else { return .empty }
        return bin(samples: decoded.samples, frameCount: decoded.frameCount, sampleRate: decoded.sampleRate, bins: bins, globalPeak: decoded.globalPeak)
    }

    /// Downsample a higher-resolution waveform for display (preserves peaks).
    static func subsample(_ data: WaveformData, to bins: Int) -> WaveformData {
        let sourceBins = data.mins.count
        guard sourceBins > 0, bins > 0, bins < sourceBins else { return data }

        var mins = [Float](repeating: 0, count: bins)
        var maxs = [Float](repeating: 0, count: bins)
        let ratio = Double(sourceBins) / Double(bins)

        for bin in 0..<bins {
            let start = Int(Double(bin) * ratio)
            let end = min(sourceBins, Int(Double(bin + 1) * ratio))
            guard start < end else { continue }
            var lo: Float = 0
            var hi: Float = 0
            for i in start..<end {
                lo = min(lo, data.mins[i])
                hi = max(hi, data.maxs[i])
            }
            mins[bin] = lo
            maxs[bin] = hi
        }
        return WaveformData(mins: mins, maxs: maxs, duration: data.duration)
    }

    private struct DecodedMono {
        var samples: [Float]
        var frameCount: Int
        var sampleRate: Double
        var globalPeak: Float
    }

    private static func decodeMono(url: URL) throws -> DecodedMono {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            return DecodedMono(samples: [], frameCount: 0, sampleRate: format.sampleRate, globalPeak: 1)
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            return DecodedMono(samples: [], frameCount: 0, sampleRate: format.sampleRate, globalPeak: 1)
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)
        var globalPeak: Float = 0.0001

        for frame in 0..<frameCount {
            var sample: Float = 0
            for ch in 0..<channelCount {
                sample += channels[ch][frame]
            }
            sample /= Float(channelCount)
            mono[frame] = sample
            globalPeak = max(globalPeak, abs(sample))
        }

        return DecodedMono(
            samples: mono,
            frameCount: frameCount,
            sampleRate: format.sampleRate,
            globalPeak: globalPeak
        )
    }

    private static func bin(samples: [Float], frameCount: Int, sampleRate: Double, bins: Int, globalPeak: Float) -> WaveformData {
        guard frameCount > 0, bins > 0 else { return .empty }

        var mins = [Float](repeating: 0, count: bins)
        var maxs = [Float](repeating: 0, count: bins)
        let duration = Double(frameCount) / sampleRate

        // One display scale for all resolutions — only boost quiet material.
        let displayScale: Float = globalPeak < 1.0 ? 1.0 / globalPeak : 1.0

        for bin in 0..<bins {
            let start = (bin * frameCount) / bins
            let end = ((bin + 1) * frameCount) / bins
            guard start < end else { continue }
            var lo: Float = 0
            var hi: Float = 0
            for frame in start..<end {
                let sample = samples[frame]
                if sample < lo { lo = sample }
                if sample > hi { hi = sample }
            }
            mins[bin] = lo * displayScale
            maxs[bin] = hi * displayScale
        }

        return WaveformData(mins: mins, maxs: maxs, duration: duration)
    }
}
