import Foundation

/// Runs the bundled audio_analyzer.py against files or folders, streaming
/// progress, one job at a time.
@MainActor
final class AnalyzerRunner: ObservableObject {
    struct Job: Identifiable {
        let id = UUID()
        let path: String
        let bpmOverride: Double?
        let quick: Bool
        /// Delete an existing YAML first so the script re-analyzes.
        let force: Bool

        var displayName: String { (path as NSString).lastPathComponent }
    }

    @Published private(set) var queue: [Job] = []
    @Published private(set) var currentJob: Job?
    @Published private(set) var isRunning = false
    @Published private(set) var log = ""
    @Published private(set) var currentFileName = ""
    @Published private(set) var completedInJob = 0
    @Published var runtimeMissing = false

    /// Called on the main actor whenever a job finishes (analysis YAMLs changed).
    var onJobFinished: (() -> Void)?

    private var process: Process?

    func enqueue(path: String, bpmOverride: Double? = nil, quick: Bool = false, force: Bool = false) {
        queue.append(Job(path: path, bpmOverride: bpmOverride, quick: quick, force: force))
        runNextIfIdle()
    }

    func cancelAll() {
        queue.removeAll()
        process?.terminate()
    }

    private func runNextIfIdle() {
        guard !isRunning, !queue.isEmpty else { return }
        guard let runtime = AnalyzerRuntime.locate() else {
            runtimeMissing = true
            queue.removeAll()
            return
        }

        let job = queue.removeFirst()
        currentJob = job
        isRunning = true
        completedInJob = 0
        currentFileName = job.displayName
        appendLog("=== Analyzing \(job.path) ===\n")

        if job.force {
            let fm = FileManager.default
            let yamlPath = job.path + ".yaml"
            if fm.fileExists(atPath: yamlPath) {
                try? fm.removeItem(atPath: yamlPath)
            }
        }

        let proc = Process()
        proc.executableURL = runtime.pythonURL
        var args = [runtime.scriptURL.path, job.path]
        if let bpm = job.bpmOverride { args += ["--bpm", String(bpm)] }
        if job.quick { args.append("--quick") }
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.consumeOutput(text)
            }
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.appendLog("\n=== Done ===\n")
                self.isRunning = false
                self.currentJob = nil
                self.currentFileName = ""
                self.process = nil
                self.onJobFinished?()
                self.runNextIfIdle()
            }
        }

        self.process = proc
        do {
            try proc.run()
        } catch {
            appendLog("Failed to launch analyzer: \(error.localizedDescription)\n")
            isRunning = false
            currentJob = nil
            process = nil
            runNextIfIdle()
        }
    }

    private func consumeOutput(_ text: String) {
        appendLog(text)
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The script prints each file path (cyan) when it starts processing it.
            if trimmed.hasSuffix(".wav") || trimmed.hasSuffix(".mp3") {
                currentFileName = (trimmed as NSString).lastPathComponent
                completedInJob += 1
            }
        }
    }

    private func appendLog(_ text: String) {
        log += text
        if log.count > 200_000 {
            log = String(log.suffix(100_000))
        }
    }
}
