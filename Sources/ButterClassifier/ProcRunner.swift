import Foundation

enum ProcRunner {
    enum ProcError: LocalizedError {
        case unknownRoutine(String)
        case invalidParams(String)
        case emptyChain

        var errorDescription: String? {
            switch self {
            case .unknownRoutine(let id): return "Unknown PROC routine: \(id)"
            case .invalidParams(let msg): return msg
            case .emptyChain: return "PROC chain is empty."
            }
        }
    }

    /// Runs one routine, writing a new WAV next to the source (or into temp for preview).
    @discardableResult
    static func run(
        routine: ProcRoutine,
        params: [String: Double],
        sourceURL: URL,
        preview: Bool,
        inputGainDB: Double = 0
    ) throws -> URL {
        guard abs(inputGainDB) > 0.001 else {
            let out = try execute(routine: routine, params: params, sourceURL: sourceURL, outputFolder: nil)
            return try finalize(out, preview: preview, sourceURL: sourceURL)
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("butter-proc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let gained = try prepareSource(sourceURL, gainDB: inputGainDB, workDir: workDir)
        let out = try execute(routine: routine, params: params, sourceURL: gained, outputFolder: workDir)

        if preview {
            return try finalize(out, preview: true, sourceURL: sourceURL)
        }
        return try commitBesideSource(
            out,
            originalSource: sourceURL,
            lastRoutineID: routine.id,
            stepCount: 1,
            commitSuffix: nil
        )
    }

    /// Runs a script chain. Intermediate steps use a temp work folder; the final step commits beside the source.
    @discardableResult
    static func runChain(
        steps: [ProcScriptStep],
        sourceURL: URL,
        preview: Bool,
        commitSuffix: String? = nil,
        inputGainDB: Double = 0
    ) throws -> URL {
        guard !steps.isEmpty else { throw ProcError.emptyChain }
        let catalog = ProcCatalog.shared
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("butter-proc-chain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var current = try prepareSource(sourceURL, gainDB: inputGainDB, workDir: workDir)

        for step in steps {
            guard let routine = catalog.routine(id: step.routineID) else {
                throw ProcError.unknownRoutine(step.routineID)
            }
            let out = try execute(
                routine: routine,
                params: step.params,
                sourceURL: current,
                outputFolder: workDir
            )
            current = out
        }

        if preview {
            return try finalize(current, preview: true, sourceURL: sourceURL)
        }

        let committed = try commitBesideSource(
            current,
            originalSource: sourceURL,
            lastRoutineID: steps.last!.routineID,
            stepCount: steps.count,
            commitSuffix: commitSuffix
        )
        return committed
    }

    /// e.g. "Ring Mod" → "_ring-mod", "Spectral Smear" → "_spectral-smear"
    static func suffixFromPresetName(_ name: String) -> String {
        let slug = name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "_\(slug.isEmpty ? "proc" : slug)"
    }

    private static func resolveCommitSuffix(
        explicit: String?,
        lastRoutineID: String,
        stepCount: Int
    ) -> String {
        if let explicit, !explicit.isEmpty {
            return explicit.hasPrefix("_") ? explicit : "_\(explicit)"
        }
        if stepCount == 1, let routineSuffix = ProcCatalog.shared.routine(id: lastRoutineID)?.suffix {
            return routineSuffix
        }
        return "_proc"
    }

    /// Applies input gain into the work folder so the original sample is never modified.
    private static func prepareSource(_ sourceURL: URL, gainDB: Double, workDir: URL) throws -> URL {
        guard abs(gainDB) > 0.001 else { return sourceURL }
        let produced = try AudioEditor.applyGain(url: sourceURL, gainDB: gainDB)
        if produced.deletingLastPathComponent().standardizedFileURL == workDir.standardizedFileURL {
            return produced
        }
        let base = sourceURL.deletingPathExtension().lastPathComponent + "_ingain"
        let dest = AudioEditor.uniqueURL(inFolder: workDir, baseName: base)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: produced, to: dest)
        return dest
    }

    /// Moves (or copies) the chain result next to the original sample — intermediate
    /// steps render into a temp folder that is deleted when this function returns.
    private static func commitBesideSource(
        _ url: URL,
        originalSource: URL,
        lastRoutineID: String,
        stepCount: Int,
        commitSuffix: String?
    ) throws -> URL {
        let destFolder = originalSource.deletingLastPathComponent()
        if url.deletingLastPathComponent().standardizedFileURL == destFolder.standardizedFileURL {
            return url
        }
        let suffix = resolveCommitSuffix(
            explicit: commitSuffix,
            lastRoutineID: lastRoutineID,
            stepCount: stepCount
        )
        let base = originalSource.deletingPathExtension().lastPathComponent + suffix
        let dest = AudioEditor.uniqueURL(inFolder: destFolder, baseName: base)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            try FileManager.default.copyItem(at: url, to: dest)
            try? FileManager.default.removeItem(at: url)
        }
        return dest
    }

    private static func execute(
        routine: ProcRoutine,
        params: [String: Double],
        sourceURL: URL,
        outputFolder: URL?
    ) throws -> URL {
        let produced: URL
        switch routine.id {
        case "gain":
            let db = params["db"] ?? routine.params.first?.default ?? 0
            produced = try AudioEditor.applyGain(url: sourceURL, gainDB: db)
        case "normalize":
            let target = params["target"] ?? routine.params.first?.default ?? -0.3
            produced = try AudioEditor.normalize(url: sourceURL, targetDBFS: target)
        case "reverse":
            produced = try AudioEditor.reverse(url: sourceURL)
        case "lpf":
            let cutoff = params["cutoff"] ?? routine.params.first?.default ?? 8000
            produced = try AudioEditor.lowPass(url: sourceURL, cutoffHz: cutoff)
        case "hpf":
            let cutoff = params["cutoff"] ?? routine.params.first?.default ?? 120
            produced = try AudioEditor.highPass(url: sourceURL, cutoffHz: cutoff)
        case "crop":
            let start = params["start"] ?? 0
            let end = params["end"] ?? 1
            guard end > start else { throw ProcError.invalidParams("Crop end must be after start.") }
            produced = try AudioEditor.trim(url: sourceURL, start: start, end: end, fadeMs: 2)
        case "limit":
            let ceiling = params["ceiling"] ?? routine.params.first?.default ?? -1
            produced = try AudioEditor.limit(url: sourceURL, ceilingDB: ceiling)
        case "gate":
            let threshold = params["threshold"] ?? -40
            let attenuation = params["attenuation"] ?? -24
            produced = try AudioEditor.gate(url: sourceURL, thresholdDB: threshold, attenuationDB: attenuation)
        case "clip":
            let drive = params["drive"] ?? routine.params.first?.default ?? 12
            produced = try AudioEditor.softClip(url: sourceURL, driveDB: drive)
        case "crush":
            let bits = params["bits"] ?? routine.params.first?.default ?? 8
            produced = try AudioEditor.bitCrush(url: sourceURL, bits: bits)
        case "tremolo":
            let rate = params["rate"] ?? 6
            let depth = params["depth"] ?? 0.8
            produced = try AudioEditor.tremolo(url: sourceURL, rateHz: rate, depth: depth)
        case "fade":
            let inMs = params["in"] ?? 10
            let outMs = params["out"] ?? 50
            produced = try AudioEditor.fade(url: sourceURL, inMs: inMs, outMs: outMs)
        case "delay":
            let time = params["time"] ?? 180
            let feedback = params["feedback"] ?? 0.35
            let mix = params["mix"] ?? 0.35
            produced = try AudioEditor.delay(url: sourceURL, timeMs: time, feedback: feedback, mix: mix)
        case "stutter":
            let grain = params["grain"] ?? 80
            let repeats = params["repeats"] ?? 8
            let start = params["start"] ?? 0
            produced = try AudioEditor.stutter(url: sourceURL, grainMs: grain, repeats: repeats, startMs: start)
        case "bandpass":
            let low = params["low"] ?? 200
            let high = params["high"] ?? 4000
            guard high > low else { throw ProcError.invalidParams("Band-pass high must be above low.") }
            produced = try AudioEditor.bandPass(url: sourceURL, lowHz: low, highHz: high)
        case "ringmod":
            let freq = params["freq"] ?? 440
            let mix = params["mix"] ?? 1
            produced = try AudioEditor.ringMod(url: sourceURL, freqHz: freq, mix: mix)
        case "spectblur":
            let amount = params["amount"] ?? 0.5
            let mix = params["mix"] ?? 0.85
            produced = try AudioEditor.spectralBlur(url: sourceURL, amount: amount, mix: mix)
        case "grain":
            let grain = params["grain"] ?? 40
            let density = params["density"] ?? 24
            let mix = params["mix"] ?? 0.75
            produced = try AudioEditor.grainScatter(url: sourceURL, grainMs: grain, density: density, mix: mix)
        case "walk":
            let step = params["step"] ?? 120
            let steps = params["steps"] ?? 16
            let fade = params["fade"] ?? 8
            produced = try AudioEditor.walk(url: sourceURL, stepMs: step, steps: steps, fadeMs: fade)
        case "combine":
            let offset = params["offset"] ?? 80
            let reverse = (params["reverse"] ?? 0) >= 0.5
            let mix = params["mix"] ?? 0.45
            produced = try AudioEditor.combine(url: sourceURL, offsetMs: offset, reverseLayer: reverse, mix: mix)
        case "degrade":
            produced = try ProcEffects.degrade(
                url: sourceURL,
                bits: params["bits"] ?? 8,
                rateRatio: params["rate"] ?? 0.35,
                mirror: params["mirror"] ?? 0.85,
                mix: params["mix"] ?? 1
            )
        case "phaser":
            produced = try ProcEffects.phaser(
                url: sourceURL,
                baseFreq: params["base"] ?? 800,
                q: params["q"] ?? 0.7,
                spread: params["spread"] ?? 400,
                stages: params["stages"] ?? 6,
                feedback: params["feedback"] ?? 0.3,
                mix: params["mix"] ?? 0.65
            )
        case "freqshift":
            produced = try ProcEffects.freqShift(
                url: sourceURL,
                shiftHz: params["shift"] ?? 40,
                feedback: params["feedback"] ?? 0.2,
                mix: params["mix"] ?? 0.75
            )
        case "waveshape":
            produced = try ProcEffects.waveShape(
                url: sourceURL,
                drive: params["drive"] ?? 18,
                preCutoff: params["pre"] ?? 6000,
                postCutoff: params["post"] ?? 9000,
                mix: params["mix"] ?? 0.85
            )
        case "parameq":
            produced = try ProcEffects.paramEQ(
                url: sourceURL,
                freq: params["freq"] ?? 1200,
                q: params["q"] ?? 1.2,
                gainDb: params["gain"] ?? 10
            )
        case "statevar":
            produced = try ProcEffects.stateVar(
                url: sourceURL,
                cutoff: params["cutoff"] ?? 1800,
                q: params["q"] ?? 0.8,
                mode: params["mode"] ?? 0,
                mix: params["mix"] ?? 1
            )
        case "granulate":
            produced = try ProcEffects.granulate(
                url: sourceURL,
                position: params["position"] ?? 0.5,
                grainMs: params["grain"] ?? 45,
                density: params["density"] ?? 28,
                pitchJitter: params["pitch"] ?? 50,
                mix: params["mix"] ?? 0.8
            )
        case "vocoder":
            produced = try ProcEffects.vocoder(
                url: sourceURL,
                bands: params["bands"] ?? 12,
                baseFreq: params["base"] ?? 200,
                spread: params["spread"] ?? 1.35,
                q: params["q"] ?? 1.5,
                mix: params["mix"] ?? 0.85
            )
        case "harmonizer":
            produced = try ProcEffects.harmonizer(
                url: sourceURL,
                voice1: params["voice1"] ?? 7,
                voice2: params["voice2"] ?? -5,
                mix: params["mix"] ?? 0.55
            )
        case "spectralgate":
            produced = try ProcEffects.spectralGate(
                url: sourceURL,
                thresholdDB: params["threshold"] ?? -36,
                mix: params["mix"] ?? 1
            )
        case "spectraldelay":
            produced = try ProcEffects.spectralDelay(
                url: sourceURL,
                timeMs: params["time"] ?? 120,
                feedback: params["feedback"] ?? 0.5,
                mix: params["mix"] ?? 0.7
            )
        case "spectralshift":
            produced = try ProcEffects.spectralShift(
                url: sourceURL,
                shiftHz: params["shift"] ?? 80,
                mix: params["mix"] ?? 0.8
            )
        case "resonators":
            produced = try ProcEffects.resonators(
                url: sourceURL,
                baseFreq: params["base"] ?? 220,
                detune: params["detune"] ?? 0.4,
                decay: params["decay"] ?? 0.9,
                mix: params["mix"] ?? 0.65
            )
        case "particle":
            produced = try ProcEffects.particle(
                url: sourceURL,
                grainMs: params["grain"] ?? 50,
                density: params["density"] ?? 32,
                posRand: params["posRand"] ?? 0.6,
                pitchRand: params["pitchRand"] ?? 80,
                mix: params["mix"] ?? 0.85
            )
        default:
            throw ProcError.unknownRoutine(routine.id)
        }

        guard let folder = outputFolder else { return produced }
        let base = "\(sourceURL.deletingPathExtension().lastPathComponent)_\(routine.suffix)"
        let dest = AudioEditor.uniqueURL(inFolder: folder, baseName: base)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: produced, to: dest)
        if produced != sourceURL {
            try? FileManager.default.removeItem(at: produced)
        }
        return dest
    }

    private static func finalize(_ url: URL, preview: Bool, sourceURL: URL) throws -> URL {
        guard preview else { return url }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("butter-proc-\(UUID().uuidString).wav")
        if FileManager.default.fileExists(atPath: temp.path) {
            try FileManager.default.removeItem(at: temp)
        }
        try FileManager.default.copyItem(at: url, to: temp)
        if url != sourceURL {
            try? FileManager.default.removeItem(at: url)
        }
        return temp
    }
}
