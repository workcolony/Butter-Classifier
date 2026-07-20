import Foundation

struct CachedSpectralData {
    var duration: Double?
    var rms: [Double]
    var spectralCentroids: [Double]
    var chroma: [[Double]]
    var chromaSmooth: [(hue: Double, saturation: Double, lightness: Double)]
}

/// In-memory + on-disk cache for decoded waveform peaks and upsampled spectral data.
/// Sidecar files live next to each sample, matching the YAML naming pattern:
///   `sample.wav` → `sample.wav.yaml`, `sample.wav.wfc`, `sample.wav.sfc`, `sample.wav.rsp`
actor WaveformCache {
    static let shared = WaveformCache()

    private var waveformMemory: [String: WaveformData] = [:]
    private var spectralMemory: [String: (yamlModifiedAt: Date, data: CachedSpectralData)] = [:]
    private var spectrogramMemory: [String: (audioModifiedAt: Date, data: SpectrogramData)] = [:]
    /// Bump when spectrogram compute/format changes so in-memory entries invalidate.
    private static let spectrogramAlgoVersion = 3

    func waveform(for url: URL, mode: WaveformMode) async -> WaveformData {
        switch mode {
        case .original:
            let canonical = await loadCanonicalWaveform(url: url)
            guard canonical.mins.count > 0 else { return canonical }
            return WaveformLoader.subsample(canonical, to: WaveformLoader.displayBins)
        case .supersample:
            return await loadSupersampleWaveform(url: url)
        default:
            return await loadCanonicalWaveform(url: url)
        }
    }

    func spectrogram(for audioURL: URL) async -> SpectrogramData? {
        let key = "\(audioURL.path)|rsp\(Self.spectrogramAlgoVersion)"
        let audioModifiedAt = fileModificationDate(audioURL) ?? .distantPast
        if let cached = spectrogramMemory[key], cached.audioModifiedAt == audioModifiedAt {
            return cached.data
        }

        if let disk = readSpectrogramDiskCache(audioURL: audioURL) {
            spectrogramMemory[key] = (audioModifiedAt: audioModifiedAt, data: disk)
            return disk
        }

        let path = audioURL.path
        let computed = await Task.detached(priority: .utility) {
            try? ResonateSpectrogram.compute(url: URL(fileURLWithPath: path))
        }.value
        guard let computed, !computed.isEmpty else { return nil }

        spectrogramMemory[key] = (audioModifiedAt: audioModifiedAt, data: computed)
        writeSpectrogramDiskCache(audioURL: audioURL, data: computed)
        return computed
    }

    func spectral(for yamlURL: URL, audioURL: URL) async -> CachedSpectralData? {
        let key = yamlURL.path
        let yamlModifiedAt = fileModificationDate(yamlURL) ?? .distantPast
        if let cached = spectralMemory[key], cached.yamlModifiedAt == yamlModifiedAt {
            return cached.data
        }

        if let disk = readSpectralDiskCache(audioURL: audioURL, yamlURL: yamlURL) {
            spectralMemory[key] = (yamlModifiedAt: yamlModifiedAt, data: disk)
            return disk
        }

        let yamlPath = yamlURL.path
        let result = await Task.detached(priority: .utility) {
            AnalysisResult.load(from: URL(fileURLWithPath: yamlPath))
        }.value
        guard let result else { return nil }

        let raw = CachedSpectralData(
            duration: result.duration,
            rms: result.rms,
            spectralCentroids: result.spectralCentroids,
            chroma: result.chroma,
            chromaSmooth: result.chromaSmooth
        )
        let upsampled = SpectralUpsampler.upsample(raw, duration: result.duration)
        spectralMemory[key] = (yamlModifiedAt: yamlModifiedAt, data: upsampled)
        writeSpectralDiskCache(audioURL: audioURL, yamlURL: yamlURL, data: upsampled)
        return upsampled
    }

    private func loadCanonicalWaveform(url: URL) async -> WaveformData {
        let bins = WaveformLoader.canonicalBins
        let key = cacheKey(url: url, bins: bins)
        if let cached = waveformMemory[key] { return cached }

        if let legacy = readLegacyWaveformDiskCache(for: url) {
            waveformMemory[key] = legacy
            writeWaveformBlob(to: waveformCacheURL(for: url), audioURL: url, data: legacy)
            return legacy
        }

        if let disk = readWaveformDiskCache(for: url) {
            waveformMemory[key] = disk
            return disk
        }

        let audioPath = url.path
        let decoded = await Task.detached(priority: .userInitiated) {
            try? WaveformLoader.load(url: URL(fileURLWithPath: audioPath), bins: bins)
        }.value ?? .empty

        waveformMemory[key] = decoded
        if decoded.mins.count > 0 {
            writeWaveformBlob(to: waveformCacheURL(for: url), audioURL: url, data: decoded)
        }
        return decoded
    }

    private func loadSupersampleWaveform(url: URL) async -> WaveformData {
        let bins = WaveformLoader.supersampleBins
        let key = cacheKey(url: url, bins: bins)
        if let cached = waveformMemory[key] { return cached }

        if let disk = readWaveformBlob(from: supersampleCacheURL(for: url), audioURL: url) {
            waveformMemory[key] = disk
            return disk
        }

        let audioPath = url.path
        let decoded = await Task.detached(priority: .userInitiated) {
            try? WaveformLoader.load(url: URL(fileURLWithPath: audioPath), bins: bins)
        }.value ?? .empty

        waveformMemory[key] = decoded
        if decoded.mins.count > 0 {
            writeWaveformBlob(to: supersampleCacheURL(for: url), audioURL: url, data: decoded)
        }
        return decoded
    }

    private func cacheKey(url: URL, bins: Int) -> String {
        let mtime = fileModificationDate(url)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(mtime)|\(bins)"
    }

    private func fileModificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func waveformCacheURL(for audioURL: URL) -> URL {
        URL(fileURLWithPath: audioURL.path + ".wfc")
    }

    private func supersampleCacheURL(for audioURL: URL) -> URL {
        URL(fileURLWithPath: audioURL.path + ".wfx")
    }

    private func spectralCacheURL(for audioURL: URL) -> URL {
        URL(fileURLWithPath: audioURL.path + ".sfc")
    }

    private func spectrogramCacheURL(for audioURL: URL) -> URL {
        URL(fileURLWithPath: audioURL.path + ".rsp")
    }

    /// Previous cache location (`sample.wfc`) — migrated to `sample.wav.wfc` on read.
    private func legacyWaveformCacheURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("wfc")
    }

    private func readLegacyWaveformDiskCache(for audioURL: URL) -> WaveformData? {
        readWaveformBlob(from: legacyWaveformCacheURL(for: audioURL), audioURL: audioURL)
    }

    private func readWaveformDiskCache(for audioURL: URL) -> WaveformData? {
        readWaveformBlob(from: waveformCacheURL(for: audioURL), audioURL: audioURL)
    }

    private func readWaveformBlob(from cacheURL: URL, audioURL: URL) -> WaveformData? {
        guard let data = try? Data(contentsOf: cacheURL), data.count >= 24 else { return nil }
        guard String(data: data.prefix(4), encoding: .ascii) == "WFC1" else { return nil }

        let sourceMtime = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: TimeInterval.self) }
        let audioMtime = fileModificationDate(audioURL)?.timeIntervalSince1970 ?? -1
        guard abs(sourceMtime - audioMtime) < 0.001 else { return nil }

        let duration = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Double.self) }
        let binCount = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) })
        guard binCount > 0, binCount <= 16_384 else { return nil }

        let header = 24
        let payload = binCount * 2 * MemoryLayout<Float>.size
        guard data.count >= header + payload else { return nil }

        var maxs = [Float](repeating: 0, count: binCount)
        var mins = [Float](repeating: 0, count: binCount)
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            maxs.withUnsafeMutableBytes { dst in
                guard let address = dst.baseAddress else { return }
                memcpy(address, base.advanced(by: header), binCount * MemoryLayout<Float>.size)
            }
            mins.withUnsafeMutableBytes { dst in
                guard let address = dst.baseAddress else { return }
                memcpy(
                    address,
                    base.advanced(by: header + binCount * MemoryLayout<Float>.size),
                    binCount * MemoryLayout<Float>.size
                )
            }
        }
        return WaveformData(mins: mins, maxs: maxs, duration: duration)
    }

    private func writeWaveformDiskCache(for audioURL: URL, data: WaveformData) {
        writeWaveformBlob(to: waveformCacheURL(for: audioURL), audioURL: audioURL, data: data)
    }

    private func writeWaveformBlob(to cacheURL: URL, audioURL: URL, data: WaveformData) {
        let count = data.mins.count
        guard count > 0, count == data.maxs.count else { return }

        var blob = Data()
        blob.append(contentsOf: Array("WFC1".utf8))
        var mtime = fileModificationDate(audioURL)?.timeIntervalSince1970 ?? 0
        var duration = data.duration
        var binCount = UInt32(count)
        blob.append(Data(bytes: &mtime, count: MemoryLayout<TimeInterval>.size))
        blob.append(Data(bytes: &duration, count: MemoryLayout<Double>.size))
        blob.append(Data(bytes: &binCount, count: MemoryLayout<UInt32>.size))
        data.maxs.withUnsafeBytes { blob.append(contentsOf: $0) }
        data.mins.withUnsafeBytes { blob.append(contentsOf: $0) }

        try? blob.write(to: cacheURL, options: .atomic)
    }

    private func readSpectralDiskCache(audioURL: URL, yamlURL: URL) -> CachedSpectralData? {
        let cacheURL = spectralCacheURL(for: audioURL)
        guard let data = try? Data(contentsOf: cacheURL), data.count >= 36 else { return nil }
        guard String(data: data.prefix(4), encoding: .ascii) == "SFC1" else { return nil }

        let yamlMtime = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: TimeInterval.self) }
        let currentYamlMtime = fileModificationDate(yamlURL)?.timeIntervalSince1970 ?? -1
        guard abs(yamlMtime - currentYamlMtime) < 0.001 else { return nil }

        let frameCount = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) })
        guard frameCount > 0, frameCount <= 16_384 else { return nil }

        let duration = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: Double.self) }
        let pitchClasses = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) })
        guard pitchClasses == 12 else { return nil }

        let header = 28
        let rmsBytes = frameCount * MemoryLayout<Float>.size
        let centroidBytes = frameCount * MemoryLayout<Float>.size
        let chromaBytes = frameCount * pitchClasses * MemoryLayout<Float>.size
        let smoothBytes = frameCount * 3 * MemoryLayout<Float>.size
        guard data.count >= header + rmsBytes + centroidBytes + chromaBytes + smoothBytes else { return nil }

        func readFloats(offset: Int, count: Int) -> [Double] {
            var values = [Float](repeating: 0, count: count)
            data.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                values.withUnsafeMutableBytes { dst in
                    guard let address = dst.baseAddress else { return }
                    memcpy(address, base.advanced(by: offset), count * MemoryLayout<Float>.size)
                }
            }
            return values.map(Double.init)
        }

        var offset = header
        let rms = readFloats(offset: offset, count: frameCount)
        offset += rmsBytes
        let centroids = readFloats(offset: offset, count: frameCount)
        offset += centroidBytes
        let chromaFlat = readFloats(offset: offset, count: frameCount * pitchClasses)
        offset += chromaBytes
        let smoothFlat = readFloats(offset: offset, count: frameCount * 3)

        let chroma: [[Double]] = (0..<frameCount).map { frame in
            let base = frame * pitchClasses
            return Array(chromaFlat[base..<(base + pitchClasses)])
        }
        let chromaSmooth: [(hue: Double, saturation: Double, lightness: Double)] = (0..<frameCount).map { frame in
            let base = frame * 3
            return (hue: smoothFlat[base], saturation: smoothFlat[base + 1], lightness: smoothFlat[base + 2])
        }

        return CachedSpectralData(
            duration: duration,
            rms: rms,
            spectralCentroids: centroids,
            chroma: chroma,
            chromaSmooth: chromaSmooth
        )
    }

    private func writeSpectralDiskCache(audioURL: URL, yamlURL: URL, data: CachedSpectralData) {
        let frameCount = data.chroma.count
        guard frameCount > 0,
              data.rms.count == frameCount,
              data.spectralCentroids.count == frameCount,
              data.chromaSmooth.count == frameCount else { return }

        let pitchClasses = 12
        var blob = Data()
        blob.append(contentsOf: Array("SFC1".utf8))
        var yamlMtime = fileModificationDate(yamlURL)?.timeIntervalSince1970 ?? 0
        var frameCount32 = UInt32(frameCount)
        var duration = data.duration ?? 0
        var pitchCount32 = UInt32(pitchClasses)
        blob.append(Data(bytes: &yamlMtime, count: MemoryLayout<TimeInterval>.size))
        blob.append(Data(bytes: &frameCount32, count: MemoryLayout<UInt32>.size))
        blob.append(Data(bytes: &duration, count: MemoryLayout<Double>.size))
        blob.append(Data(bytes: &pitchCount32, count: MemoryLayout<UInt32>.size))

        appendFloats(data.rms.map(Float.init), to: &blob)
        appendFloats(data.spectralCentroids.map(Float.init), to: &blob)
        let chromaFlat = data.chroma.flatMap { row in
            (0..<pitchClasses).map { pitch in
                Float(pitch < row.count ? row[pitch] : 0)
            }
        }
        appendFloats(chromaFlat, to: &blob)
        let smoothFlat = data.chromaSmooth.flatMap { frame in
            [Float(frame.hue), Float(frame.saturation), Float(frame.lightness)]
        }
        appendFloats(smoothFlat, to: &blob)

        try? blob.write(to: spectralCacheURL(for: audioURL), options: .atomic)
    }

    private func appendFloats(_ values: [Float], to blob: inout Data) {
        values.withUnsafeBytes { blob.append(contentsOf: $0) }
    }

    // MARK: - Spectrogram disk cache (RSP1)

    private func readSpectrogramDiskCache(audioURL: URL) -> SpectrogramData? {
        let cacheURL = spectrogramCacheURL(for: audioURL)
        guard let data = try? Data(contentsOf: cacheURL), data.count >= 48 else { return nil }
        guard String(data: data.prefix(4), encoding: .ascii) == "RSP3" else { return nil }

        let sourceMtime = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: TimeInterval.self) }
        let audioMtime = fileModificationDate(audioURL)?.timeIntervalSince1970 ?? -1
        guard abs(sourceMtime - audioMtime) < 0.001 else { return nil }

        let duration = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Double.self) }
        let sampleRate = data.withUnsafeBytes { $0.load(fromByteOffset: 20, as: Double.self) }
        let bandCount = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) })
        let frameCount = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt32.self) })
        let hopSamples = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 36, as: UInt32.self) })
        let minDB = data.withUnsafeBytes { $0.load(fromByteOffset: 40, as: Float.self) }
        let maxDB = data.withUnsafeBytes { $0.load(fromByteOffset: 44, as: Float.self) }

        guard bandCount > 0, bandCount <= 512,
              frameCount > 0, frameCount <= 500_000 else { return nil }

        let header = 48
        let payload = bandCount * frameCount * MemoryLayout<Float>.size
        guard data.count >= header + payload else { return nil }

        var powers = [Float](repeating: 0, count: bandCount * frameCount)
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            powers.withUnsafeMutableBytes { dst in
                guard let address = dst.baseAddress else { return }
                memcpy(address, base.advanced(by: header), payload)
            }
        }

        return SpectrogramData(
            duration: duration,
            sampleRate: sampleRate,
            bandCount: bandCount,
            frameCount: frameCount,
            hopSamples: hopSamples,
            powersDB: powers,
            minDB: minDB,
            maxDB: maxDB
        )
    }

    private func writeSpectrogramDiskCache(audioURL: URL, data: SpectrogramData) {
        guard !data.isEmpty,
              data.powersDB.count == data.bandCount * data.frameCount else { return }

        var blob = Data()
        blob.append(contentsOf: Array("RSP3".utf8))
        var mtime = fileModificationDate(audioURL)?.timeIntervalSince1970 ?? 0
        var duration = data.duration
        var sampleRate = data.sampleRate
        var bandCount = UInt32(data.bandCount)
        var frameCount = UInt32(data.frameCount)
        var hopSamples = UInt32(data.hopSamples)
        var minDB = data.minDB
        var maxDB = data.maxDB
        blob.append(Data(bytes: &mtime, count: MemoryLayout<TimeInterval>.size))
        blob.append(Data(bytes: &duration, count: MemoryLayout<Double>.size))
        blob.append(Data(bytes: &sampleRate, count: MemoryLayout<Double>.size))
        blob.append(Data(bytes: &bandCount, count: MemoryLayout<UInt32>.size))
        blob.append(Data(bytes: &frameCount, count: MemoryLayout<UInt32>.size))
        blob.append(Data(bytes: &hopSamples, count: MemoryLayout<UInt32>.size))
        blob.append(Data(bytes: &minDB, count: MemoryLayout<Float>.size))
        blob.append(Data(bytes: &maxDB, count: MemoryLayout<Float>.size))
        data.powersDB.withUnsafeBytes { blob.append(contentsOf: $0) }

        try? blob.write(to: spectrogramCacheURL(for: audioURL), options: .atomic)
    }
}
