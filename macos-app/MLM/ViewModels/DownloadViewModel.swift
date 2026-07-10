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
    /// Combined batch progress (0...1): track index plus the running
    /// progress reported by scdl/yt-dlp for the in-flight track.
    private(set) var progress: Double = 0
    /// Progress of the currently downloading track (0...1) — driven by
    /// scdl/yt-dlp's `[download] XX.X%` lines on stderr.
    private(set) var currentTrackProgress: Double = 0
    private(set) var completedCount: Int = 0
    private(set) var failedCount: Int = 0
    private(set) var totalCount: Int = 0
    private(set) var lastResult: DownloadOrchestrator.BatchResult?

    /// Queue of pending download items for display.
    private(set) var queueItems: [DownloadItem] = []

    enum DiscoveryStatus: String, Sendable, Codable {
        case queued = "queued"
        case downloading = "downloading"
        case downloaded = "downloaded"
        case failed = "failed"
    }

    struct DiscoveryDownloadRequest: Sendable, Hashable {
        let artist: String
        let title: String
        let soundcloudURL: String?
        let source: String
        let seedTrack: Track
    }

    private(set) var discoveryStatuses: [String: DiscoveryStatus] = [:]
    private var discoveryQueue: [DiscoveryDownloadRequest] = []
    private var isProcessingDiscoveryQueue = false

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

        // Notify priority queue service that download is active
        await PerformanceQueueService.shared.setExternalDownloadActive(true)
        defer {
            Task {
                await PerformanceQueueService.shared.setExternalDownloadActive(false)
            }
        }

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

        let result = await orchestrator.downloadBatch(
            requests,
            onProgress: { [weak self] index, total, current in
                guard let self else { return }
                self.currentTrack = current
                self.currentTrackProgress = 0
                self.progress = Double(index) / Double(max(total, 1))
                self.completedCount = index

                if index < self.queueItems.count {
                    self.queueItems[index].status = .downloading
                    if index > 0 {
                        self.queueItems[index - 1].status = .completed
                    }
                }
            },
            onTrackProgress: { [weak self] fraction in
                guard let self, self.totalCount > 0 else { return }
                self.currentTrackProgress = fraction
                // Combined: completed tracks plus the running fraction of
                // the in-flight track, normalized by total batch size.
                self.progress = (Double(self.completedCount) + fraction) / Double(self.totalCount)
            }
        )

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

        // Notify Library / Folders / Sidebar so the downloaded rows can
        // move from the Remote tab to the Local tab without requiring a
        // manual re-scan.
        NotificationCenter.default.post(
            name: .downloadDidComplete,
            object: nil,
            userInfo: [
                "succeeded": result.succeeded,
                "failed": result.failed
            ]
        )

        AppLogger.shared.log(
            "Download batch complete: \(result.succeeded) succeeded, \(result.failed) failed, \(result.skipped) skipped",
            level: .info,
            source: "Download"
        )
    }

    /// Retry failed downloads from the queue.
    func retryFailed() async {
        guard let orchestrator else { return }
        
        await PerformanceQueueService.shared.setExternalDownloadActive(true)
        defer {
            Task {
                await PerformanceQueueService.shared.setExternalDownloadActive(false)
            }
        }
        
        isDownloading = true
        let result = await orchestrator.retryFailed()
        lastResult = result
        isDownloading = false
    }

    /// Ask the orchestrator to stop after the current track.
    ///
    /// The active scdl/yt-dlp/ffmpeg process is allowed to complete so
    /// the on-disk and DB state stay consistent. Subsequent tracks are
    /// skipped.
    func cancel() {
        orchestrator?.cancel()
        AppLogger.shared.log(
            "Download cancel requested",
            level: .info,
            source: "Download"
        )
    }

    /// Download a recommended swarm track, extract its metadata, insert it in the DB, and register in track_discovery_log as 'new'.
    func downloadDiscoveryTrack(
        artist: String,
        title: String,
        soundcloudURL: String?,
        source: String,
        seedTrack: Track
    ) {
        let key = soundcloudURL ?? "\(artist) - \(title)"
        
        // Don't duplicate downloads
        if discoveryStatuses[key] == .queued || discoveryStatuses[key] == .downloading {
            return
        }
        
        let request = DiscoveryDownloadRequest(
            artist: artist,
            title: title,
            soundcloudURL: soundcloudURL,
            source: source,
            seedTrack: seedTrack
        )
        
        discoveryStatuses[key] = .queued
        discoveryQueue.append(request)
        
        // Start background processing if not already running
        if !isProcessingDiscoveryQueue {
            Task {
                await processDiscoveryQueue()
            }
        }
    }

    private func processDiscoveryQueue() async {
        guard let orchestrator, let trackRepository else { return }
        isProcessingDiscoveryQueue = true
        
        await PerformanceQueueService.shared.setExternalDownloadActive(true)
        defer {
            Task {
                await PerformanceQueueService.shared.setExternalDownloadActive(false)
            }
        }
        
        while !discoveryQueue.isEmpty {
            let request = discoveryQueue.removeFirst()
            let key = request.soundcloudURL ?? "\(request.artist) - \(request.title)"
            
            await MainActor.run {
                self.discoveryStatuses[key] = .downloading
                self.isDownloading = true
                self.currentTrack = "\(request.artist) - \(request.title)"
                self.currentTrackProgress = 0
                self.progress = 0
            }
            
            // Determine destination folder inside "Discovered Neighbors"
            let libURL = URL(fileURLWithPath: libraryRoot)
            let discoveryRoot = libURL.appendingPathComponent("Discovered Neighbors")
            let seedFolder = "\(request.seedTrack.artist) - \(request.seedTrack.title)"
            let targetDir = discoveryRoot.appendingPathComponent(seedFolder)
            
            do {
                // Perform download
                let fileURL = try await orchestrator.downloadDiscoveryTrack(
                    artist: request.artist,
                    title: request.title,
                    soundcloudURL: request.soundcloudURL,
                    targetDir: targetDir,
                    onProgress: { [weak self] pct in
                        Task { @MainActor [weak self] in
                            self?.currentTrackProgress = pct
                            self?.progress = pct
                        }
                    }
                )
                
                guard let fileURL = fileURL else {
                    await MainActor.run {
                        self.discoveryStatuses[key] = .failed
                    }
                    continue
                }
                
                // Extract metadata using MetadataExtractor
                let metadata = try? await MetadataExtractor.extract(from: fileURL)
                
                // Generate absolute organized path relative to libraryRoot to keep DB consistent
                let relativePath = fileURL.path.replacingOccurrences(of: libURL.path + "/", with: "")
                
                // Determine format and bitrate
                let format = fileURL.pathExtension.lowercased()
                let bitrate = await orchestrator.transcodeService.detectBitrateKbps(fileURL)
                
                // Create the Track struct
                let newTrack = Track(
                    id: nil,
                    artist: metadata?.artist.isEmpty == false ? metadata!.artist : request.artist,
                    albumArtist: metadata?.albumArtist.isEmpty == false ? metadata!.albumArtist : request.artist,
                    album: metadata?.album.isEmpty == false ? metadata!.album : "Discovered Neighbors",
                    title: metadata?.title.isEmpty == false ? metadata!.title : request.title,
                    genre: metadata?.genre,
                    year: metadata?.year,
                    bitrate: bitrate,
                    duration: metadata?.duration,
                    format: format,
                    originalPath: fileURL.path,
                    organizedPath: relativePath,
                    isDuplicate: 0,
                    dateAdded: ISO8601DateFormatter().string(from: Date()),
                    downloadStatus: ISO8601DateFormatter().string(from: Date())
                )
                
                // Save track to DB
                let insertedTrack = try await trackRepository.insert(newTrack)
                guard let newTrackId = insertedTrack.id else {
                    await MainActor.run {
                        self.discoveryStatuses[key] = .failed
                    }
                    continue
                }
                
                // Enqueue discovery track for auto-analysis
                await PerformanceQueueService.shared.enqueueAnalysis(track: insertedTrack)
                
                // Register in track_discovery_log
                try await trackRepository.saveDiscoveryLog(
                    discoveredTrackId: newTrackId,
                    seedTrackId: request.seedTrack.id,
                    source: request.source,
                    status: "new"
                )
                
                await MainActor.run {
                    self.discoveryStatuses[key] = .downloaded
                }
                
                // Post notification so the library and inbox views reload
                NotificationCenter.default.post(
                    name: .downloadDidComplete,
                    object: nil,
                    userInfo: [
                        "succeeded": 1,
                        "failed": 0
                    ]
                )
            } catch {
                AppLogger.shared.log("Discovery queue download failed for \(request.title): \(error)", level: .error, source: "Download")
                await MainActor.run {
                    self.discoveryStatuses[key] = .failed
                }
            }
        }
        
        await MainActor.run {
            self.isDownloading = false
            self.currentTrack = ""
            self.progress = 1.0
            self.isProcessingDiscoveryQueue = false
        }
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
                
                // Enqueue downloaded track for auto-analysis
                if let updatedTrack = try await trackRepository?.fetchTrack(id: trackId) {
                    await PerformanceQueueService.shared.enqueueAnalysis(track: updatedTrack)
                }
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
        // 1. Real permalink URL stored on the Track itself — always preferred.
        if let permalink = soundCloudURLFromOriginalPath(track.originalPath) {
            return (permalink, nil)
        }

        var externalId: String?
        var userId: String?

        // 2. Walk track_sources for a SC linkage. We accept rows with
        //    source_id=0 or unknown source rows too, because earlier sync
        //    versions occasionally wrote orphaned entries — as long as the
        //    external_id parses as a SoundCloud track ID, it's usable.
        if let trackId = track.id, let sourceRepo = sourceRepository {
            do {
                let trackSources = try await sourceRepo.fetchTrackSources(trackId: trackId)
                let allSources = try await sourceRepo.fetchAll()
                for ts in trackSources {
                    let isExplicitSC = allSources
                        .first(where: { $0.id == ts.sourceId })?.name == "soundcloud"
                    let looksLikeSC = ts.externalId.hasPrefix("soundcloud:") ||
                                      ts.externalId.allSatisfy(\.isNumber)
                    guard isExplicitSC || looksLikeSC else { continue }

                    externalId = ts.externalId
                    if let src = allSources.first(where: { $0.id == ts.sourceId }) {
                        userId = src.userId
                    }
                    break
                }
            } catch {
                AppLogger.shared.log(
                    "Failed to resolve track_sources for track \(trackId): \(error)",
                    level: .warning,
                    source: "Download"
                )
            }
        }

        // 3. Fall back to synthetic `soundcloud://<id>` stored in original_path.
        if externalId == nil, let id = soundCloudIdFromSyntheticPath(track.originalPath) {
            externalId = id
        }

        guard let raw = externalId, !raw.isEmpty else {
            return (nil, userId)
        }

        // Normalize: legacy entries store `soundcloud:<id>`, fresh sync stores `<id>`.
        // scdl needs the bare numeric ID in the URL.
        let bare = raw.hasPrefix("soundcloud:")
            ? String(raw.dropFirst("soundcloud:".count))
            : raw
        guard !bare.isEmpty, bare.allSatisfy(\.isNumber) else {
            return (nil, userId)
        }

        return ("https://api.soundcloud.com/tracks/\(bare)", userId)
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

    /// Extract the bare SoundCloud track ID from a synthetic
    /// `soundcloud://<id>` original_path. Returns nil for anything else.
    private func soundCloudIdFromSyntheticPath(_ path: String) -> String? {
        let prefix = "soundcloud://"
        guard path.hasPrefix(prefix) else { return nil }
        let id = String(path.dropFirst(prefix.count))
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return id
    }
}
