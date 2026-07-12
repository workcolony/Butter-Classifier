import Foundation

/// Runs analysis through a pool of persistent Python workers. Each worker
/// imports librosa/essentia once (the expensive part, ~1 min) and then
/// analyzes files in a few seconds each for the rest of the app session.
@MainActor
final class AnalyzerRunner: ObservableObject {
    struct FileTask {
        let path: String
        let bpmOverride: Double?
        let quick: Bool
        /// Delete an existing YAML first so the file is re-analyzed.
        let force: Bool
    }

    @Published private(set) var isRunning = false
    @Published private(set) var totalInBatch = 0
    @Published private(set) var completedInBatch = 0
    @Published private(set) var activeFileNames: [String] = []
    @Published private(set) var readyWorkers = 0
    @Published private(set) var startingWorkers = 0
    @Published private(set) var preparingRuntime = false
    @Published private(set) var log = ""
    @Published var runtimeMissing = false
    @Published var verboseLog = false

    /// How many files to process simultaneously (one worker process each).
    var maxWorkers = 1

    /// Called with the file path whenever a single file finishes.
    var onFileFinished: ((String) -> Void)?

    private var pending: [FileTask] = []
    private var workers: [Worker] = []
    private var nextWorkerID = 1
    private var runtime: AnalyzerRuntime?
    private var requestedWorkerCount = 0
    private var consecutiveStartupDeaths = 0
    private var fileTimeoutTasks: [Int: Task<Void, Never>] = [:]

    private static let maxConsecutiveStartupDeaths = 3
    private static let fileTimeoutSeconds: UInt64 = 180

    private final class Worker {
        let id: Int
        let process: Process
        let stdinHandle: FileHandle
        var ready = false
        var currentTask: FileTask?
        var lineBuffer = ""

        init(id: Int, process: Process, stdinHandle: FileHandle) {
            self.id = id
            self.process = process
            self.stdinHandle = stdinHandle
        }
    }

    // MARK: - Public API

    /// True while the runtime is being prepared or workers are importing libraries.
    var showsAnalyzerStatus: Bool {
        isRunning || preparingRuntime || startingWorkers > 0
    }

    /// Pre-start workers so the first analyze batch doesn't wait on library imports.
    func warmUp() {
        ensureWorkers(count: maxWorkers)
    }

    func enqueue(files: [FileTask]) {
        guard !files.isEmpty else { return }
        let startingBatch = !isRunning
        if startingBatch {
            totalInBatch = 0
            completedInBatch = 0
            log = ""
            consecutiveStartupDeaths = 0
        }
        let fm = FileManager.default
        let work = files.filter { $0.force || !fm.fileExists(atPath: $0.path + ".yaml") }
        guard !work.isEmpty else { return }

        pending.append(contentsOf: work)
        totalInBatch += work.count
        isRunning = true
        pump()
    }

    func cancelAll() {
        pending.removeAll()
        cancelAllTimeouts()
        for worker in workers {
            worker.process.terminationHandler = nil
            worker.process.terminate()
        }
        workers.removeAll()
        finishBatchIfIdle()
        updateCounts()
        ensureWorkers(count: 1)
    }

    // MARK: - Pool management

    /// Workers load heavy Python libraries on startup. Grow the pool one
    /// process at a time so we don't launch twenty imports at once.
    private func ensureWorkers(count: Int) {
        guard workers.count < count else { return }
        guard let runtime else {
            requestedWorkerCount = max(requestedWorkerCount, count)
            resolveRuntime()
            return
        }

        if workers.isEmpty {
            spawnWorker(runtime: runtime)
            return
        }

        if !workers.contains(where: \.ready) {
            // Still waiting for the first worker to finish importing.
            return
        }

        spawnWorker(runtime: runtime)
        updateCounts()
    }

    private func resolveRuntime() {
        guard !preparingRuntime else { return }
        preparingRuntime = true
        Task.detached(priority: .userInitiated) {
            let resolved = AnalyzerRuntime.prepared { message in
                Task { @MainActor [weak self] in self?.appendLog(message) }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.preparingRuntime = false
                guard let resolved else {
                    self.runtimeMissing = true
                    self.pending.removeAll()
                    self.finishBatchIfIdle()
                    return
                }
                self.runtime = resolved
                let wanted = max(self.requestedWorkerCount, 1)
                self.requestedWorkerCount = 0
                self.ensureWorkers(count: wanted)
                self.pump()
            }
        }
    }

