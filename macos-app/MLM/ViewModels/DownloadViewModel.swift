import SwiftUI

/// ViewModel for the download pipeline.
///
/// Wraps `DownloadOrchestrator` and exposes state for the Activity Panel
/// and download triggers from context menus / batch operations.
@Observable
final class DownloadViewModel {
    // MARK: - State

    private(set) var isDownloading = false
    private(set) var currentTrack: String = ""
    private(set) var progress: Double = 0
    private(set) var completedCount: Int = 0
    private(set) var failedCount: Int = 0
    private(set) var totalCount: Int = 0
    private(set) var lastResult: DownloadOrchestrator.BatchResult?

    /// Queue of pending download items for display.
    private(set) var queueItems: [DownloadItem] = []

    // MARK: - Dependencies

    private var orchestrator: DownloadOrchestrator?
    private let trackRepository: TrackRepository?
    private let sourceRepository: SourceRepository?

    init(
        trackRepository: TrackRepository? = nil,
        sourceRepository: SourceRepository? = nil
    ) {
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
    }

    /// Set up the orchestrator with library root. Called after initialization.
    func configure(libraryRoot: String, tokenStorage: TokenStorage) {
        self.orchestrator = DownloadOrchestrator(
            libraryRoot: libraryRoot,
            tokenStorage: tokenStorage
        )
    }

    // MARK: - Actions

    /// Download remote tracks that don't have local files yet.
    func downloadTracks(_ tracks: [Track]) async {
        guard let orchestrator else {
            AppLogger.shared.log("Download orchestrator not configured", level: .error, source: "Download")
            return
        }

        let remoteTracks = tracks.filter { $0.isRemote }
        guard !remoteTracks.isEmpty else { return }

        isDownloading = true
        totalCount = remoteTracks.count
        completedCount = 0
        failedCount = 0

        // Build download requests
        let requests = remoteTracks.map { track in
            DownloadOrchestrator.DownloadRequest(
                trackId: track.id ?? 0,
                artist: track.artist,
                title: track.title,
                query: "\(track.artist) - \(track.title)",
                soundcloudURL: nil,  // TODO: Lookup from track_sources
                userId: nil
            )
        }

        // Build queue items for UI
        queueItems = remoteTracks.map { track in
            DownloadItem(
                id: track.id ?? 0,
                trackId: track.id ?? 0,
                artist: track.artist,
                title: track.title,
                status: .queued,
                progress: 0
            )
        }

        let result = await orchestrator.downloadBatch(requests) { [weak self] index, total, current in
            self?.currentTrack = current
            self?.progress = Double(index) / Double(max(total, 1))
            self?.completedCount = index

            // Update queue item status
            if index < (self?.queueItems.count ?? 0) {
                self?.queueItems[index].status = .downloading
                if index > 0 {
                    self?.queueItems[index - 1].status = .completed
                }
            }
        }

        lastResult = result
        completedCount = result.succeeded
        failedCount = result.failed
        isDownloading = false
        progress = 1.0
        currentTrack = ""

        // Update track organized_paths in the database
        for (trackId, path) in result.downloadedPaths {
            do {
                try await trackRepository?.updateOrganizedPath(trackId: trackId, organizedPath: path)
            } catch {
                AppLogger.shared.log("Failed to update path for track \(trackId): \(error)", level: .error, source: "Download")
            }
        }

        AppLogger.shared.log(
            "Download batch complete: \(result.succeeded) succeeded, \(result.failed) failed, \(result.skipped) skipped",
            level: .info,
            source: "Download"
        )
    }

    /// Retry failed downloads from the queue.
    func retryFailed() async {
        guard let orchestrator else { return }
        isDownloading = true
        let result = await orchestrator.retryFailed()
        lastResult = result
        isDownloading = false
    }
}
