import Foundation

/// Sensible limits for the analyzer worker pool: fast but safe on RAM and CPU.
enum AnalysisSettings {
    /// Rough resident size of one warm worker (librosa + essentia + numpy).
    private static let bytesPerWorker: UInt64 = 800 * 1024 * 1024
    /// Leave headroom for macOS, the SwiftUI app, playback, and file I/O.
    private static let reservedBytes: UInt64 = 10 * 1024 * 1024 * 1024

    /// Maximum parallel workers that won't oversubscribe CPU or exhaust RAM.
    static var safeMaxParallelWorkers: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let physical = ProcessInfo.processInfo.physicalMemory
        let available = physical > reservedBytes ? physical - reservedBytes : physical / 2
        var memoryCap = max(1, Int(available / bytesPerWorker))
        // Extra headroom on smaller machines so we don't pressure swap.
        if physical < 12 * 1024 * 1024 * 1024 {
            memoryCap = min(memoryCap, 2)
        } else if physical < 24 * 1024 * 1024 * 1024 {
            memoryCap = min(memoryCap, 4)
        }
        return max(1, min(cores, memoryCap))
    }

    /// Default: use the safe maximum so batches run as fast as the machine allows.
    static var defaultParallelWorkers: Int { safeMaxParallelWorkers }

    /// Picker choices from 1 up to the safe maximum.
    static func parallelWorkerOptions() -> [Int] {
        let max = safeMaxParallelWorkers
        guard max > 1 else { return [1] }
        var options = Set([1, 2, max])
        var step = 2
        while step < max {
            options.insert(step)
            step += step < 8 ? 1 : 2
        }
        return options.sorted()
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, 1), safeMaxParallelWorkers)
    }
}