    private func spawnWorker(runtime: AnalyzerRuntime) {
        let id = nextWorkerID
        nextWorkerID += 1

        let proc = Process()
        proc.executableURL = runtime.pythonURL
        proc.arguments = [runtime.workerURL.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stdoutPipe

        let worker = Worker(id: id, process: proc, stdinHandle: stdinPipe.fileHandleForWriting)

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.consumeOutput(text, from: worker)
            }
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                self?.workerDied(worker)
            }
        }

        do {
            try proc.run()
            workers.append(worker)
            appendLog("[worker \(id)] starting (loading analyzer libraries — first load can take ~1 min)…\n")
        } catch {
            appendLog("[worker \(id)] failed to launch: \(error.localizedDescription)\n")
        }
    }

    private func workerDied(_ worker: Worker) {
        cancelTimeout(for: worker.id)
        workers.removeAll { $0 === worker }

        if let task = worker.currentTask {
            appendLog("[worker \(worker.id)] exited mid-file; requeueing \((task.path as NSString).lastPathComponent)\n")
            pending.insert(task, at: 0)
            consecutiveStartupDeaths = 0
        } else if worker.ready {
            appendLog("[worker \(worker.id)] exited\n")
            consecutiveStartupDeaths = 0
        } else {
            consecutiveStartupDeaths += 1
            appendLog("[worker \(worker.id)] exited before becoming ready (\(consecutiveStartupDeaths)/\(Self.maxConsecutiveStartupDeaths))\n")
            if consecutiveStartupDeaths >= Self.maxConsecutiveStartupDeaths {
                appendLog("Workers keep failing during startup. Falling back to 1 parallel worker — try Analyze again, or lower Files in Parallel.\n")
                maxWorkers = 1
                consecutiveStartupDeaths = 0
                for extra in workers where !extra.ready {
                    extra.process.terminationHandler = nil
                    extra.process.terminate()
                }
                workers.removeAll { !$0.ready }
            }
        }
        updateCounts()
        pump()
    }

    // MARK: - Scheduling

    private func pump() {
        guard !pending.isEmpty else {
            finishBatchIfIdle()
            return
        }

        let busy = workers.filter { $0.currentTask != nil }.count
        let wanted = min(maxWorkers, busy + pending.count)
        ensureWorkers(count: wanted)

        for worker in workers where worker.ready && worker.currentTask == nil {
            guard !pending.isEmpty else { break }
            assign(pending.removeFirst(), to: worker)
        }
        updateCounts()
    }

    private func assign(_ task: FileTask, to worker: Worker) {
        var request: [String: Any] = ["path": task.path, "force": task.force, "quick": task.quick]
        if let bpm = task.bpmOverride { request["bpm"] = bpm }
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        worker.currentTask = task
        do {
            try worker.stdinHandle.write(contentsOf: Data(line.utf8))
            scheduleTimeout(for: worker, task: task)
        } catch {
            appendLog("[worker \(worker.id)] failed to send file: \(error.localizedDescription)\n")
            worker.currentTask = nil
            pending.insert(task, at: 0)
        }
    }

    private func scheduleTimeout(for worker: Worker, task: FileTask) {
        let workerID = worker.id
        let path = task.path
        fileTimeoutTasks[workerID]?.cancel()
        fileTimeoutTasks[workerID] = Task {
            try? await Task.sleep(nanoseconds: Self.fileTimeoutSeconds * 1_000_000_000)
            await MainActor.run { [weak self] in
                guard let self,
                      let w = self.workers.first(where: { $0.id == workerID }),
                      w.currentTask?.path == path else { return }
                self.appendLog("[worker \(workerID)] timed out on \((path as NSString).lastPathComponent); restarting worker\n")
                w.process.terminate()
            }
        }
    }

    private func cancelTimeout(for workerID: Int) {
        fileTimeoutTasks[workerID]?.cancel()
        fileTimeoutTasks[workerID] = nil
    }

    private func cancelAllTimeouts() {
        for task in fileTimeoutTasks.values { task.cancel() }
        fileTimeoutTasks.removeAll()
    }

    private func finishBatchIfIdle() {
        if pending.isEmpty && workers.allSatisfy({ $0.currentTask == nil }) {
            isRunning = false
        }
    }

    // MARK: - Worker output

    private func consumeOutput(_ text: String, from worker: Worker) {
        worker.lineBuffer += text
        while let newline = worker.lineBuffer.firstIndex(of: "\n") {
            let line = String(worker.lineBuffer[..<newline])
            worker.lineBuffer.removeSubrange(...newline)
            handleLine(line, from: worker)
        }
    }

    private func handleLine(_ line: String, from worker: Worker) {
        if line.hasPrefix("<<<BC_READY>>>") {
            worker.ready = true
            consecutiveStartupDeaths = 0
            appendLog("[worker \(worker.id)] ready\n")
            updateCounts()
            if workers.count < maxWorkers {
                ensureWorkers(count: min(maxWorkers, workers.count + 1))
            }
            pump()
            return
        }
        if line.hasPrefix("<<<BC_DONE>>>") {
            cancelTimeout(for: worker.id)
            let payload = line.dropFirst("<<<BC_DONE>>>".count)
            var finishedPath = worker.currentTask?.path
            if let data = payload.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let p = obj["path"] as? String { finishedPath = p }
                if let err = obj["error"] as? String {
                    appendLog("[worker \(worker.id)] ERROR: \(err)\n")
                }
            }
            worker.currentTask = nil
            completedInBatch += 1
            if let path = finishedPath {
                onFileFinished?(path)
            }
            updateCounts()
            pump()
            return
        }
        if shouldLogAnalyzerLine(line) {
            appendLog(line + "\n")
        }
    }

    /// Per-file analyzer output is very chatty and can flood the main thread,
    /// which stalls pipe reads and makes workers look stuck. Keep lifecycle
    /// messages always; include script lines only in verbose mode.
    private func shouldLogAnalyzerLine(_ line: String) -> Bool {
        if verboseLog { return true }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("[worker") { return true }
        if trimmed.contains("Analyzer runtime") { return true }
        if trimmed.contains("ERROR") || trimmed.contains("Warning: skipping") { return true }
        if trimmed.contains("Failed to analyze") { return true }
        return false
    }

    private func updateCounts() {
        readyWorkers = workers.filter(\.ready).count
        startingWorkers = workers.count - readyWorkers
        activeFileNames = workers.compactMap { w in
            w.currentTask.map { ($0.path as NSString).lastPathComponent }
        }
        if pending.isEmpty && activeFileNames.isEmpty {
            finishBatchIfIdle()
        }
    }

    private func appendLog(_ text: String) {
        log += text
        if log.count > 200_000 {
            log = String(log.suffix(100_000))
        }
    }
}
