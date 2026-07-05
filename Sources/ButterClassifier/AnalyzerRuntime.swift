import Foundation

/// Locates the bundled Python runtime and analyzer script.
struct AnalyzerRuntime {
    let pythonURL: URL
    let scriptURL: URL

    static func locate() -> AnalyzerRuntime? {
        let fm = FileManager.default

        // 1. Inside the .app bundle (release layout).
        if let res = Bundle.main.resourceURL {
            let py = res.appendingPathComponent("analyzer/python/bin/python3")
            let script = res.appendingPathComponent("analyzer/audio_analyzer.py")
            if fm.isExecutableFile(atPath: py.path), fm.fileExists(atPath: script.path) {
                return AnalyzerRuntime(pythonURL: py, scriptURL: script)
            }
        }

        // 2. Explicit override for development.
        if let dir = ProcessInfo.processInfo.environment["BUTTER_ANALYZER_DIR"] {
            let base = URL(fileURLWithPath: dir)
            let py = base.appendingPathComponent("python/bin/python3")
            let script = base.appendingPathComponent("audio_analyzer.py")
            if fm.isExecutableFile(atPath: py.path), fm.fileExists(atPath: script.path) {
                return AnalyzerRuntime(pythonURL: py, scriptURL: script)
            }
        }

        // 3. Walk up from the executable (covers `swift run` from the repo).
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<8 {
            guard let d = dir else { break }
            let py = d.appendingPathComponent("Runtime/python/bin/python3")
            let script = d.appendingPathComponent("python/analyzer/audio_analyzer.py")
            if fm.isExecutableFile(atPath: py.path), fm.fileExists(atPath: script.path) {
                return AnalyzerRuntime(pythonURL: py, scriptURL: script)
            }
            dir = d.deletingLastPathComponent()
        }

        return nil
    }
}
