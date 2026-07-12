import Foundation

struct ProcScriptStep: Equatable, Codable, Hashable {
    let routineID: String
    let params: [String: Double]
}

enum ProcScriptParser {
    enum ParseError: LocalizedError {
        case emptyScript
        case invalidLine(Int, String)

        var errorDescription: String? {
            switch self {
            case .emptyScript: return "Script has no routine lines."
            case .invalidLine(let line, let detail):
                return "Line \(line): \(detail)"
            }
        }
    }

    static func parse(_ text: String) throws -> [ProcScriptStep] {
        var steps: [ProcScriptStep] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let routineID = parts.first, !routineID.isEmpty else { continue }
            var params: [String: Double] = [:]
            for part in parts.dropFirst() {
                let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pieces.count == 2, let value = Double(pieces[1]) else {
                    throw ParseError.invalidLine(index + 1, "expected name=value, got \"\(part)\"")
                }
                params[pieces[0]] = value
            }
            steps.append(ProcScriptStep(routineID: routineID, params: params))
        }
        guard !steps.isEmpty else { throw ParseError.emptyScript }
        return steps
    }

    static func serialize(_ steps: [ProcScriptStep]) -> String {
        steps.map { step in
            let params = step.params
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            if params.isEmpty { return step.routineID }
            return "\(step.routineID) \(params)"
        }
        .joined(separator: "\n")
    }

    static func defaultTemplate() -> String {
        """
        # One routine per line. Optional params: name=value
        #
        # --- Basics ---
        # gain db=-6
        # normalize target=-0.3
        # reverse
        #
        # --- Filter + distort ---
        # hpf cutoff=180
        # lpf cutoff=5500
        # clip drive=14
        # crush bits=8
        #
        # --- Time + space ---
        # crop start=0.2 end=1.4
        # stutter grain=60 repeats=12 start=0
        # delay time=220 feedback=0.4 mix=0.35
        # fade in=10 out=80
        #
        # --- Modulate + spectral ---
        # ringmod freq=180 mix=0.8
        # spectblur amount=0.6 mix=0.85
        # tremolo rate=5 depth=0.6
        #
        # --- Grain / walk / combine ---
        # grain grain=40 density=28 mix=0.75
        # walk step=120 steps=16 fade=8
        # combine offset=100 reverse=1 mix=0.45
        #
        # --- Cecilia-inspired ---
        # degrade bits=8 rate=0.35 mirror=0.85 mix=1
        # phaser base=800 q=0.7 spread=400 stages=4 feedback=0.3 mix=0.65
        # freqshift shift=40 feedback=0.2 mix=0.75
        # waveshape drive=18 pre=6000 post=9000 mix=0.85
        # parameq freq=1200 q=1.2 gain=6
        # statevar cutoff=1800 q=0.8 mode=0 mix=1
        # granulate position=0.5 grain=45 density=28 pitch=50 mix=0.8
        # vocoder bands=12 base=200 spread=1.35 q=1.5 mix=0.85
        # harmonizer voice1=7 voice2=-5 mix=0.55
        # spectralgate threshold=-36 mix=1
        # spectraldelay time=120 feedback=0.5 mix=0.7
        # spectralshift shift=80 mix=0.8
        # resonators base=220 detune=0.4 decay=0.75 mix=0.65
        # particle grain=50 density=32 posRand=0.6 pitchRand=80 mix=0.85
        #
        gain db=-3
        normalize target=-0.3
        """
    }
}
