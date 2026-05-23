import Foundation

/// Shared batch control and turbo mode management for maintenance operations.
///
/// Provides:
/// - Turbo mode toggle (uses 80% of available cores, no artificial cap)
/// - Worker count calculation based on turbo mode
/// - Batch size adjustment for throughput vs responsiveness
/// - ConcurrencyLimiter factory for enforcing real parallel execution
@Observable
final class BatchControl {
    
    /// Turbo mode enabled - uses 80% of available cores for maximum throughput
    private(set) var turboMode: Bool = false
    
    /// Batch size for normal mode - responsive cancellation
    static let normalBatchSize = 75
    
    /// Batch size for turbo mode - larger batches for throughput
    static let turboBatchSize = 150
    
    /// Calculate worker count based on turbo mode.
    ///
    /// - Turbo: 80% of available cores, minimum 4. No upper cap —
    ///   if the machine has 24 cores, turbo uses 19.
    /// - Normal: conservative parallelism (half the cores, capped at 4)
    ///   to keep the UI responsive during background work.
    static func workerCount(turboMode: Bool) -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if turboMode {
            return max(4, Int(Double(cores) * 0.8))
        } else {
            return max(2, min(cores / 2, 4))
        }
    }
    
    /// Get current batch size based on turbo mode
    static func batchSize(turboMode: Bool) -> Int {
        turboMode ? turboBatchSize : normalBatchSize
    }

    /// Create a `ConcurrencyLimiter` pre-configured for the given turbo mode.
    ///
    /// The returned limiter enforces that exactly `workerCount` tasks
    /// execute in parallel — unlike a bare `TaskGroup` which relies on
    /// Swift's cooperative thread pool (often under-parallelizing I/O-heavy
    /// subprocess work like fpcalc and ffmpeg).
    static func limiter(turboMode: Bool) -> ConcurrencyLimiter {
        ConcurrencyLimiter(maxConcurrency: workerCount(turboMode: turboMode))
    }
    
    /// Enable or disable turbo mode
    func setTurboMode(_ enabled: Bool) {
        turboMode = enabled
        AppLogger.shared.info("Turbo mode \(enabled ? "enabled" : "disabled") - using \(BatchControl.workerCount(turboMode: enabled)) workers", source: "BatchControl")
    }
}

extension Int {
    /// Clamp integer value to a range
    func clamped(to range: Range<Int>) -> Int {
        return Swift.max(range.lowerBound, Swift.min(self, range.upperBound - 1))
    }
}