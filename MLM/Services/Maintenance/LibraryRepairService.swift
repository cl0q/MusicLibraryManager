import Foundation

/// Maintenance operations that re-read metadata from files already resolved as local.
///
/// Stale organized-path repair intentionally lives in `OrganizedPathMigrationService`.
/// Its former basename-overwriting/demotion entry point was removed so path changes
/// can only occur through preview, explicit confirmation, backup, and transaction.
@Observable
final class LibraryRepairService {
    private let trackRepository: TrackRepository
    private let configRepository: ConfigRepository

    init(trackRepository: TrackRepository, configRepository: ConfigRepository) {
        self.trackRepository = trackRepository
        self.configRepository = configRepository
    }
    /// Re-read audio tags from all local files and update their metadata in the database.
    func rescanMetadata(
        turboMode: Bool = false,
        progressHandler: ((MaintenanceProgressTracker.ProgressState) -> Void)? = nil
    ) async throws -> (succeeded: Int, failed: Int) {
        let libraryRoot = try await configRepository.getLibraryRoot() ?? ""
        guard !libraryRoot.isEmpty else {
            AppLogger.shared.warn(
                "LibraryRepair: library root not configured — aborting",
                source: "Repair"
            )
            return (0, 0)
        }

        let normalizedRoot = libraryRoot.hasSuffix("/")
            ? String(libraryRoot.dropLast())
            : libraryRoot

        let tracks = try await trackRepository.fetchLocalTracks()
        
        let tracker = MaintenanceProgressTracker(
            total: tracks.count,
            turboMode: turboMode,
            progressHandler: progressHandler
        )

        var succeeded = 0
        var failed = 0

        AppLogger.shared.info(
            "Rescan Metadata: scanning \(tracks.count) tracks...",
            source: "Repair"
        )

        // Bridge Swift task cancellation to the tracker so the loop's
        // isCancelled gates actually fire when the user taps Cancel.
        await withTaskCancellationHandler {
            for (index, var track) in tracks.enumerated() {
                guard !tracker.isCancelled else { break }

                // Resolve track file
                guard let resolvedURL = resolveLocalURL(for: track, normalizedRoot: normalizedRoot) else {
                    tracker.updateProgress(
                        current: index + 1,
                        trackId: track.id ?? 0,
                        trackTitle: track.title,
                        trackArtist: track.artist,
                        savedToDb: false
                    )
                    failed += 1
                    continue
                }

                do {
                    // Extract metadata
                    let metadata = try await MetadataExtractor.extract(from: resolvedURL)

                    // Update track fields
                    track.artist = metadata.artist
                    track.albumArtist = metadata.albumArtist
                    track.album = metadata.album
                    track.title = metadata.title
                    track.genre = metadata.genre
                    track.year = metadata.year
                    track.bitrate = metadata.bitrate
                    track.duration = metadata.duration
                    track.format = metadata.format

                    // Save to database
                    try await trackRepository.update(track)

                    tracker.updateProgress(
                        current: index + 1,
                        trackId: track.id ?? 0,
                        trackTitle: track.title,
                        trackArtist: track.artist,
                        savedToDb: true
                    )
                    succeeded += 1
                } catch {
                    AppLogger.shared.error(
                        "Rescan Metadata: Error for \(track.artist) - \(track.title) [\(resolvedURL.lastPathComponent)]: \(error.localizedDescription)",
                        source: "Repair"
                    )
                    tracker.updateProgress(
                        current: index + 1,
                        trackId: track.id ?? 0,
                        trackTitle: track.title,
                        trackArtist: track.artist,
                        savedToDb: false
                    )
                    failed += 1
                }
            }
        } onCancel: {
            tracker.cancel()
        }

        return (succeeded, failed)
    }

    private func resolveLocalURL(for track: Track, normalizedRoot: String) -> URL? {
        if let organized = track.organizedPath, !organized.isEmpty {
            if let resolved = TranscodeCache.resolveSourceURL(sourcePath: organized, libraryRoot: normalizedRoot) {
                return resolved
            }
        }
        let originalPath = track.originalPath
        if let resolved = TranscodeCache.resolveSourceURL(sourcePath: originalPath, libraryRoot: normalizedRoot) {
            return resolved
        }
        return nil
    }
}

