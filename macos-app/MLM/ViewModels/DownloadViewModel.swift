import SwiftUI

/// Narrow protocol over exactly the batch-download method `DownloadViewModel`
/// calls on `DownloadOrchestrator`. `DownloadOrchestrator` is a `final class`
/// (cannot be subclassed), so tests inject a fake conforming to this
/// protocol to exercise the tally/terminal-state logic in `downloadTracks`
/// deterministically instead of driving the real scdl/yt-dlp/ffmpeg chain.
///
/// Intentionally NOT `Sendable`-constrained: `DownloadOrchestrator` exposes
/// mutable `@Observable` state (`isRunning`, `currentItem`, `progress`) and
/// is not itself verified `Sendable`; requiring it here would force an
/// unchecked conformance on a type this plan does not otherwise touch.
protocol DownloadBatchRunning {
    func downloadBatch(
        _ requests: [DownloadOrchestrator.DownloadRequest],
        onProgress: ((Int, Int, String) -> Void)?,
        onTrackProgress: ((Double) -> Void)?
    ) async -> DownloadOrchestrator.BatchResult
}

extension DownloadOrchestrator: DownloadBatchRunning {}

protocol DownloadRetryRunning {
    func pendingRetryRequests() -> [DownloadOrchestrator.DownloadRequest]
    func persistedRetryItems() -> [DownloadQueue.QueueItem]
    func retryFailed(
        onProgress: ((Int, Int, String) -> Void)?,
        onTrackProgress: ((Double) -> Void)?
    ) async -> DownloadOrchestrator.BatchResult
    func dequeuePersistedRetries(trackIds: Set<Int64>)
}

extension DownloadOrchestrator: DownloadRetryRunning {}

/// Narrow protocol over exactly the DB-write method `DownloadViewModel`
/// calls on `TrackRepository` when persisting a downloaded track.
/// `TrackRepository` is a `final class`, so tests inject a throwing fake
/// conforming to this protocol to prove a DB-write failure demotes a track
/// from succeeded to failed before the UI-facing tally is finalized.
protocol DownloadTrackPersisting: Sendable {
    func markDownloadsInProgress(trackIds: [Int64]) async throws
    func clearDownloadsInProgress(trackIds: [Int64]) async throws
    func markAsDownloaded(
        trackId: Int64,
        organizedPath: String,
        format: String,
        bitrate: Int?,
        downloadStatus: String?
    ) async throws
    func persistDownloadFailure(
        trackId: Int64,
        reason: String,
        date: Date,
        minimumAttempts: Int
    ) async throws -> TrackDownloadFailure
}

/// Lifecycle writes are no-ops for narrow test persisters that only model
/// final DB persistence. The concrete `TrackRepository` supplies both writes.
extension DownloadTrackPersisting {
    func markDownloadsInProgress(trackIds: [Int64]) async throws {}
    func clearDownloadsInProgress(trackIds: [Int64]) async throws {}
}

