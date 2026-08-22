import Foundation

/// ReplayGain loudness normalization analyzer using ffmpeg.
///
/// Measures EBU R128 loudness (LUFS, true peak) per track and per album.
/// Reference level: -18 LUFS (ReplayGain 2.0 standard).
/// Mirrors the Rust `ReplayGainAnalyzer`.
final class ReplayGainAnalyzer: Sendable {

    /// ReplayGain 2.0 reference level (NOT -23 LUFS from EBU R128 broadcast).
    static let referenceLevel: Double = -18.0

    /// Minimum loudness before clamping (silence threshold).
    private static let silenceThreshold: Double = -70.0

    /// Maximum gain to apply (for near-silent tracks).
    private static let maxGain: Double = 20.0

    private let ffmpegPath: String?

    init() {
        self.ffmpegPath = ProcessRunner.findExecutable("ffmpeg")
    }

    /// Whether ffmpeg is available for analysis.
    var isAvailable: Bool { ffmpegPath != nil }

    // MARK: - Track Analysis

    struct GainResult {
        let trackGain: Double   // dB to apply
        let trackPeak: Double   // true peak (linear)
        let loudness: Double    // measured LUFS
        let lufsRange: Double   // measured LRA (LU)
    }

    /// Analyze loudness of a single track using ffmpeg's ebur128 filter.
    func analyzeTrack(path: String) async throws -> GainResult? {
        guard let ffmpeg = ffmpegPath else { return nil }

        let result = try await ProcessRunner.run(
            ffmpeg,
            arguments: [
                "-i", path,
                "-af", "ebur128=peak=true",
                "-f", "null",
                "-"
            ]
        )

        // ebur128 outputs to stderr
        return parseEBUR128Output(result.stderr)
    }

    /// Batch-analyze multiple tracks for ReplayGain with true parallel processing.
    ///
    /// Uses a `ConcurrencyLimiter` to enforce exactly `workerCount` ffmpeg
    /// subprocesses running at once. In turbo mode this saturates 80% of
    /// available CPU cores — each slot runs a blocking ffmpeg ebur128 analysis.
    ///
    /// - Parameters:
    ///   - tracks: Tracks to analyze
    ///   - repository: Analysis repository for saving results
    ///   - trackRepository: Track repository for updating energy buckets
    ///   - turboMode: Enable turbo mode (80% core utilization, no cap)
    ///   - progressHandler: Optional progress callback
    /// - Returns: Count of analyzed, failed, and cancelled tracks
    func batchAnalyze(
        tracks: [Track],
        repository: AnalysisRepository,
        trackRepository: TrackRepository,
        libraryRoot: String? = nil,
        turboMode: Bool = false,
        progressHandler: ((MaintenanceProgressTracker.ProgressState) -> Void)? = nil
    ) async -> (analyzed: Int, failed: Int, cancelled: Bool) {
        let tracker = MaintenanceProgressTracker(total: tracks.count, turboMode: turboMode, progressHandler: progressHandler)
        
        let workerCount = BatchControl.workerCount(turboMode: turboMode)
        let limiter = BatchControl.limiter(turboMode: turboMode)
        
        AppLogger.shared.info("Starting ReplayGain batch: \(tracks.count) tracks, \(workerCount) workers (turbo: \(turboMode))", source: "ReplayGain")
        
        // Feed ALL tracks into a single task group. The ConcurrencyLimiter
        // ensures exactly `workerCount` ffmpeg subprocesses run at once.
        let results: [Result<Void, Error>] = await withTaskGroup(of: Result<Void, Error>.self) { group in
            for track in tracks {
                group.addTask {
                    // Check cancellation before acquiring a slot
                    guard !tracker.isCancelled else {
                        return .failure(CancellationError())
                    }
                    return await limiter.run {
                        await self.processSingleAnalysis(
                            track: track,
                            repository: repository,
                            trackRepository: trackRepository,
                            libraryRoot: libraryRoot,
                            tracker: tracker
                        )
                    }
                }
            }
            
            var collected: [Result<Void, Error>] = []
            collected.reserveCapacity(tracks.count)
            for await result in group {
                collected.append(result)
                // Early exit: stop collecting if cancelled
                if tracker.isCancelled { break }
            }
            return collected
        }
        
        var analyzed = 0
        var failed = 0
        for result in results {
            switch result {
            case .success: analyzed += 1
            case .failure: failed += 1
            }
        }
        
        AppLogger.shared.info("ReplayGain batch complete: \(analyzed) analyzed, \(failed) failed", source: "ReplayGain")
        return (analyzed, failed, tracker.isCancelled)
    }
    
