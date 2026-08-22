import Foundation

/// Shared batch control for maintenance operations.
///
/// Provides:
/// - Background processing setting
/// - Worker count calculation based on the setting
/// - Batch size adjustment for throughput vs responsiveness
/// - ConcurrencyLimiter factory for enforcing real parallel execution
@Observable
final class BatchControl {
    
    /// Internal compatibility state for the persisted background-processing setting.
    private(set) var turboMode: Bool = false
    
    /// Batch size for normal mode - responsive cancellation
    static let normalBatchSize = 75
    
    /// Batch size for fast background processing.
    static let turboBatchSize = 150
    
    /// Calculate worker count from the persisted Background processing level.
    ///
    /// - Fast: 80% of available cores, minimum 4. No upper cap.
    /// - Normal: conservative parallelism (half the cores, capped at 4)
    ///   to keep the UI responsive during background work.
    static func workerCount(turboMode: Bool) -> Int {
        if let rawValue = UserDefaults.standard.string(forKey: "sync_turbo_level"),
           let level = SyncTurboLevel(rawValue: rawValue) {
            return level.workerCount()
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if turboMode {
            return max(4, Int(Double(cores) * 0.8))
        } else {
            return max(2, min(cores / 2, 4))
        }
    }
    
    /// Get current batch size based on the background-processing setting.
    static func batchSize(turboMode: Bool) -> Int {
        let level = UserDefaults.standard.string(forKey: "sync_turbo_level")
            .flatMap(SyncTurboLevel.init(rawValue:))
        return level == .fast || (level == nil && turboMode) ? turboBatchSize : normalBatchSize
    }

    /// Create a `ConcurrencyLimiter` pre-configured for the given setting.
    ///
    /// The returned limiter enforces that exactly `workerCount` tasks
    /// execute in parallel — unlike a bare `TaskGroup` which relies on
    /// Swift's cooperative thread pool (often under-parallelizing I/O-heavy
    /// subprocess work like fpcalc and ffmpeg).
    static func limiter(turboMode: Bool) -> ConcurrencyLimiter {
        ConcurrencyLimiter(maxConcurrency: workerCount(turboMode: turboMode))
    }
    
    /// Update the internal compatibility state used by legacy callers.
    func setTurboMode(_ enabled: Bool) {
        turboMode = enabled
        AppLogger.shared.info("Background processing updated - using \(BatchControl.workerCount(turboMode: enabled)) workers", source: "BatchControl")
    }
}

extension Int {
    /// Clamp integer value to a range
    func clamped(to range: Range<Int>) -> Int {
        return Swift.max(range.lowerBound, Swift.min(self, range.upperBound - 1))
    }
}