extension TrackRepository: DownloadTrackPersisting {}

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

    /// Test seam: when set, `downloadTracks` runs the batch through this
    /// instead of the concrete `orchestrator`. Production code leaves this
    /// `nil` and relies on `configure(libraryRoot:tokenStorage:)` to build
    /// the real `DownloadOrchestrator`. Settable (not init-only) so a test
    /// can inject a fake without calling `configure`.
    var batchRunnerOverride: (any DownloadBatchRunning)?
    var retryRunnerOverride: (any DownloadRetryRunning)?

    /// Test seam: when set, `persistDownloadedTracks` writes through this
    /// instead of the concrete `trackRepository`. Production code leaves
    /// this `nil` and relies on the injected `trackRepository`.
    private let trackPersisterOverride: (any DownloadTrackPersisting)?

    /// The batch runner `downloadTracks` actually uses: the test override
    /// when present, otherwise the concrete configured orchestrator.
    private var activeBatchRunner: (any DownloadBatchRunning)? {
        batchRunnerOverride ?? orchestrator
    }

    private var activeRetryRunner: (any DownloadRetryRunning)? {
        retryRunnerOverride ?? orchestrator
    }

    /// The persister `persistDownloadedTracks` actually uses: the test
    /// override when present, otherwise the concrete injected repository.
    private var activeTrackPersister: (any DownloadTrackPersisting)? {
        trackPersisterOverride ?? trackRepository
    }

    /// The global retry action only handles legacy queue entries that are
    /// below its retry cap. Other durable failures remain available through
    /// Activity's per-row Retry action.
    var hasActionableRetryFailures: Bool {
        !(activeRetryRunner?.pendingRetryRequests().isEmpty ?? true)
    }

    /// Absolute path to the library root — used to convert orchestrator
    /// output paths to library-relative paths before storing in the DB.
    private(set) var libraryRoot: String = ""

    init(
        trackRepository: TrackRepository? = nil,
        sourceRepository: SourceRepository? = nil,
        trackPersister: (any DownloadTrackPersisting)? = nil
    ) {
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
        self.trackPersisterOverride = trackPersister
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
    ///
    /// - Parameter preferredSource: pin the download to a specific source
    ///   (e.g. `.soundcloud` for SoundCloud playlists). Defaults to `.auto`.
    func downloadTracks(
        _ tracks: [Track],
        preferredSource: DownloadOrchestrator.PreferredSource = .auto
    ) async {
        guard let runner = activeBatchRunner else {
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
            // When the download is pinned to YouTube, hand the orchestrator
            // the video URL directly (playlist tracks store it in
            // original_path) so it downloads the exact video instead of
            // running a fresh search.
            let ytURL: String? = preferredSource == .youtube
                ? youTubeURLFromOriginalPath(track.originalPath)
                : nil
            requests.append(
                DownloadOrchestrator.DownloadRequest(
                    trackId: track.id ?? 0,
                    artist: track.artist,
                    title: track.title,
                    query: "\(track.artist) - \(track.title)",
                    soundcloudURL: scURL,
                    userId: userId,
                    preferredSource: preferredSource,
                    youtubeURL: ytURL
                )
            )
        }

        await markDownloadsInProgress(trackIds: requests.map(\.trackId))

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

        let result = terminalResult(
            await runner.downloadBatch(
                requests,
                onProgress: { [weak self] index, total, current in
                    guard let self else { return }
                    self.currentTrack = current
                    self.currentTrackProgress = 0
                    self.progress = Double(index) / Double(max(total, 1))
                    self.completedCount = index

                    if index < self.queueItems.count {
                        self.queueItems[index].status = .downloading
                    }
                },
                onTrackProgress: { [weak self] fraction in
                    guard let self, self.totalCount > 0 else { return }
                    self.currentTrackProgress = fraction
                    // Combined: completed tracks plus the running fraction of
                    // the in-flight track, normalized by total batch size.
                    self.progress = (Double(self.completedCount) + fraction) / Double(self.totalCount)
                }
            ),
            requests: requests
        )

        // Persist the four download columns together for each succeeded
        // track: organized_path + format + bitrate + download_status.
        // Updating only organized_path leaves the Library showing stale
        // "0 kbps soundcloud" rows, which is one of the documented
        // invariants for this pipeline.
        let persistenceFailures = await persistDownloadedTracks(
            remoteTracks: remoteTracks,
            result: result
        )
        await persistTerminalFailures(result: result, requests: requests)
        await persistPersistenceFailures(trackIds: persistenceFailures)
        orchestrator?.enqueuePersistenceFailures(
            requests: requests,
            trackIds: persistenceFailures
        )
        let persistedTrackIds = Set(result.downloadedPaths.keys)
            .subtracting(persistenceFailures)
        activeRetryRunner?.dequeuePersistedRetries(trackIds: persistedTrackIds)
        await clearDownloadsInProgress(
            trackIds: result.failedTrackIds
                .union(result.skippedTrackIds)
                .union(result.cancelledTrackIds)
                .union(persistenceFailures)
        )

        let finalResult = resultAfterPersistence(
            result,
            persistenceFailures: persistenceFailures
        )
        applyTerminalStates(
            result: result,
            persistenceFailures: persistenceFailures
        )
        finishBatch(finalResult)
    }

    /// Retry failed downloads from the queue.
    func retryFailed() async {
        guard let retryRunner = activeRetryRunner else { return }
        let requests = retryRunner.pendingRetryRequests()
        guard !requests.isEmpty else { return }

        await PerformanceQueueService.shared.setExternalDownloadActive(true)
        defer {
            Task {
                await PerformanceQueueService.shared.setExternalDownloadActive(false)
            }
        }

        isDownloading = true
        totalCount = requests.count
        completedCount = 0
        failedCount = 0
        progress = 0
        queueItems = requests.map { request in
            DownloadItem(
                id: request.trackId,
                trackId: request.trackId,
                artist: request.artist,
                title: request.title,
                status: .queued,
                progress: 0
            )
        }

        await markDownloadsInProgress(trackIds: requests.map(\.trackId))

        let result = terminalResult(
            await retryRunner.retryFailed(
                onProgress: { [weak self] index, total, current in
                    guard let self else { return }
                    self.currentTrack = current
                    self.currentTrackProgress = 0
                    self.progress = Double(index) / Double(max(total, 1))
                    self.completedCount = index
                    if index < self.queueItems.count {
                        self.queueItems[index].status = .downloading
                    }
                },
                onTrackProgress: { [weak self] fraction in
                    guard let self, self.totalCount > 0 else { return }
                    self.currentTrackProgress = fraction
                    self.progress = (
                        Double(self.completedCount) + fraction
                    ) / Double(self.totalCount)
                }
            ),
            requests: requests
        )

        let persistenceFailures = await persistDownloadedTracks(
            remoteTracks: [],
            result: result
        )
        await persistTerminalFailures(result: result, requests: requests)
        await persistPersistenceFailures(trackIds: persistenceFailures)
        orchestrator?.enqueuePersistenceFailures(
            requests: requests,
            trackIds: persistenceFailures
        )
        let persistedTrackIds = Set(result.downloadedPaths.keys)
            .subtracting(persistenceFailures)
        retryRunner.dequeuePersistedRetries(trackIds: persistedTrackIds)
        await clearDownloadsInProgress(
            trackIds: result.failedTrackIds
                .union(result.skippedTrackIds)
                .union(result.cancelledTrackIds)
                .union(persistenceFailures)
        )

        let finalResult = resultAfterPersistence(
            result,
            persistenceFailures: persistenceFailures
        )
        applyTerminalStates(
            result: result,
            persistenceFailures: persistenceFailures
        )
        finishBatch(finalResult)
    }

    private func resultAfterPersistence(
        _ result: DownloadOrchestrator.BatchResult,
        persistenceFailures: Set<Int64>
    ) -> DownloadOrchestrator.BatchResult {
        var finalResult = result
        finalResult.succeeded = max(
            0,
            result.succeeded - persistenceFailures.count
        )
        finalResult.failed = result.failed + persistenceFailures.count
        finalResult.failedTrackIds.formUnion(persistenceFailures)
        for trackId in persistenceFailures {
            finalResult.failureReasons[trackId] = persistenceFailureReason
        }
        return finalResult
    }

    /// Make every request terminal even when an upstream runner fails to
    /// identify a failed track explicitly. This prevents a persisted
    /// `downloading` state from surviving a completed batch.
    private func terminalResult(
        _ result: DownloadOrchestrator.BatchResult,
        requests: [DownloadOrchestrator.DownloadRequest]
    ) -> DownloadOrchestrator.BatchResult {
        var terminal = result
        let requestIDs = Set(requests.map(\.trackId))
        let accountedFor = Set(result.downloadedPaths.keys)
            .union(result.failedTrackIds)
            .union(result.skippedTrackIds)
            .union(result.cancelledTrackIds)
        let implicitFailures = requestIDs.subtracting(accountedFor)
        terminal.failedTrackIds.formUnion(implicitFailures)
        for trackId in implicitFailures where terminal.failureReasons[trackId] == nil {
            terminal.failureReasons[trackId] = DownloadOrchestrator.DownloadFailureReason
                .sourcesExhausted
                .userFacingText
        }
        terminal.failed = max(terminal.failed, terminal.failedTrackIds.count)
        return terminal
    }

    /// Persist every provider-level terminal failure after the orchestrator
    /// returns its per-track outcome. The DB record, not the capped legacy
    /// retry queue, is the durable history shown after relaunch.
    private func persistTerminalFailures(
        result: DownloadOrchestrator.BatchResult,
        requests: [DownloadOrchestrator.DownloadRequest]
    ) async {
        guard let persister = activeTrackPersister else { return }
        let requestByTrackID = Dictionary(
            uniqueKeysWithValues: requests.map { ($0.trackId, $0) }
        )

        for trackId in result.failedTrackIds {
            let reason = result.failureReasons[trackId]
                ?? DownloadOrchestrator.DownloadFailureReason.sourcesExhausted.userFacingText
            let priorQueueAttempts = requestByTrackID[trackId]?.previousAttemptCount ?? 0
            do {
                _ = try await persister.persistDownloadFailure(
                    trackId: trackId,
                    reason: reason,
                    date: Date(),
                    minimumAttempts: priorQueueAttempts + 1
                )
            } catch {
                // Do not mask the original terminal download outcome. The
                // legacy retry queue remains available as a fallback when a
                // database write itself fails.
                AppLogger.shared.error(
                    "Failed to persist download failure for track \(trackId): \(error.localizedDescription)",
                    source: "Download"
                )
            }
        }
    }

    /// A file that downloaded but could not be finalized in GRDB is still a
    /// durable, user-actionable download failure whenever the database write
    /// remains available. The legacy queue is only the fallback for a truly
    /// unavailable database.
    private func persistPersistenceFailures(trackIds: Set<Int64>) async {
        guard !trackIds.isEmpty, let persister = activeTrackPersister else { return }

        for trackId in trackIds {
            do {
                _ = try await persister.persistDownloadFailure(
                    trackId: trackId,
                    reason: persistenceFailureReason,
                    date: Date(),
                    minimumAttempts: 1
                )
            } catch {
                AppLogger.shared.error(
                    "Failed to persist finalization failure for track \(trackId): \(error.localizedDescription)",
                    source: "Download"
                )
            }
        }
    }

    private func markDownloadsInProgress(trackIds: [Int64]) async {
        guard let persister = activeTrackPersister else { return }
        do {
            try await persister.markDownloadsInProgress(trackIds: trackIds)
        } catch {
            AppLogger.shared.error(
                "Failed to mark downloads in progress: \(error.localizedDescription)",
                source: "Download"
            )
        }
    }

    private func clearDownloadsInProgress(trackIds: Set<Int64>) async {
        guard !trackIds.isEmpty, let persister = activeTrackPersister else { return }
        do {
            try await persister.clearDownloadsInProgress(trackIds: Array(trackIds))
        } catch {
            AppLogger.shared.error(
                "Failed to clear download activity state: \(error.localizedDescription)",
                source: "Download"
            )
        }
    }

    func persistedRetryItems() -> [DownloadQueue.QueueItem] {
        activeRetryRunner?.persistedRetryItems() ?? []
    }

    private func applyTerminalStates(
        result: DownloadOrchestrator.BatchResult,
        persistenceFailures: Set<Int64>
    ) {
        for index in queueItems.indices {
            let trackId = queueItems[index].trackId
            if persistenceFailures.contains(trackId) {
                queueItems[index].status = .failed
                queueItems[index].error = "downloaded but not saved to library"
            } else if result.downloadedPaths[trackId] != nil {
                queueItems[index].status = .completed
                queueItems[index].error = nil
            } else if result.skippedTrackIds.contains(trackId) {
                queueItems[index].status = .skipped
                queueItems[index].error = nil
            } else if result.cancelledTrackIds.contains(trackId) {
                queueItems[index].status = .cancelled
                queueItems[index].error = "download cancelled"
            } else {
                queueItems[index].status = .failed
                queueItems[index].error = result.failureReasons[trackId]
                    ?? DownloadOrchestrator.DownloadFailureReason.sourcesExhausted.userFacingText
            }
        }
    }

    private func finishBatch(_ result: DownloadOrchestrator.BatchResult) {
        lastResult = result
        completedCount = result.succeeded
        failedCount = result.failed
        isDownloading = false
        progress = 1.0
        currentTrack = ""

        NotificationCenter.default.post(
            name: .downloadDidComplete,
            object: nil,
            userInfo: [
                "succeeded": result.succeeded,
                "failed": result.failed,
            ]
        )

        AppLogger.shared.log(
            "Download batch complete: \(result.succeeded) succeeded, \(result.failed) failed, \(result.skipped) skipped",
            level: .info,
            source: "Download"
        )
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

    /// Retry one persisted Activity failure through the normal per-track
    /// download path. This does not pretend that the legacy queue's global
    /// retry operation can safely target a single row.
    func retryDownload(trackId: Int64) async {
        guard let trackRepository else {
            AppLogger.shared.error(
                "Cannot retry download because the track repository is unavailable",
                source: "Download"
            )
            return
        }

        do {
            guard let track = try await trackRepository.fetchTrack(id: trackId), track.isRemote else {
                return
            }
            await downloadTracks([track], preferredSource: preferredSource(for: track))
        } catch {
            AppLogger.shared.error(
                "Could not load track \(trackId) for retry: \(error.localizedDescription)",
                source: "Download"
            )
        }
    }

    /// Retry every persisted Activity failure in a single batch.
    /// Fetches each track and hands them to the normal download path so
    /// the orchestrator re-runs its source chain per track.
    func retryAllFailed(trackIds: [Int64]) async {
        guard let trackRepository else {
            AppLogger.shared.error(
                "Cannot retry downloads because the track repository is unavailable",
                source: "Download"
            )
            return
        }

        var tracks: [Track] = []
        for trackId in trackIds {
            if let track = try? await trackRepository.fetchTrack(id: trackId), track.isRemote {
                tracks.append(track)
            }
        }
        guard !tracks.isEmpty else { return }
        await downloadTracks(tracks)
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
                AppLogger.shared.log("Discovery download error for \(request.title): \(error)", level: .error, source: "Download")
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
    ) async -> Set<Int64> {
        guard let persister = activeTrackPersister else {
            let trackIds = Set(result.downloadedPaths.keys)
            if !trackIds.isEmpty {
                AppLogger.shared.error(
                    "Downloaded files could not be saved because the track repository is unavailable",
                    source: "Download"
                )
            }
            return trackIds
        }

        let trackById = Dictionary(uniqueKeysWithValues: remoteTracks.compactMap { t -> (Int64, Track)? in
            guard let id = t.id else { return nil }
            return (id, t)
        })
        var failures: Set<Int64> = []

        for (trackId, _) in result.downloadedPaths {
            guard let absolutePath = result.downloadedPaths[trackId] else { continue }
            let info = result.downloadedMetadata[trackId]
            let format = info?.format ?? (absolutePath as NSString).pathExtension.lowercased()
            let bitrate = info?.bitrate ?? trackById[trackId]?.bitrate
            let relative = relativeLibraryPath(for: absolutePath)
            do {
                try await persister.markAsDownloaded(
                    trackId: trackId,
                    organizedPath: relative,
                    format: format,
                    bitrate: bitrate,
                    downloadStatus: nil
                )
            } catch {
                failures.insert(trackId)
                AppLogger.shared.log(
                    "Failed to update DB for track \(trackId): \(error)",
                    level: .error,
                    source: "Download"
                )
                continue
            }

            // Analysis scheduling is best-effort and must not turn a
            // successful library DB write into a reported download failure.
            if let trackRepository {
                do {
                    if let updatedTrack = try await trackRepository.fetchTrack(id: trackId) {
                        await PerformanceQueueService.shared.enqueueAnalysis(track: updatedTrack)
                    }
                } catch {
                    AppLogger.shared.warn(
                        "Downloaded track \(trackId) was saved, but analysis scheduling failed: \(error.localizedDescription)",
                        source: "Download"
                    )
                }
            }
        }

        return failures
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

    private var persistenceFailureReason: String {
        "Downloaded file could not be saved to library"
    }

    /// Preserve an explicit source link when the track itself provides one;
    /// otherwise let the fallback chain use all available providers.
    private func preferredSource(for track: Track) -> DownloadOrchestrator.PreferredSource {
        let path = track.originalPath.lowercased()
        if path.contains("youtube.com/") || path.contains("youtu.be/") {
            return .youtube
        }
        if path.contains("soundcloud.com/") {
            return .soundcloud
        }
        return .auto
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

    /// Return the original_path when it's a URL usable by a YouTube-pinned
    /// download. yt-dlp's `downloadByURL` supports YouTube *and* hundreds of
    /// other sites (the link-downloader feeds arbitrary URLs), so any
    /// http(s) URL is accepted here.
    private func youTubeURLFromOriginalPath(_ path: String) -> String? {
        guard path.hasPrefix("https://") || path.hasPrefix("http://") else {
            return nil
        }
        return path
    }
}
