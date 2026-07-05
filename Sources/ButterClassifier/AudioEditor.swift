import Foundation
import AVFoundation

/// Non-destructive audio editing: every operation writes a new WAV file and
/// never touches the original.
enum AudioEditor {
    enum EditError: LocalizedError {
        case emptyFile
        case invalidSelection
        case bufferAllocation

        var errorDescription: String? {
            switch self {
            case .emptyFile: return "The audio file is empty."
            case .invalidSelection: return "The selection is empty or out of range."
            case .bufferAllocation: return "Could not allocate audio buffers."
            }
        }
    }

    private static func readAll(_ url: URL) throws -> (AVAudioPCMBuffer, AVAudioFormat) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { throw EditError.emptyFile }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw EditError.bufferAllocation
        }
        try file.read(into: buffer)
        return (buffer, format)
    }

    private static func writeWAV(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outFile = try AVAudioFile(forWriting: url, settings: settings)
        try outFile.write(from: buffer)
    }

    /// Returns a URL like `base name.wav`, `base name 2.wav`, ... that doesn't exist yet.
    static func uniqueURL(inFolder folder: URL, baseName: String, ext: String = "wav") -> URL {
        var candidate = folder.appendingPathComponent("\(baseName).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private static func copySegment(of buffer: AVAudioPCMBuffer, format: AVAudioFormat,
                                    startFrame: Int, endFrame: Int) throws -> AVAudioPCMBuffer {
        let length = endFrame - startFrame
        guard length > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else {
            throw EditError.invalidSelection
        }
        for ch in 0..<Int(format.channelCount) {
            dst[ch].update(from: src[ch] + startFrame, count: length)
        }
        out.frameLength = AVAudioFrameCount(length)
        return out
    }

    private static func applyFades(_ buffer: AVAudioPCMBuffer, channels: Int, fadeSeconds: Double, sampleRate: Double) {
        guard fadeSeconds > 0, let data = buffer.floatChannelData else { return }
        let total = Int(buffer.frameLength)
        let fadeFrames = min(Int(fadeSeconds * sampleRate), total / 2)
        guard fadeFrames > 0 else { return }
        for ch in 0..<channels {
            for i in 0..<fadeFrames {
                let g = Float(i) / Float(fadeFrames)
                data[ch][i] *= g
                data[ch][total - 1 - i] *= g
            }
        }
    }

    // MARK: - Operations

    /// Exports [start, end] seconds of the file as a new WAV next to the original.
    @discardableResult
    static func trim(url: URL, start: Double, end: Double, fadeMs: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        let sr = format.sampleRate
        let startFrame = max(0, Int(start * sr))
        let endFrame = min(Int(buffer.frameLength), Int(end * sr))
        guard endFrame > startFrame else { throw EditError.invalidSelection }

        let segment = try copySegment(of: buffer, format: format, startFrame: startFrame, endFrame: endFrame)
        applyFades(segment, channels: Int(format.channelCount), fadeSeconds: fadeMs / 1000.0, sampleRate: sr)

        let base = url.deletingPathExtension().lastPathComponent + "_trim"
        let outURL = uniqueURL(inFolder: url.deletingLastPathComponent(), baseName: base)
        try writeWAV(segment, format: format, to: outURL)
        return outURL
    }

    /// Peak-normalizes to the target dBFS, writing a new WAV next to the original.
    @discardableResult
    static func normalize(url: URL, targetDBFS: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)

        var peak: Float = 0
        for ch in 0..<channels {
            for i in 0..<frames {
                peak = max(peak, abs(data[ch][i]))
            }
        }
        guard peak > 0 else { throw EditError.emptyFile }

        let target = Float(pow(10.0, targetDBFS / 20.0))
        let gain = target / peak
        for ch in 0..<channels {
            for i in 0..<frames {
                data[ch][i] *= gain
            }
        }

        let base = url.deletingPathExtension().lastPathComponent + "_norm"
        let outURL = uniqueURL(inFolder: url.deletingLastPathComponent(), baseName: base)
        try writeWAV(buffer, format: format, to: outURL)
        return outURL
    }

    /// Applies a fixed gain in dB, writing a new WAV next to the original.
    @discardableResult
    static func applyGain(url: URL, gainDB: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let gain = Float(pow(10.0, gainDB / 20.0))
        for ch in 0..<channels {
            for i in 0..<frames {
                data[ch][i] *= gain
            }
        }
        let base = url.deletingPathExtension().lastPathComponent + String(format: "_gain%+.1fdB", gainDB)
        let outURL = uniqueURL(inFolder: url.deletingLastPathComponent(), baseName: base)
        try writeWAV(buffer, format: format, to: outURL)
        return outURL
    }

    /// Slices the file at the given onset times (seconds) into numbered WAVs
    /// inside a `<name>_slices` subfolder. Returns the created folder.
    @discardableResult
    static func slice(url: URL, onsets: [Double], fadeMs: Double = 2) throws -> URL {
        let (buffer, format) = try readAll(url)
        let sr = format.sampleRate
        let totalFrames = Int(buffer.frameLength)

        // Boundaries: each onset starts a slice; the last slice runs to EOF.
        var boundaries = onsets.map { max(0, Int($0 * sr)) }.filter { $0 < totalFrames }
        boundaries = Array(Set(boundaries)).sorted()
        if boundaries.isEmpty || boundaries[0] != 0 {
            boundaries.insert(0, at: 0)
        }
        guard boundaries.count >= 1 else { throw EditError.invalidSelection }

        let folderName = url.deletingPathExtension().lastPathComponent + "_slices"
        var sliceFolder = url.deletingLastPathComponent().appendingPathComponent(folderName)
        var n = 2
        while FileManager.default.fileExists(atPath: sliceFolder.path) {
            sliceFolder = url.deletingLastPathComponent().appendingPathComponent("\(folderName) \(n)")
            n += 1
        }
        try FileManager.default.createDirectory(at: sliceFolder, withIntermediateDirectories: true)

        let baseName = url.deletingPathExtension().lastPathComponent
        for (i, start) in boundaries.enumerated() {
            let end = i + 1 < boundaries.count ? boundaries[i + 1] : totalFrames
            guard end > start else { continue }
            let segment = try copySegment(of: buffer, format: format, startFrame: start, endFrame: end)
            applyFades(segment, channels: Int(format.channelCount), fadeSeconds: fadeMs / 1000.0, sampleRate: sr)
            let name = String(format: "%@_%02d.wav", baseName, i + 1)
            try writeWAV(segment, format: format, to: sliceFolder.appendingPathComponent(name))
        }
        return sliceFolder
    }
}
