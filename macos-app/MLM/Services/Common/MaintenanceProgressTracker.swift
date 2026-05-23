import Foundation

/// Progress tracking for batch maintenance operations.
///
/// Provides transparent progress reporting with:
/// - Current item count and total
/// - Percentage progress
/// - Current track being processed
/// - Database save confirmation
/// - Cancellation support
final class MaintenanceProgressTracker: Sendable {
    
    /// Progress state for a maintenance operation
    struct ProgressState {
        var current: Int = 0
        var total: Int = 0
        var percent: Double = 0.0
        var currentTrackTitle: String = ""
        var currentTrackArtist: String = ""
        var lastSavedToDb: Bool = false
        var isCancelled: Bool = false
        var lufsI: Double? = nil
        
        mutating func update(current: Int, total: Int) {
            self.current = current
            self.total = total
            self.percent = total > 0 ? (Double(current) / Double(total)) * 100.0 : 0.0
        }
        
        mutating func setCurrentTrack(title: String, artist: String) {
            self.currentTrackTitle = title
            self.currentTrackArtist = artist
        }
        
        mutating func markSavedToDb() {
            self.lastSavedToDb = true
        }
        
        mutating func setLoudness(lufs: Double) {
            self.lufsI = lufs
        }
    }
    
    /// Progress callback type
    typealias ProgressHandler = (ProgressState) -> Void
    
    private let lock = NSRecursiveLock()
    private var state: ProgressState = ProgressState()
    private let progressHandler: ProgressHandler?
    private let batchSize: Int
    private let workerCount: Int
    
    /// Initialize with progress reporting configuration
    /// - Parameters:
    ///   - total: Total items to process
    ///   - turboMode: Whether turbo mode is enabled (adjusts batch size and workers)
    ///   - progressHandler: Callback for progress updates
    init(total: Int, turboMode: Bool = false, progressHandler: ProgressHandler? = nil) {
        self.progressHandler = progressHandler
        self.batchSize = BatchControl.batchSize(turboMode: turboMode)
        self.workerCount = BatchControl.workerCount(turboMode: turboMode)
        state.total = total
        
        AppLogger.shared.info(
            "MaintenanceProgress initialized: \(total) items, turbo=\(turboMode), workers=\(workerCount), batch=\(batchSize)",
            source: "Maintenance"
        )
    }
    
    /// Update progress with current item info
    func updateProgress(
        current: Int? = nil,
        trackId: Int64,
        trackTitle: String,
        trackArtist: String,
        savedToDb: Bool,
        lufsI: Double? = nil
    ) {
        lock.lock()
        
        let newCurrent = current ?? (state.current + 1)
        state.update(current: newCurrent, total: state.total)
        state.setCurrentTrack(title: trackTitle, artist: trackArtist)
        if savedToDb {
            state.markSavedToDb()
        } else {
            state.lastSavedToDb = false
        }
        if let lufs = lufsI {
            state.setLoudness(lufs: lufs)
        } else {
            state.lufsI = nil
        }
        
        let currentStateSnapshot = state
        lock.unlock()
        
        // Log every batch for visibility without spam
        if newCurrent % batchSize == 0 || newCurrent == 1 {
            let loudnessInfo = lufsI != nil ? " [LUFS: \(lufsI!.format(1))]" : ""
            AppLogger.shared.info(
                "Progress: \(newCurrent)/\(currentStateSnapshot.total) (\(currentStateSnapshot.percent.format(1))%) - \(trackArtist) - \(trackTitle) [DB: \(savedToDb ? "✓" : "✗")]\(loudnessInfo)",
                source: "Maintenance"
            )
        }
        
        progressHandler?(currentStateSnapshot)
    }
    
    /// Check if operation should be cancelled
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.isCancelled
    }
    
    /// Request cancellation
    func cancel() {
        lock.lock()
        state.isCancelled = true
        lock.unlock()
        AppLogger.shared.info("Cancellation requested", source: "Maintenance")
    }
    
    /// Get current progress state
    var currentState: ProgressState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

extension Double {
    /// Format double with specified decimal places
    func format(_ decimals: Int) -> String {
        String(format: "%.\(decimals)f", self)
    }
}