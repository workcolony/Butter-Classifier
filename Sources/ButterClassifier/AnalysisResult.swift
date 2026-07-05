import Foundation
import Yams

/// Parsed contents of an audio_analyzer.py YAML output file.
struct AnalysisResult {
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
    var onsetInfos: [OnsetInfo] = []

    struct OnsetInfo {
        var onset: Double
        var loudness: Double
        var bands: [Double]
        var bandBools: [Int]
    }

    static func load(from url: URL) -> AnalysisResult? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let root = try? Yams.load(yaml: text) as? [String: Any] else {
            return nil
        }

        func num(_ key: String) -> Double? {
            if let d = root[key] as? Double { return d }
            if let i = root[key] as? Int { return Double(i) }
            return nil
        }
        func numArray(_ value: Any?) -> [Double] {
            (value as? [Any])?.compactMap {
                if let d = $0 as? Double { return d }
                if let i = $0 as? Int { return Double(i) }
                return nil
            } ?? []
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
        r.onsetTimes = numArray(root["onset_times"])
        r.rms = numArray(root["rms"])
        r.spectralCentroids = numArray(root["spectral_centroids"])

        if let infos = root["onset_infos"] as? [[String: Any]] {
            r.onsetInfos = infos.compactMap { info in
                guard let onset = info["onset"] as? Double ?? (info["onset"] as? Int).map(Double.init) else { return nil }
                let loudness = info["loudness"] as? Double ?? 0
                let bands = numArray(info["bands"])
                let bandBools = (info["band_bools"] as? [Any])?.compactMap { $0 as? Int } ?? []
                return OnsetInfo(onset: onset, loudness: loudness, bands: bands, bandBools: bandBools)
            }
        }
        return r
    }
}
