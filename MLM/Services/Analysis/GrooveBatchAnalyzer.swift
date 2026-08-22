import Foundation

/// Service that manages high-performance batch calculations of CoreML audio embeddings (Grooves)
/// with multi-threaded concurrency controls and Turbo Mode support.
final class GrooveBatchAnalyzer: Sendable {
    private let embeddingService: AudioEmbeddingService

    init(embeddingService: AudioEmbeddingService) {
        self.embeddingService = embeddingService
    }

    /// Whether the underlying CoreML service is available.
    var isAvailable: Bool {
        embeddingService.isAvailable
    }

    /// Batch-analyze multiple tracks for Groove embeddings.
    func batchAnalyze(
        tracks: [Track],
        trackRepository: TrackRepository,
        libraryRoot: String? = nil,
        turboMode: Bool = false,
        progressHandler: ((MaintenanceProgressTracker.ProgressState) -> Void)? = nil
    ) async -> (analyzed: Int, failed: Int, cancelled: Bool) {
        let tracker = MaintenanceProgressTracker(total: tracks.count, turboMode: turboMode, progressHandler: progressHandler)
        let workerCount = BatchControl.workerCount(turboMode: turboMode)
        let limiter = BatchControl.limiter(turboMode: turboMode)

        AppLogger.shared.info("Starting Groove (CoreML) batch: \(tracks.count) tracks, \(workerCount) workers (turbo: \(turboMode))", source: "GrooveBatch")

        let results: [Result<Void, Error>] = await withTaskGroup(of: Result<Void, Error>.self) { group in
            for track in tracks {
                group.addTask {
                    guard !tracker.isCancelled else {
                        return .failure(CancellationError())
                    }
                    return await limiter.run {
                        await self.processSingleAnalysis(
                            track: track,
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

        AppLogger.shared.info("Groove batch complete: \(analyzed) analyzed, \(failed) failed", source: "GrooveBatch")
        return (analyzed, failed, tracker.isCancelled)
    }

    private func processSingleAnalysis(
        track: Track,
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
            return .failure(NSError(domain: "GrooveBatch", code: -1, userInfo: [NSLocalizedDescriptionKey: "No track ID"]))
        }

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
            return .failure(NSError(domain: "GrooveBatch", code: -1, userInfo: [NSLocalizedDescriptionKey: "No file path"]))
        }

        do {
            let totalDuration = Double(track.duration ?? 0)
            let res = try await embeddingService.analyzeTrackDrop(at: resolvedPath, totalDuration: totalDuration)

            // Classify if it's a mix category (e.g. for long tracks > 10 mins)
            let mixCat = MixClassifier.classify(
                bpm: 126.0,
                avgLufs: track.lufsI ?? -14.0,
                lufsRange: track.lufsRange ?? 5.0,
                artist: track.artist,
                title: track.title
            )
            let mixCatString = (track.duration ?? 0) > 600 ? mixCat.rawValue : nil

            try await trackRepository.saveTrackEmbedding(
                trackId: trackId,
                embedding: res.embedding,
                dropOffset: res.offset,
                mixCategory: mixCatString
            )

            tracker.updateProgress(
                trackId: trackId,
                trackTitle: track.title,
                trackArtist: track.artist,
                savedToDb: true
            )

            AppLogger.shared.debug(
                "Groove [\(tracker.currentState.current)/\(tracker.currentState.total)] \(track.artist) - \(track.title) → analyzed & saved",
                source: "GrooveBatch"
            )
            return .success(())
        } catch {
            tracker.updateProgress(
                trackId: trackId,
                trackTitle: track.title,
                trackArtist: track.artist,
                savedToDb: false
            )
            AppLogger.shared.log("Groove calculation failed for \(track.title): \(error)", level: .warning, source: "GrooveBatch")
            return .failure(error)
        }
    }
}
