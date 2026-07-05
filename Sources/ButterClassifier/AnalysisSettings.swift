import Foundation

/// Limits for the analyzer worker pool. Caps are conservative on small
/// machines; on machines with plenty of RAM we allow modest CPU
/// oversubscription since analysis mixes compute with file I/O.
enum AnalysisSettings {
    private static let bytesPerWorkerSmall: UInt64 = 800 * 1024 * 1024
    private static let bytesPerWorkerLarge: UInt64 = 600 * 1024 * 1024
    private static let reservedBytesSmall: UInt64 = 10 * 1024 * 1024 * 1024
    private static let reservedBytesLarge: UInt64 = 8 * 1024 * 1024 * 1024
    private static let largeMemoryThreshold: UInt64 = 32 * 1024 * 1024 * 1024

    private static var isLargeMemoryMachine: Bool {
        ProcessInfo.processInfo.physicalMemory >= largeMemoryThreshold
    }

    /// Maximum parallel workers that stay within CPU and RAM limits.
    static var safeMaxParallelWorkers: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let physical = ProcessInfo.processInfo.physicalMemory
        let reserved = isLargeMemoryMachine ? reservedBytesLarge : reservedBytesSmall
        let perWorker = isLargeMemoryMachine ? bytesPerWorkerLarge : bytesPerWorkerSmall
        let available = physical > reserved ? physical - reserved : physical / 2
        var memoryCap = max(1, Int(available / perWorker))

        if physical < 12 * 1024 * 1024 * 1024 {
            memoryCap = min(memoryCap, 2)
        } else if physical < 24 * 1024 * 1024 * 1024 {
            memoryCap = min(memoryCap, 4)
        }

        // On high-RAM machines, allow up to 2× core count — workers often wait
        // on disk I/O and Activity Monitor shows headroom below core count.
        let cpuCap = isLargeMemoryMachine ? min(memoryCap, max(cores, cores * 2)) : cores
        return max(1, min(cpuCap, memoryCap))
    }

    static var defaultParallelWorkers: Int { safeMaxParallelWorkers }

    static func parallelWorkerOptions() -> [Int] {
        let max = safeMaxParallelWorkers
        guard max > 1 else { return [1] }
        var options = Set([1, 2, max])
        var n = 2
        while n < max {
            options.insert(n)
            n += n < 8 ? 1 : (n < 16 ? 2 : 4)
        }
        return options.sorted()
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, 1), safeMaxParallelWorkers)
    }
}
