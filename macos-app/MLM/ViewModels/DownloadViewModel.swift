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

    /// Absolute path to the library root — used to convert orchestrator
    /// output paths to library-relative paths before storing in the DB.
    private(set) var libraryRoot: String = ""

    init(
        trackRepository: TrackRepository? = nil,
        sourceRepository: SourceRepository? = nil
    ) {
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
    }

    /// Set up the orchestrator with library root. Called after initialization.
    func configure(libraryRoot: String, tokenStorage: TokenStorage) {
        self.libraryRoot = libraryRoot
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

        // Build download requests — look up the SoundCloud permalink URL
        // for each track so the orchestrator can attempt a direct scdl
        // download before falling back to DAB/YouTube.
        var requests: [DownloadOrchestrator.DownloadRequest] = []
        requests.reserveCapacity(remoteTracks.count)
        for track in remoteTracks {
            let (scURL, userId) = await resolveSoundCloudURL(for: track)
            requests.append(
                DownloadOrchestrator.DownloadRequest(
                    trackId: track.id ?? 0,
                    artist: track.artist,
                    title: track.title,
                    query: "\(track.artist) - \(track.title)",
                    soundcloudURL: scURL,
                    userId: userId
                )
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

        // Persist the four download columns together for each succeeded
        // track: organized_path + format + bitrate + download_status.
        // Updating only organized_path leaves the Library showing stale
        // "0 kbps soundcloud" rows, which is one of the documented
        // invariants for this pipeline.
        await persistDownloadedTracks(remoteTracks: remoteTracks, result: result)

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

    // MARK: - Persistence

    /// Persist successful downloads into the `tracks` table.
    ///
    /// For each succeeded track:
    /// - `organized_path` ← library-relative path
    /// - `format` ← container extension reported by the orchestrator
    /// - `bitrate` ← `TranscodeService.targetBitrate` (248) when the file
    ///   was transcoded, or the track's existing bitrate when the
    ///   transcode was skipped (lossy < 248k source preserved as-is).
    /// - `download_status` ← ISO 8601 timestamp
    private func persistDownloadedTracks(
        remoteTracks: [Track],
        result: DownloadOrchestrator.BatchResult
    ) async {
        let trackById = Dictionary(uniqueKeysWithValues: remoteTracks.compactMap { t -> (Int64, Track)? in
            guard let id = t.id else { return nil }
            return (id, t)
        })

        for (trackId, _) in result.downloadedPaths {
            guard let absolutePath = result.downloadedPaths[trackId] else { continue }
            let info = result.downloadedMetadata[trackId]
            let format = info?.format ?? (absolutePath as NSString).pathExtension.lowercased()
            let bitrate = info?.bitrate ?? trackById[trackId]?.bitrate
            let relative = relativeLibraryPath(for: absolutePath)
            do {
                try await trackRepository?.markAsDownloaded(
                    trackId: trackId,
                    organizedPath: relative,
                    format: format,
                    bitrate: bitrate
                )
            } catch {
                AppLogger.shared.log(
                    "Failed to update DB for track \(trackId): \(error)",
                    level: .error,
                    source: "Download"
                )
            }
        }
    }

    /// Convert an absolute filesystem path to a library-relative path.
    ///
    /// The DB stores `organized_path` and `download_destination` as paths
    /// relative to `library_root` (e.g. `00_Artists/Yeat/Mr. Lordbow.m4a`)
    /// — the frontend joins `library_root + organized_path` to reach the
    /// absolute path. Storing absolute paths here breaks portability when
    /// the library moves to a different mount point.
    ///
    /// Falls back to returning `path` unchanged when it doesn't sit under
    /// the configured root (defensive — shouldn't happen in practice).
    private func relativeLibraryPath(for path: String) -> String {
        guard !libraryRoot.isEmpty else { return path }

        let normalizedRoot = URL(fileURLWithPath: libraryRoot)
            .standardizedFileURL.path
        let normalizedPath = URL(fileURLWithPath: path)
            .standardizedFileURL.path

        // Use a trailing slash so we don't accidentally match a sibling
        // directory with the same prefix as the root.
        let rootWithSlash = normalizedRoot.hasSuffix("/")
            ? normalizedRoot
            : normalizedRoot + "/"

        if normalizedPath.hasPrefix(rootWithSlash) {
            return String(normalizedPath.dropFirst(rootWithSlash.count))
        }
        // Last-resort: strip a leading `/` so the value at least looks
        // relative; log a warning so we notice mis-configured roots.
        AppLogger.shared.log(
            "Downloaded path \(normalizedPath) is not under library root \(normalizedRoot)",
            level: .warning,
            source: "Download"
        )
        var trimmed = normalizedPath
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        return trimmed
    }

    // MARK: - Helpers

    /// Resolve the SoundCloud permalink URL and user ID for a track, if any.
    ///
    /// Logic:
    /// 1. Look up `track_sources` rows for this track. If a "soundcloud"
    ///    source link exists, capture its user_id (so scdl can be invoked
    ///    against the correct account) and keep its `external_id` as a
    ///    fallback synthetic URL.
    /// 2. Prefer `track.originalPath` when it's an `https://soundcloud.com/…`
    ///    permalink URL (set during SoundCloud sync).
    /// 3. Otherwise, synthesize `https://api.soundcloud.com/tracks/<id>`
    ///    from the external_id — `scdl` accepts API URLs too.
    private func resolveSoundCloudURL(for track: Track) async -> (url: String?, userId: String?) {
        guard let trackId = track.id, let sourceRepo = sourceRepository else {
            // No DB lookup possible — only use originalPath if it's a real URL
            return (soundCloudURLFromOriginalPath(track.originalPath), nil)
        }

        var externalId: String?
        var userId: String?
        do {
            let trackSources = try await sourceRepo.fetchTrackSources(trackId: trackId)
            for trackSource in trackSources {
                // Find the source row to confirm it's SoundCloud
                let allSources = try await sourceRepo.fetchAll()
                if let src = allSources.first(where: { $0.id == trackSource.sourceId }),
                   src.name == "soundcloud" {
                    externalId = trackSource.externalId
                    userId = src.userId
                    break
                }
            }
        } catch {
            AppLogger.shared.log(
                "Failed to resolve track_sources for track \(trackId): \(error)",
                level: .warning,
                source: "Download"
            )
        }

        // Prefer the permalink URL stored on the Track itself.
        if let permalink = soundCloudURLFromOriginalPath(track.originalPath) {
            return (permalink, userId)
        }
        // Fall back to the SoundCloud API URL via the external_id.
        if let id = externalId, !id.isEmpty {
            return ("https://api.soundcloud.com/tracks/\(id)", userId)
        }
        return (nil, userId)
    }

    /// Returns `originalPath` only if it looks like a real SoundCloud
    /// permalink URL. Filters out synthetic `soundcloud://<id>` schemes,
    /// `spotify:track:<id>` URIs, and on-disk paths so the orchestrator
    /// doesn't hand scdl something it can't resolve.
    private func soundCloudURLFromOriginalPath(_ path: String) -> String? {
        guard path.hasPrefix("https://soundcloud.com/") ||
              path.hasPrefix("http://soundcloud.com/") ||
              path.hasPrefix("https://api.soundcloud.com/") else {
            return nil
        }
        return path
    }
}