    /// Process a single track analysis with progress tracking
    private func processSingleAnalysis(
        track: Track,
        repository: AnalysisRepository,
        trackRepository: TrackRepository,
        libraryRoot: String?,
        tracker: MaintenanceProgressTracker
    ) async -> Result<Void, Error> {
        guard let trackId = track.id else {
            tracker.updateProgress(
                trackId: 0,
                trackTitle: track.title,
                trackArtist: track.artist,
                savedToDb: false
            )
            return .failure(NSError(domain: "ReplayGain", code: -1, userInfo: [NSLocalizedDescriptionKey: "No track ID"]))
        }
        
        // Resolve the actual file path (organizedPath is relative to libraryRoot)
        let filePath: String?
        if let organized = track.organizedPath {
            let path: String
            if let root = libraryRoot, !root.isEmpty {
                path = URL(fileURLWithPath: root).appendingPathComponent(organized).path
            } else {
                path = organized
            }
            if FileManager.default.fileExists(atPath: path) {
                filePath = path
            } else if FileManager.default.fileExists(atPath: track.originalPath) {
                filePath = track.originalPath
            } else {
                filePath = nil
            }
        } else {
            filePath = track.isLocal && FileManager.default.fileExists(atPath: track.originalPath) ? track.originalPath : nil
        }
        
        guard let resolvedPath = filePath else {
            tracker.updateProgress(
                trackId: trackId,
                trackTitle: track.title,
                trackArtist: track.artist,
                savedToDb: false
            )
            return .failure(NSError(domain: "ReplayGain", code: -1, userInfo: [NSLocalizedDescriptionKey: "No file path"]))
        }
        
        do {
            if let gain = try await analyzeTrack(path: resolvedPath) {
                // Save ReplayGain data
                let rg = ReplayGain(
                    trackId: trackId,
                    trackGain: gain.trackGain,
                    trackPeak: gain.trackPeak,
                    albumGain: nil,
                    albumPeak: nil,
                    analyzedAt: ISO8601DateFormatter().string(from: Date())
                )
                try await repository.saveReplayGain(rg)

                // Compute and save energy bucket
                let bucket = EnergyBucketer.bucket(lufs: gain.loudness)
                try await trackRepository.updateEnergyBucket(
                    trackId: trackId,
                    energyBucket: bucket,
                    lufsI: gain.loudness,
                    lufsRange: gain.lufsRange,
                    truePeak: gain.trackPeak
                )
                
                tracker.updateProgress(
                    trackId: trackId,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: true
                )
                
                AppLogger.shared.debug(
                    "ReplayGain [\(tracker.currentState.current)/\(tracker.currentState.total)] \(track.artist) - \(track.title) → LUFS-I \(gain.loudness.format(1)), saved to DB",
                    source: "ReplayGain"
                )
                
                return .success(())
            } else {
                tracker.updateProgress(
                    trackId: trackId,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: false
                )
                return .failure(NSError(domain: "ReplayGain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Analysis failed"]))
            }
        } catch {
            tracker.updateProgress(
                trackId: trackId,
                trackTitle: track.title,
                trackArtist: track.artist,
                savedToDb: false
            )
            AppLogger.shared.log("ReplayGain failed for \(track.title): \(error)", level: .warning, source: "Analysis")
            return .failure(error)
        }
    }

    // MARK: - Parsing

    /// Parse ffmpeg's ebur128 filter output for integrated loudness and true peak.
    private func parseEBUR128Output(_ output: String) -> GainResult? {
        // Look for "Integrated loudness:" section
        // Format: "I:         -14.0 LUFS"
        // Format: "Peak:        -1.2 dBFS" or "True peak: X dBFS"

        var loudness: Double?
        var truePeak: Double?
        var lufsRange: Double?

        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Integrated loudness
            if trimmed.contains("I:") && trimmed.contains("LUFS") {
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if let idx = parts.firstIndex(of: "LUFS"), idx > 0 {
                    loudness = Double(parts[idx - 1])
                }
            }

            // True peak
            if trimmed.contains("Peak:") && trimmed.contains("dBFS") {
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if let idx = parts.firstIndex(of: "dBFS"), idx > 0 {
                    if let peakDB = Double(parts[idx - 1]) {
                        // Convert dBFS to linear
                        truePeak = pow(10.0, peakDB / 20.0)
                    }
                }
            }

            // Loudness range
            if trimmed.contains("LRA:") && trimmed.contains("LU") {
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if let idx = parts.firstIndex(of: "LU"), idx > 0 {
                    lufsRange = Double(parts[idx - 1])
                }
            }
        }

        guard let lufs = loudness else { return nil }

        // Handle silence
        if lufs < Self.silenceThreshold || lufs.isInfinite || lufs.isNaN {
            return GainResult(trackGain: Self.maxGain, trackPeak: 0.0, loudness: lufs, lufsRange: 0.0)
        }

        let gain = Self.referenceLevel - lufs
        let peak = truePeak ?? 0.0
        let lra = lufsRange ?? 0.0

        return GainResult(trackGain: gain, trackPeak: peak, loudness: lufs, lufsRange: lra)
    }
}

// MARK: - Energy Bucketer

/// Converts LUFS loudness to a 1-5 energy scale.
///
/// Mirrors the Rust `EnergyBucketer`. Maps integrated LUFS to
/// perceptual energy levels for the library table's energy column.
enum EnergyBucketer {
    /// Map integrated loudness (LUFS) to an energy bucket (1-5).
    ///
    /// Thresholds (from Rust implementation):
    /// - 1 (quiet): LUFS < -20
    /// - 2 (calm):  -20 ≤ LUFS < -16
    /// - 3 (moderate): -16 ≤ LUFS < -12
    /// - 4 (loud):  -12 ≤ LUFS < -8
    /// - 5 (intense): LUFS ≥ -8
    static func bucket(lufs: Double) -> Int {
        if lufs.isNaN || lufs.isInfinite || lufs < -20.0 {
            return 1
        } else if lufs < -16.0 {
            return 2
        } else if lufs < -12.0 {
            return 3
        } else if lufs < -8.0 {
            return 4
        } else {
            return 5
        }
    }
}
