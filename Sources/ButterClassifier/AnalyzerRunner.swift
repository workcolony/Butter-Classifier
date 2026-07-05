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

    /// How many files to process simultaneously (one worker process each).
    var maxWorkers = 1

    /// Called with the file path whenever a single file finishes.
    var onFileFinished: ((String) -> Void)?

    private var pending: [FileTask] = []
    private var workers: [Worker] = []
    private var nextWorkerID = 1
    private var runtime: AnalyzerRuntime?
    private var requestedWorkerCount = 0

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

    /// Spawn the first worker ahead of time so imports happen while the user
    /// is still browsing.
    func warmUp() {
        ensureWorkers(count: 1)
    }

    func enqueue(files: [FileTask]) {
        guard !files.isEmpty else { return }
        if !isRunning {
            totalInBatch = 0
            completedInBatch = 0
        }
        // Skip files already analyzed unless forced (the worker checks too,
        // but not queueing them keeps the progress numbers honest).
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
        for worker in workers {
            worker.process.terminationHandler = nil
            worker.process.terminate()
        }
        workers.removeAll()
        finishBatchIfIdle()
        updateCounts()
        // Keep one warm worker around for the next batch.
        ensureWorkers(count: 1)
    }

    // MARK: - Pool management

    private func ensureWorkers(count: Int) {
        guard workers.count < count else { return }
        guard let runtime else {
            requestedWorkerCount = max(requestedWorkerCount, count)
            resolveRuntime()
            return
        }
        while workers.count < count {
            spawnWorker(runtime: runtime)
        }
        updateCounts()
    }

    /// Resolves (and if needed, locally mirrors) the runtime off the main
    /// thread, then spawns whatever was requested in the meantime.
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
            appendLog("[worker \(id)] starting (loading analyzer libraries)...\n")
        } catch {
            appendLog("[worker \(id)] failed to launch: \(error.localizedDescription)\n")
        }
    }

    private func workerDied(_ worker: Worker) {
        workers.removeAll { $0 === worker }
        if let task = worker.currentTask {
            // Requeue so the file isn't silently lost.
            appendLog("[worker \(worker.id)] exited mid-file; requeueing \((task.path as NSString).lastPathComponent)\n")
            pending.insert(task, at: 0)
        } else if worker.ready {
            appendLog("[worker \(worker.id)] exited\n")
        } else {
            appendLog("[worker \(worker.id)] exited before becoming ready (see log above)\n")
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
        } catch {
            appendLog("[worker \(worker.id)] failed to send file: \(error.localizedDescription)\n")
            worker.currentTask = nil
            pending.insert(task, at: 0)
        }
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
            appendLog("[worker \(worker.id)] ready\n")
            updateCounts()
            pump()
            return
        }
        if line.hasPrefix("<<<BC_DONE>>>") {
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
        appendLog(line + "\n")
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
