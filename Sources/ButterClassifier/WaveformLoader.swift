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
    /// Decodes the file and reduces it to `bins` min/max pairs (mono).
    static func load(url: URL, bins: Int = 1200) throws -> WaveformData {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            return .empty
        }
        try file.read(into: buffer)

        guard let channels = buffer.floatChannelData else { return .empty }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        let duration = Double(frameCount) / format.sampleRate

        var mins = [Float](repeating: 0, count: bins)
        var maxs = [Float](repeating: 0, count: bins)
        let framesPerBin = max(1, frameCount / bins)

        for bin in 0..<bins {
            let start = bin * framesPerBin
            if start >= frameCount { break }
            let end = min(start + framesPerBin, frameCount)
            var lo: Float = 0
            var hi: Float = 0
            for frame in start..<end {
                var sample: Float = 0
                for ch in 0..<channelCount {
                    sample += channels[ch][frame]
                }
                sample /= Float(channelCount)
                if sample < lo { lo = sample }
                if sample > hi { hi = sample }
            }
            mins[bin] = lo
            maxs[bin] = hi
        }

        // Normalize display so quiet files are still visible.
        let peak = max(maxs.max() ?? 0, abs(mins.min() ?? 0))
        if peak > 0.0001 && peak < 1.0 {
            let scale = 1.0 / peak
            for i in 0..<bins {
                mins[i] *= scale
                maxs[i] *= scale
            }
        }

        return WaveformData(mins: mins, maxs: maxs, duration: duration)
    }
}
