import Foundation

struct ProcParam: Codable, Identifiable {
    let name: String
    let label: String
    let `default`: Double
    var min: Double?
    var max: Double?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, label, min, max
        case `default` = "default"
    }
}

struct ProcRoutine: Codable, Identifiable {
    let id: String
    let label: String
    let suffix: String
    let params: [ProcParam]
}

struct ProcGroup: Codable, Identifiable {
    let id: String
    let label: String
    let routines: [ProcRoutine]
}

struct ProcCatalog: Codable {
    let groups: [ProcGroup]

    func routine(id: String) -> ProcRoutine? {
        for group in groups {
            if let routine = group.routines.first(where: { $0.id == id }) {
                return routine
            }
        }
        return nil
    }

    private static let bundledFallback = ProcCatalog(groups: [
        ProcGroup(id: "basics", label: "Basics", routines: [
            ProcRoutine(id: "gain", label: "Gain", suffix: "_gain",
                        params: [ProcParam(name: "db", label: "dB", default: -3, min: -48, max: 24)]),
            ProcRoutine(id: "normalize", label: "Normalize", suffix: "_norm",
                        params: [ProcParam(name: "target", label: "dBFS", default: -0.3, min: -24, max: 0)]),
            ProcRoutine(id: "reverse", label: "Reverse", suffix: "_rev", params: []),
        ]),
        ProcGroup(id: "filter", label: "Filter", routines: [
            ProcRoutine(id: "lpf", label: "Low-pass", suffix: "_lpf",
                        params: [ProcParam(name: "cutoff", label: "Hz", default: 8000, min: 80, max: 20000)]),
            ProcRoutine(id: "hpf", label: "High-pass", suffix: "_hpf",
                        params: [ProcParam(name: "cutoff", label: "Hz", default: 120, min: 20, max: 8000)]),
        ]),
        ProcGroup(id: "time", label: "Time", routines: [
            ProcRoutine(id: "crop", label: "Crop selection", suffix: "_crop", params: [
                ProcParam(name: "start", label: "Start (s)", default: 0, min: 0, max: 600),
                ProcParam(name: "end", label: "End (s)", default: 1, min: 0, max: 600),
            ]),
        ]),
    ])

    static let shared: ProcCatalog = {
        if let url = Bundle.main.url(forResource: "proc-routines", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let catalog = try? JSONDecoder().decode(ProcCatalog.self, from: data),
           !catalog.groups.isEmpty {
            return catalog
        }
        return bundledFallback
    }()
}
