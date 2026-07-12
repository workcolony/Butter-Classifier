import Foundation
import Yams

/// Parsed contents of an audio_analyzer.py YAML output file.
struct AnalysisResult {
    enum LoadMode {
        /// Waveform / chromagram views — all arrays.
        case full
        /// Library index + scan cache — scalars, onset data, subsampled rms/centroids.
        case index
        /// Tag suggestions — scalars + onset band data only.
        case tagging
    }

    var duration: Double?
    var bpm: Double?
    var loudnessLUFS: Double?
    var kickiness: Double?
    var swing8th: Double?
    var swing16th: Double?
    var pitchSalience: Double?
    var sampleRate: Int?
    var onsetTimes: [Double] = []
    var rms: [Double] = []
    var spectralCentroids: [Double] = []
    var chroma: [[Double]] = []
    var chromaSmooth: [(hue: Double, saturation: Double, lightness: Double)] = []
    var onsetInfos: [OnsetInfo] = []

    struct OnsetInfo {
        var onset: Double
        var loudness: Double
        var bands: [Double]
        var bandBools: [Int]
    }

    static func load(from url: URL) -> AnalysisResult? {
        load(from: url, mode: .full)
    }

    static func load(from url: URL, mode: LoadMode) -> AnalysisResult? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let root = try? Yams.load(yaml: text) as? [String: Any] else {
            return nil
        }

        func num(_ key: String) -> Double? {
            YAMLValues.double(root[key])
        }
        func numArray(_ value: Any?) -> [Double] {
            YAMLValues.doubleArray(value)
        }
        func sampledArray(_ value: Any?, maxCount: Int) -> [Double] {
            let full = numArray(value)
            guard full.count > maxCount else { return full }
            let step = Double(full.count) / Double(maxCount)
            return (0..<maxCount).map { i in
                full[min(full.count - 1, Int(Double(i) * step))]
            }
        }

        var r = AnalysisResult()
        r.duration = num("duration")
        r.bpm = num("bpm_est")
        r.loudnessLUFS = num("integrated_loudness_ebur128")
        r.kickiness = num("kickiness")
        r.swing8th = num("avg_swing_8th")
        r.swing16th = num("avg_swing_16th")
        r.pitchSalience = num("pitch_salience")
        r.sampleRate = root["sample_rate"] as? Int

        switch mode {
        case .full:
            r.onsetTimes = numArray(root["onset_times"])
            r.rms = numArray(root["rms"])
            r.spectralCentroids = numArray(root["spectral_centroids"])
            if let chromaFrames = root["chroma"] as? [[Any]] {
                r.chroma = chromaFrames.map { frame in
                    let values = numArray(frame as Any?)
                    return values.count == 12 ? values : Array(values.prefix(12))
                }.filter { $0.count == 12 }
            }
            if let smoothFrames = root["chroma_smooth"] as? [[Any]] {
                r.chromaSmooth = smoothFrames.compactMap { frame in
                    let values = numArray(frame as Any?)
                    guard values.count >= 3 else { return nil }
                    return (hue: values[0], saturation: values[1], lightness: values[2])
                }
            }
            if let infos = root["onset_infos"] as? [[String: Any]] {
                r.onsetInfos = parseOnsetInfos(infos, numArray: numArray)
            }
        case .index:
            r.rms = sampledArray(root["rms"], maxCount: 256)
            r.spectralCentroids = sampledArray(root["spectral_centroids"], maxCount: 256)
        case .tagging:
            r.onsetTimes = numArray(root["onset_times"])
            if let infos = root["onset_infos"] as? [[String: Any]] {
                r.onsetInfos = parseOnsetInfos(infos, numArray: numArray)
            }
        }
        return r
    }

    private static func parseOnsetInfos(
        _ infos: [[String: Any]],
        numArray: (Any?) -> [Double]
    ) -> [OnsetInfo] {
        infos.compactMap { info in
            guard let onset = info["onset"] as? Double ?? (info["onset"] as? Int).map(Double.init) else { return nil }
            let loudness = info["loudness"] as? Double ?? 0
            let bands = numArray(info["bands"])
            let bandBools = (info["band_bools"] as? [Any])?.compactMap { $0 as? Int } ?? []
            return OnsetInfo(onset: onset, loudness: loudness, bands: bands, bandBools: bandBools)
        }
    }
}
