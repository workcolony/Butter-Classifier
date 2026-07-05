import Foundation

/// Locates the bundled Python runtime and analyzer script.
struct AnalyzerRuntime {
    let pythonURL: URL
    let scriptURL: URL

    /// Persistent worker wrapper, sitting next to the analyzer script.
    var workerURL: URL {
        scriptURL.deletingLastPathComponent().appendingPathComponent("worker.py")
    }

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

    /// Returns a runtime that is safe to execute. Running Python from a
    /// cloud-synced volume (e.g. Synology Drive under ~/Library/CloudStorage)
    /// intermittently segfaults numpy because the file provider can't reliably
    /// serve memory-mapped native libraries. In that case the runtime is
    /// mirrored once into local Application Support and run from there.
    /// Blocking (the first mirror copies ~500 MB) - call off the main thread.
    static func prepared(log: @escaping (String) -> Void = { _ in }) -> AnalyzerRuntime? {
        guard let source = locate() else { return nil }
        guard source.pythonURL.path.contains("/Library/CloudStorage/") else { return source }

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ButterClassifier")
        let mirror = appSupport.appendingPathComponent("analyzer")
        let stampURL = appSupport.appendingPathComponent("analyzer.stamp")
        let sourceDir = source.scriptURL.deletingLastPathComponent()

        func mtime(_ url: URL) -> String {
            let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
            return String(date?.timeIntervalSince1970 ?? 0)
        }
        let stamp = [
            sourceDir.path,
            mtime(source.scriptURL),
            mtime(sourceDir.appendingPathComponent("worker.py")),
            mtime(source.pythonURL),
        ].joined(separator: "|")

        let mirrored = AnalyzerRuntime(
            pythonURL: mirror.appendingPathComponent("python/bin/python3"),
            scriptURL: mirror.appendingPathComponent("audio_analyzer.py")
        )

        if let existing = try? String(contentsOf: stampURL, encoding: .utf8),
           existing == stamp,
           fm.isExecutableFile(atPath: mirrored.pythonURL.path) {
            return mirrored
        }

        log("Analyzer runtime is on a cloud-synced volume; copying it to local storage (one-time, ~500 MB)...\n")
        do {
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let sync = Process()
            sync.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
            sync.arguments = ["-a", "--delete", sourceDir.path + "/", mirror.path + "/"]
            try sync.run()
            sync.waitUntilExit()
            guard sync.terminationStatus == 0,
                  fm.isExecutableFile(atPath: mirrored.pythonURL.path) else {
                log("Local mirror failed (rsync exit \(sync.terminationStatus)); falling back to in-place runtime.\n")
                return source
            }
            try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
            log("Local analyzer runtime ready.\n")
            return mirrored
        } catch {
            log("Local mirror failed: \(error.localizedDescription); falling back to in-place runtime.\n")
            return source
        }
    }
}
