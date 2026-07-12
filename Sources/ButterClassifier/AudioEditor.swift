import Foundation
import AVFoundation
import Accelerate

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

    // MARK: - Playback FX (time stretch + pitch)

    struct PlaybackFX: Equatable {
        var rate: Float = 1.0
        var pitch: Float = 1.0

        var isActive: Bool {
            abs(rate - 1.0) > 0.001 || abs(pitch - 1.0) > 0.001
        }

        static func clampedRate(_ rate: Float) -> Float {
            max(0.25, min(4.0, rate))
        }

        static func clampedPitch(_ pitch: Float) -> Float {
            max(0.25, min(4.0, pitch))
        }

        static func pitchRatioToCents(_ ratio: Float) -> Float {
            let clamped = clampedPitch(ratio)
            return Float(1200.0 * log2(Double(clamped)))
        }

        static func fileSuffix(rate: Float, pitch: Float) -> String {
            let r = (Double(clampedRate(rate)) * 100).rounded() / 100
            let p = (Double(clampedPitch(pitch)) * 100).rounded() / 100
            return String(format: "_fx_s%.2g_p%.2g", r, p)
        }
    }

    /// Bakes the current speed (time stretch) and pitch settings into a new WAV.
    @discardableResult
    static func applyPlaybackFX(url: URL, rate: Float, pitch: Float) throws -> URL {
        let fx = PlaybackFX(rate: rate, pitch: pitch)
        guard fx.isActive else { throw EditError.invalidSelection }
        let (buffer, format) = try readAll(url)
        let processed = try renderPlaybackFX(buffer: buffer, format: format, fx: fx)
        return try writeProcessedEdit(
            processed,
            format: format,
            source: url,
            suffix: PlaybackFX.fileSuffix(rate: fx.rate, pitch: fx.pitch)
        )
    }

    // MARK: - Operations

    /// Exports [start, end] seconds of the file as a new WAV next to the original.
    @discardableResult
    static func trim(url: URL, start: Double, end: Double, fadeMs: Double, playbackFX: PlaybackFX? = nil) throws -> URL {
        let (buffer, format) = try readAll(url)
        let sr = format.sampleRate
        let startFrame = max(0, Int(start * sr))
        let endFrame = min(Int(buffer.frameLength), Int(end * sr))
        guard endFrame > startFrame else { throw EditError.invalidSelection }

        let segment = try copySegment(of: buffer, format: format, startFrame: startFrame, endFrame: endFrame)
        applyFades(segment, channels: Int(format.channelCount), fadeSeconds: fadeMs / 1000.0, sampleRate: sr)

        return try writeProcessedEdit(
            segment,
            format: format,
            source: url,
            suffix: "_trim",
            playbackFX: playbackFX
        )
    }

    /// Peak-normalizes to the target dBFS, writing a new WAV next to the original.
    @discardableResult
    static func normalize(url: URL, targetDBFS: Double, playbackFX: PlaybackFX? = nil) throws -> URL {
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

        return try writeProcessedEdit(
            buffer,
            format: format,
            source: url,
            suffix: "_norm",
            playbackFX: playbackFX
        )
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

    /// Reverses the file, writing a new WAV next to the original.
    @discardableResult
    static func reverse(url: URL) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        for ch in 0..<channels {
            var lo = 0
            var hi = frames - 1
            while lo < hi {
                let tmp = data[ch][lo]
                data[ch][lo] = data[ch][hi]
                data[ch][hi] = tmp
                lo += 1
                hi -= 1
            }
        }
        let base = url.deletingPathExtension().lastPathComponent + "_rev"
        let outURL = uniqueURL(inFolder: url.deletingLastPathComponent(), baseName: base)
        try writeWAV(buffer, format: format, to: outURL)
        return outURL
    }

    /// One-pole low-pass filter.
    @discardableResult
    static func lowPass(url: URL, cutoffHz: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        try applyOnePoleLowPass(buffer, sampleRate: format.sampleRate, cutoffHz: cutoffHz, channels: Int(format.channelCount))
        let base = url.deletingPathExtension().lastPathComponent + String(format: "_lpf%.0f", cutoffHz)
        let outURL = uniqueURL(inFolder: url.deletingLastPathComponent(), baseName: base)
        try writeWAV(buffer, format: format, to: outURL)
        return outURL
    }

    /// One-pole high-pass filter.
    @discardableResult
    static func highPass(url: URL, cutoffHz: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        try applyOnePoleHighPass(buffer, sampleRate: format.sampleRate, cutoffHz: cutoffHz, channels: Int(format.channelCount))
        let base = url.deletingPathExtension().lastPathComponent + String(format: "_hpf%.0f", cutoffHz)
        let outURL = uniqueURL(inFolder: url.deletingLastPathComponent(), baseName: base)
        try writeWAV(buffer, format: format, to: outURL)
        return outURL
    }

    private static func applyOnePoleLowPass(_ buffer: AVAudioPCMBuffer, sampleRate: Double, cutoffHz: Double, channels: Int) throws {
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let rc = 1.0 / (2.0 * Double.pi * max(20, cutoffHz))
        let alpha = (1.0 / sampleRate) / (rc + (1.0 / sampleRate))
        for ch in 0..<channels {
            var y: Float = data[ch][0]
            for i in 0..<frames {
                y += Float(alpha) * (data[ch][i] - y)
                data[ch][i] = y
            }
        }
    }

    private static func applyOnePoleHighPass(_ buffer: AVAudioPCMBuffer, sampleRate: Double, cutoffHz: Double, channels: Int) throws {
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let rc = 1.0 / (2.0 * Double.pi * max(20, cutoffHz))
        let alpha = rc / (rc + (1.0 / sampleRate))
        for ch in 0..<channels {
            var yPrev: Float = 0
            var xPrev = data[ch][0]
            for i in 0..<frames {
                let x = data[ch][i]
                let y = Float(alpha) * (yPrev + x - xPrev)
                data[ch][i] = y
                yPrev = y
                xPrev = x
            }
        }
    }

    private static func writeNextToSource(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat, source: URL, suffix: String) throws -> URL {
        let base = source.deletingPathExtension().lastPathComponent + suffix
        let outURL = uniqueURL(inFolder: source.deletingLastPathComponent(), baseName: base)
        try writeWAV(buffer, format: format, to: outURL)
        return outURL
    }

    private static func writeProcessedEdit(
        _ buffer: AVAudioPCMBuffer,
        format: AVAudioFormat,
        source: URL,
        suffix: String,
        playbackFX: PlaybackFX? = nil
    ) throws -> URL {
        let outBuffer: AVAudioPCMBuffer
        if let fx = playbackFX, fx.isActive {
            outBuffer = try renderPlaybackFX(buffer: buffer, format: format, fx: fx)
        } else {
            outBuffer = buffer
        }
        return try writeNextToSource(outBuffer, format: format, source: source, suffix: suffix)
    }

    private static func renderPlaybackFX(
        buffer: AVAudioPCMBuffer,
        format: AVAudioFormat,
        fx: PlaybackFX
    ) throws -> AVAudioPCMBuffer {
        let rate = PlaybackFX.clampedRate(fx.rate)
        let pitch = PlaybackFX.clampedPitch(fx.pitch)
        guard buffer.frameLength > 0 else { throw EditError.emptyFile }

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()

        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        timePitch.rate = rate
        timePitch.pitch = PlaybackFX.pitchRatioToCents(pitch)

        let maxFrameCount: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrameCount)
        try engine.start()

        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
        playerNode.play()

        let inputFrames = AVAudioFramePosition(buffer.frameLength)
        let targetFrames = AVAudioFramePosition(ceil(Double(inputFrames) / Double(rate))) + 1024
        guard let output = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(targetFrames)
        ) else {
            throw EditError.bufferAllocation
        }
        output.frameLength = 0

        guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrameCount) else {
            throw EditError.bufferAllocation
        }

        var emptyPasses = 0
        while engine.manualRenderingSampleTime < targetFrames {
            let remaining = targetFrames - engine.manualRenderingSampleTime
            let framesToRender = AVAudioFrameCount(min(AVAudioFramePosition(maxFrameCount), remaining))
            guard framesToRender > 0 else { break }

            let status = try engine.renderOffline(framesToRender, to: renderBuffer)
            switch status {
            case .success:
                let produced = Int(renderBuffer.frameLength)
                if produced == 0 {
                    emptyPasses += 1
                    if emptyPasses > 12 { break }
                    continue
                }
                emptyPasses = 0
                try appendPCM(frames: produced, from: renderBuffer, to: output)
            case .insufficientDataFromInputNode:
                continue
            case .cannotDoInCurrentContext:
                continue
            case .error:
                throw EditError.bufferAllocation
            @unknown default:
                break
            }
        }

        playerNode.stop()
        engine.stop()

        guard output.frameLength > 0 else { throw EditError.emptyFile }
        return output
    }

    private static func appendPCM(frames: Int, from source: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) throws {
        guard let src = source.floatChannelData, let dst = destination.floatChannelData else {
            throw EditError.bufferAllocation
        }
        let dstStart = Int(destination.frameLength)
        let channels = Int(source.format.channelCount)
        guard dstStart + frames <= Int(destination.frameCapacity) else {
            throw EditError.bufferAllocation
        }
        for ch in 0..<channels {
            dst[ch].advanced(by: dstStart).update(from: src[ch], count: frames)
        }
        destination.frameLength = AVAudioFrameCount(dstStart + frames)
    }

    /// Hard peak limiter at the given ceiling (dBFS).
    @discardableResult
    static func limit(url: URL, ceilingDB: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let ceiling = Float(pow(10.0, ceilingDB / 20.0))
        for ch in 0..<channels {
            for i in 0..<frames {
                data[ch][i] = max(-ceiling, min(ceiling, data[ch][i]))
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_lim%.1f", ceilingDB))
    }

    /// Simple downward gate — attenuates samples below threshold.
    @discardableResult
    static func gate(url: URL, thresholdDB: Double, attenuationDB: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let threshold = Float(pow(10.0, thresholdDB / 20.0))
        let attenuation = Float(pow(10.0, attenuationDB / 20.0))
        for ch in 0..<channels {
            for i in 0..<frames {
                if abs(data[ch][i]) < threshold {
                    data[ch][i] *= attenuation
                }
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_gate%.0f", thresholdDB))
    }

    /// Tanh soft-clip saturation.
    @discardableResult
    static func softClip(url: URL, driveDB: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let drive = Float(pow(10.0, driveDB / 20.0))
        let norm = tanh(drive)
        for ch in 0..<channels {
            for i in 0..<frames {
                data[ch][i] = tanh(data[ch][i] * drive) / norm
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_clip%.0f", driveDB))
    }

    /// Bit-depth reduction (crush).
    @discardableResult
    static func bitCrush(url: URL, bits: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let levels = Float(pow(2.0, max(2, min(16, bits))))
        for ch in 0..<channels {
            for i in 0..<frames {
                data[ch][i] = round(data[ch][i] * levels) / levels
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_crush%.0f", bits))
    }

    /// Amplitude tremolo (LFO).
    @discardableResult
    static func tremolo(url: URL, rateHz: Double, depth: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let d = Float(max(0, min(1, depth)))
        for ch in 0..<channels {
            for i in 0..<frames {
                let t = Double(i) / sr
                let lfo = 1.0 - d + d * Float(sin(2.0 * Double.pi * rateHz * t))
                data[ch][i] *= lfo
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_trem%.1f", rateHz))
    }

    /// Fade in/out edges (milliseconds).
    @discardableResult
    static func fade(url: URL, inMs: Double, outMs: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let inFrames = min(Int(inMs / 1000.0 * sr), frames / 2)
        let outFrames = min(Int(outMs / 1000.0 * sr), frames / 2)
        for ch in 0..<channels {
            for i in 0..<inFrames {
                let g = Float(i) / Float(max(1, inFrames))
                data[ch][i] *= g
            }
            for i in 0..<outFrames {
                let g = Float(i) / Float(max(1, outFrames))
                data[ch][frames - 1 - i] *= g
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: "_fade")
    }

    /// Simple feedback delay.
    @discardableResult
    static func delay(url: URL, timeMs: Double, feedback: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let delayFrames = max(1, Int(timeMs / 1000.0 * sr))
        let fb = Float(max(0, min(0.95, feedback)))
        let wet = Float(max(0, min(1, mix)))
        let dry = 1 - wet

        var delayLines = Array(repeating: [Float](repeating: 0, count: delayFrames), count: channels)
        var writeIndex = 0

        for i in 0..<frames {
            for ch in 0..<channels {
                let drySample = data[ch][i]
                let delayed = delayLines[ch][writeIndex]
                let wetSample = drySample + delayed * fb
                delayLines[ch][writeIndex] = wetSample
                data[ch][i] = drySample * dry + wetSample * wet
            }
            writeIndex = (writeIndex + 1) % delayFrames
        }

        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_dly%.0f", timeMs))
    }

    /// Repeat a short grain (LUP-style stutter).
    @discardableResult
    static func stutter(url: URL, grainMs: Double, repeats: Double, startMs: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        let sr = format.sampleRate
        let totalFrames = Int(buffer.frameLength)
        let grainFrames = max(1, Int(grainMs / 1000.0 * sr))
        let startFrame = min(max(0, Int(startMs / 1000.0 * sr)), max(0, totalFrames - grainFrames))
        let count = max(1, Int(repeats))

        let endFrame = min(totalFrames, startFrame + grainFrames)
        let grain = try copySegment(of: buffer, format: format, startFrame: startFrame, endFrame: endFrame)
        let outFrames = grainFrames * count
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outFrames)),
              let src = grain.floatChannelData, let dst = out.floatChannelData else {
            throw EditError.bufferAllocation
        }
        let channels = Int(format.channelCount)
        for ch in 0..<channels {
            for rep in 0..<count {
                let offset = rep * grainFrames
                for i in 0..<grainFrames {
                    dst[ch][offset + i] = src[ch][i]
                }
            }
        }
        out.frameLength = AVAudioFrameCount(outFrames)

        return try writeNextToSource(out, format: format, source: url, suffix: String(format: "_stut%.0f", grainMs))
    }

    /// Band-pass via cascaded one-pole HPF + LPF.
    @discardableResult
    static func bandPass(url: URL, lowHz: Double, highHz: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        let channels = Int(format.channelCount)
        try applyOnePoleHighPass(buffer, sampleRate: format.sampleRate, cutoffHz: lowHz, channels: channels)
        try applyOnePoleLowPass(buffer, sampleRate: format.sampleRate, cutoffHz: highHz, channels: channels)
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_bp%.0f-%.0f", lowHz, highHz))
    }

    /// Ring modulation — multiply by a sine carrier.
    @discardableResult
    static func ringMod(url: URL, freqHz: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let wet = Float(max(0, min(1, mix)))
        let dry = 1 - wet
        for ch in 0..<channels {
            for i in 0..<frames {
                let t = Double(i) / sr
                let carrier = Float(sin(2.0 * Double.pi * freqHz * t))
                let sample = data[ch][i]
                data[ch][i] = sample * dry + (sample * carrier) * wet
            }
        }
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_rmod%.0f", freqHz))
    }

    /// STFT magnitude blur — smears spectral energy across neighboring bins.
    @discardableResult
    static func spectralBlur(url: URL, amount: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let wet = Float(max(0, min(1, mix)))
        let dry = 1 - wet
        let blurRadius = max(1, Int(amount * 48))

        for ch in 0..<channels {
            let drySamples = Array(UnsafeBufferPointer(start: data[ch], count: frames))
            let blurred = try spectralBlurChannel(drySamples, blurRadius: blurRadius)
            for i in 0..<frames {
                data[ch][i] = drySamples[i] * dry + blurred[i] * wet
            }
        }

        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_sblur%.0f", amount * 100))
    }

    /// Granular scatter — overlapping windowed grains placed at random positions.
    @discardableResult
    static func grainScatter(url: URL, grainMs: Double, density: Double, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let grainFrames = max(1, Int(grainMs / 1000.0 * sr))
        let maxStart = max(0, frames - grainFrames)
        guard maxStart > 0 else { throw EditError.emptyFile }

        let grainsPerSecond = max(1, density)
        let duration = Double(frames) / sr
        let grainCount = max(1, Int(grainsPerSecond * duration))

        var window = [Float](repeating: 0, count: grainFrames)
        vDSP_hann_window(&window, vDSP_Length(grainFrames), Int32(vDSP_HANN_NORM))

        var wet = Array(repeating: [Float](repeating: 0, count: frames), count: channels)
        var norm = [Float](repeating: 0, count: frames)
        let wetMix = Float(max(0, min(1, mix)))
        let dryMix = 1 - wetMix

        for _ in 0..<grainCount {
            let srcStart = Int.random(in: 0...maxStart)
            let dstStart = Int.random(in: 0...maxStart)
            for ch in 0..<channels {
                for i in 0..<grainFrames {
                    let dstIdx = dstStart + i
                    guard dstIdx < frames else { break }
                    let w = window[i]
                    wet[ch][dstIdx] += data[ch][srcStart + i] * w
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

        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_grain%.0f", grainMs))
    }

    /// Random segment walk — shuffled slices with short crossfades (glitch reorder).
    @discardableResult
    static func walk(url: URL, stepMs: Double, steps: Double, fadeMs: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        let sr = format.sampleRate
        let totalFrames = Int(buffer.frameLength)
        let stepFrames = max(1, Int(stepMs / 1000.0 * sr))
        let fadeFrames = min(max(0, Int(fadeMs / 1000.0 * sr)), stepFrames / 2)
        let count = max(2, Int(steps))
        let maxStart = max(0, totalFrames - stepFrames)
        guard maxStart > 0 else { throw EditError.emptyFile }

        var starts = (0..<count).map { _ in Int.random(in: 0...maxStart) }
        starts.shuffle()

        let overlap = fadeFrames * 2
        let outFrames = count * stepFrames - max(0, count - 1) * overlap
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outFrames)),
              let dst = out.floatChannelData else {
            throw EditError.bufferAllocation
        }
        let channels = Int(format.channelCount)
        for ch in 0..<channels {
            for i in 0..<outFrames { dst[ch][i] = 0 }
        }

        var writePos = 0
        for (idx, start) in starts.enumerated() {
            let segment = try copySegment(of: buffer, format: format, startFrame: start, endFrame: start + stepFrames)
            guard let src = segment.floatChannelData else { continue }
            for ch in 0..<channels {
                for i in 0..<stepFrames {
                    let outIdx = writePos + i
                    guard outIdx < outFrames else { break }
                    var g: Float = 1
                    if fadeFrames > 0 {
                        if idx > 0, i < fadeFrames {
                            g = Float(i) / Float(fadeFrames)
                        }
                        if idx < count - 1, i >= stepFrames - fadeFrames {
                            g = min(g, Float(stepFrames - 1 - i) / Float(fadeFrames))
                        }
                    }
                    dst[ch][outIdx] += src[ch][i] * g
                }
            }
            writePos += stepFrames - overlap
        }
        out.frameLength = AVAudioFrameCount(outFrames)

        return try writeNextToSource(out, format: format, source: url, suffix: String(format: "_walk%.0f", stepMs))
    }

    /// Layer the file with a time-offset (and optional reversed) copy of itself.
    @discardableResult
    static func combine(url: URL, offsetMs: Double, reverseLayer: Bool, mix: Double) throws -> URL {
        let (buffer, format) = try readAll(url)
        guard let data = buffer.floatChannelData else { throw EditError.bufferAllocation }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        let offsetFrames = Int(offsetMs / 1000.0 * sr)
        let wet = Float(max(0, min(1, mix)))
        let dry = 1 - wet

        var layer = Array(repeating: [Float](repeating: 0, count: frames), count: channels)
        for ch in 0..<channels {
            if reverseLayer {
                for i in 0..<frames { layer[ch][i] = data[ch][frames - 1 - i] }
            } else {
                for i in 0..<frames { layer[ch][i] = data[ch][i] }
            }
        }

        for ch in 0..<channels {
            for i in 0..<frames {
                let srcIdx = i - offsetFrames
                let layered = (srcIdx >= 0 && srcIdx < frames) ? layer[ch][srcIdx] : 0
                data[ch][i] = data[ch][i] * dry + layered * wet
            }
        }

        let tag = reverseLayer ? "rev" : "dly"
        return try writeNextToSource(buffer, format: format, source: url, suffix: String(format: "_mix_%@%.0f", tag, offsetMs))
    }

    private static func spectralBlurChannel(_ samples: [Float], blurRadius: Int) throws -> [Float] {
        let frames = samples.count
        guard frames > 0 else { return samples }

        let fftSize = 2048
        let hop = 512
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw EditError.bufferAllocation
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

                    var power = [Float](repeating: 0, count: fftSize / 2)
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(fftSize / 2))
                    let blurredPower = boxBlur(power, radius: blurRadius)

                    for i in 0..<fftSize / 2 {
                        let origMag = sqrt(max(power[i], 1e-12))
                        let newMag = sqrt(max(blurredPower[i], 1e-12))
                        let scale = newMag / origMag
                        realBuf[i] *= scale
                        imagBuf[i] *= scale
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
                            var splitOut = DSPSplitComplex(
                                realp: realBuf.baseAddress!,
                                imagp: imagBuf.baseAddress!
                            )
                            vDSP_ztoc(&splitOut, 1, complexPtr, 2, vDSP_Length(fftSize / 2))
                        }
                    }
                }
            }

            for i in 0..<fftSize where pos + i < frames {
                let w = window[i]
                output[pos + i] += reconstructed[i] * w
                norm[pos + i] += w * w
            }

            pos += hop
        }

        for i in 0..<frames where norm[i] > 1e-6 {
            output[i] /= norm[i]
        }
        return output
    }

    private static func boxBlur(_ input: [Float], radius: Int) -> [Float] {
        guard radius > 0, !input.isEmpty else { return input }
        var output = [Float](repeating: 0, count: input.count)
        for i in 0..<input.count {
            let lo = max(0, i - radius)
            let hi = min(input.count - 1, i + radius)
            var sum: Float = 0
            for j in lo...hi { sum += input[j] }
            output[i] = sum / Float(hi - lo + 1)
        }
        return output
    }
}
