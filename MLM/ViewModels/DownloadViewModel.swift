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
    private var activeBatchID: UUID?

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
        /// Held in Discover ▸ Recommendations until kept (v49, IMP-053) — `false`: a library
        /// track from the start (`Keep` in Similar ▸ Online).
        var hold = true
    }

    private(set) var discoveryStatuses: [String: DiscoveryStatus] = [:]
    private(set) var discoveryFailureMessages: [String: String] = [:]
    private var discoveryQueue: [DiscoveryDownloadRequest] = []
    private var isProcessingDiscoveryQueue = false

    // MARK: - Dependencies

    private var orchestrator: DownloadOrchestrator?
    /// The Activity registry (W3-ACT). Every batch is one operation in the `.downloads` lane.
    let activity: ActivityCenter
    /// Track ids queued or downloading in the lane, and their operation (B1, S1).
    let ledger = DownloadLedger()
    /// Test seam: reads a track again when its batch's turn comes (default: the repository).
    var trackFetchOverride: (@Sendable (Int64) async -> Track?)?
    /// Whether a volume (`/Volumes/<name>`) is mounted — the reconciler's check; tests fake it.
    var isVolumeMounted: @Sendable (String) -> Bool = { MountObserver.isVolumeMounted($0) }
    /// How often a waiting batch re-checks the drive (besides the mount notification).
    var driveRecheckInterval: TimeInterval = 3
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
    /// Set by `configure`; tests set it directly to exercise the drive wait.
    var libraryRoot: String = ""

    init(
        trackRepository: TrackRepository? = nil,
        sourceRepository: SourceRepository? = nil,
        trackPersister: (any DownloadTrackPersisting)? = nil,
        activity: ActivityCenter = ActivityCenter()
    ) {
        self.activity = activity
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
        self.trackPersisterOverride = trackPersister
    }

    /// Set up the orchestrator with library root. Called after initialization.
    func configure(libraryRoot: String, tokenStorage: TokenStorage) {
        self.libraryRoot = libraryRoot
        let orchestrator = DownloadOrchestrator(
            libraryRoot: libraryRoot,
            tokenStorage: tokenStorage
        )
        // Belt and braces (B1): a track that has a file by the time its turn comes is skipped.
        let repository = trackRepository
        orchestrator.isAlreadyLocal = { id in
            guard let track = try? await repository?.fetchTrack(id: id) else { return false }
            return !track.isRemote
        }
        self.orchestrator = orchestrator
    }

    // MARK: - Actions

    /// Download remote tracks that don't have local files yet.
    ///
    /// One Activity operation per request, in the `downloads` lane (W3-ACT):
    /// - Tracks already queued or downloading in the lane are left out; a request with nothing
    ///   new registers nothing and says `Already downloading` / `Already queued` (B1).
    /// - When its turn comes the tracks are read again from the database: only those still
    ///   without a file are downloaded (another batch may have done them meanwhile, B1).
    /// - Cancel is this operation's own (`ticket`, Activity, `cancel(containing:)`); it is honoured
    ///   between every preparatory step and stops after the current track while running (S1, S2).
    /// - A drive that goes away before or during the run makes the operation wait for it and
    ///   continue as the same operation — never failures (UC-JOB-10, S3).
    ///
    /// - Parameter preferredSource: pin the download to a specific source
    ///   (e.g. `.soundcloud` for SoundCloud playlists). Defaults to `.auto`.
    @discardableResult
    func downloadTracks(
        _ tracks: [Track],
        preferredSource: DownloadOrchestrator.PreferredSource = .auto,
        artworkURL: String? = nil,
        context: DownloadActivityContext? = nil,
        ticket: DownloadTicket? = nil
    ) async -> DownloadOrchestrator.BatchResult? {
        guard let runner = activeBatchRunner else {
            AppLogger.shared.log("Download orchestrator not configured", level: .error, source: "Download")
            return nil
        }

        let remoteTracks = tracks.filter { $0.isRemote }
        guard !remoteTracks.isEmpty else { return nil }

        // B1: leave out what the lane already has.
        let operationID = UUID()
        let claim = ledger.claim(remoteTracks.compactMap(\.id), for: operationID)
        let claimed = Set(claim.fresh)
        let requested = remoteTracks.filter { track in track.id.map(claimed.contains) ?? true }
        guard !requested.isEmpty else {
            activity.postNote(claim.anyRunning ? "Already downloading" : "Already queued")
            return nil
        }
        defer { ledger.release(claimed, for: operationID) }

        let control = DownloadBatchControl()
        let job = activity.begin(
            context?.kind ?? .download,
            title: context?.title ?? Self.batchTitle(count: requested.count),
            subject: context?.subject ?? .tracks(requested.compactMap(\.id)),
            progress: ActivityProgress(total: requested.count),
            itemNoun: .track,
            messageName: context?.messageName ?? "Download",
            controls: batchControls(control, pin: preferredSource),
            lane: .downloads,
            id: operationID
        )
        ticket?.attach(operationID, center: activity)
        guard await job.waitForTurn() else { return nil }
        ledger.markRunning(operationID)

        // B1: what still needs a file now that the turn has come.
        let current = await stillRemote(requested)
        guard !current.isEmpty else {
            job.discard()
            return nil
        }

        var total = DownloadOrchestrator.BatchResult()
        var pending = current
        var wasCancelled = false
        while !pending.isEmpty {
            // Work that needs the drive waits while it is away and says so (UC-JOB-10).
            guard await waitForLibraryFolder(job: job, control: control) else {
                wasCancelled = true
                break
            }
            guard let run = await runBatch(pending, runner: runner, preferredSource: preferredSource,
                                           artworkURL: artworkURL, job: job, control: control,
                                           offset: total.succeeded + total.failed + total.skipped,
                                           grandTotal: current.count) else {
                wasCancelled = true
                break
            }
            total = Self.merged(total, run.result)
            if control.isCancelled || !run.result.cancelledTrackIds.isEmpty {
                wasCancelled = true
                break
            }
            // Downloads the drive interrupted continue — same operation — once it is back.
            pending = run.driveWaiting.isEmpty ? [] : await stillRemote(current.filter { $0.id.map(run.driveWaiting.contains) ?? false })
        }

        let activityResult = Self.activityResult(total, tracks: current, wasCancelled: wasCancelled, pin: preferredSource)
        if wasCancelled {
            job.cancelled(activityResult)
        } else {
            job.finish(activityResult)
        }
        activity.scheduleFailingRefresh()
        return total
    }

    /// One run of the orchestrator over `tracks`. `nil` = cancelled before anything started (all
    /// preparatory state undone). `driveWaiting` = tracks the drive interrupted (not failures).
    private func runBatch(
        _ tracks: [Track],
        runner: any DownloadBatchRunning,
        preferredSource: DownloadOrchestrator.PreferredSource,
        artworkURL: String?,
        job: ActivityOperationHandle,
        control: DownloadBatchControl,
        offset: Int,
        grandTotal: Int
    ) async -> (result: DownloadOrchestrator.BatchResult, driveWaiting: Set<Int64>)? {
        guard !control.isCancelled else { return nil }

        // Build download requests — look up the SoundCloud permalink URL
        // for each track so the orchestrator can attempt a direct scdl
        // download before falling back to DAB/YouTube.
        var requests: [DownloadOrchestrator.DownloadRequest] = []
        requests.reserveCapacity(tracks.count)
        for track in tracks {
            let (scURL, userId) = await resolveSoundCloudURL(for: track)
            guard !control.isCancelled else { return nil }  // S2
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
                    youtubeURL: ytURL,
                    artworkURL: artworkURL
                )
            )
        }

        await markDownloadsInProgress(trackIds: requests.map(\.trackId))
        // S2: a cancel during the preparation undoes it — nothing started.
        func undoPreparation() async {
            await clearDownloadsInProgress(trackIds: Set(requests.map(\.trackId)))
        }
        guard !control.isCancelled else {
            await undoPreparation()
            return nil
        }

        let batchID = UUID()
        activeBatchID = batchID
        isDownloading = true
        totalCount = tracks.count
        completedCount = 0
        failedCount = 0

        // Notify priority queue service that download is active
        await PerformanceQueueService.shared.setExternalDownloadActive(true)
        defer {
            Task {
                await PerformanceQueueService.shared.setExternalDownloadActive(false)
            }
        }

        // Build queue items for UI
        queueItems = tracks.map { track in
            DownloadItem(
                id: track.id ?? 0,
                trackId: track.id ?? 0,
                artist: track.artist,
                title: track.title,
                status: .queued,
                progress: 0
            )
        }

        // The orchestrator's stop flag belongs to this batch only (S1: never sticky).
        orchestrator?.clearCancelRequest()
        control.setRunning(true)
        guard !control.isCancelled else {
            control.setRunning(false)
            await undoPreparation()
            if activeBatchID == batchID { activeBatchID = nil; isDownloading = false }
            return nil
        }
        let rawResult = await runner.downloadBatch(
                requests,
                onProgress: { [weak self] index, total, current in
                    job.update(completed: offset + index, total: grandTotal, currentItem: current)
                    guard let self, self.activeBatchID == batchID else { return }
                    self.currentTrack = current
                    self.currentTrackProgress = 0
                    self.progress = Double(index) / Double(max(total, 1))
                    self.completedCount = index

                    if index < self.queueItems.count {
                        self.queueItems[index].status = .downloading
                    }
                },
                onTrackProgress: { [weak self] fraction in
                    guard let self, self.activeBatchID == batchID, self.totalCount > 0 else { return }
                    self.currentTrackProgress = fraction
                    // Combined: completed tracks plus the running fraction of
                    // the in-flight track, normalized by total batch size.
                    self.progress = (Double(self.completedCount) + fraction) / Double(self.totalCount)
                    job.update(completed: offset + self.completedCount, total: grandTotal,
                               currentItem: self.currentTrack, currentFraction: fraction)
                }
            )
        control.setRunning(false)
        // A track that failed only because the drive went away is not a failure (UC-JOB-10):
        // it stays Not downloaded and the operation waits for the drive to download it.
        let (driveFree, reasonWaits) = Self.separatingDriveWaits(rawResult)
        let driveWaiting = reasonWaits.union(rawResult.driveWaitingTrackIds)
        var cleaned = driveFree
        cleaned.failedTrackIds.subtract(driveWaiting)
        cleaned.driveWaitingTrackIds = []
        let result = terminalResult(cleaned, requests: requests.filter { !driveWaiting.contains($0.trackId) })

        // Persist the four download columns together for each succeeded
        // track: organized_path + format + bitrate + download_status.
        // Updating only organized_path leaves the Library showing stale
        // "0 kbps soundcloud" rows, which is one of the documented
        // invariants for this pipeline.
        let persistenceFailures = await persistDownloadedTracks(
            remoteTracks: tracks,
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
                .union(driveWaiting)
        )

        let finalResult = resultAfterPersistence(
            result,
            persistenceFailures: persistenceFailures
        )
        applyTerminalStates(
            result: result,
            persistenceFailures: persistenceFailures
        )
        finishBatch(finalResult, batchID: batchID)
        return (finalResult, driveWaiting)
    }

    /// The tracks re-read from the database that still have no file (B1). Without a repository
    /// (tests) the given tracks.
    private func stillRemote(_ tracks: [Track]) async -> [Track] {
        var current: [Track] = []
        for track in tracks {
            guard let id = track.id else { current.append(track); continue }
            if let fetch = trackFetchOverride {
                if let fresh = await fetch(id), fresh.isRemote { current.append(fresh) }
            } else if let trackRepository {
                if let fresh = try? await trackRepository.fetchTrack(id: id), fresh.isRemote { current.append(fresh) }
            } else {
                current.append(track)
            }
        }
        return current
    }

    static func merged(_ a: DownloadOrchestrator.BatchResult, _ b: DownloadOrchestrator.BatchResult) -> DownloadOrchestrator.BatchResult {
        var m = a
        m.succeeded += b.succeeded
        m.failed += b.failed
        m.skipped += b.skipped
        m.downloadedPaths.merge(b.downloadedPaths) { $1 }
        m.failedTrackIds.formUnion(b.failedTrackIds)
        m.failureReasons.merge(b.failureReasons) { $1 }
        m.skippedTrackIds.formUnion(b.skippedTrackIds)
        m.cancelledTrackIds.formUnion(b.cancelledTrackIds)
        m.downloadedMetadata.merge(b.downloadedMetadata) { $1 }
        return m
    }

    // MARK: - Activity (W3-ACT)

    /// `Download 3 tracks` / `Download “‹title›”`.
    static func batchTitle(count: Int) -> String {
        "Download \(ActivityNoun.track.counted(count))"
    }

    /// Cancel After This Track (the running scdl/yt-dlp finishes) — this batch only; Retry of
    /// its failed tracks with the batch's own source policy (B2).
    private func batchControls(_ control: DownloadBatchControl, pin: DownloadOrchestrator.PreferredSource) -> ActivityControls {
        ActivityControls(
            cancelStyle: .afterThisTrack,
            cancel: { [weak self] in
                control.cancel()
                if control.isRunning { self?.orchestrator?.cancel() }
            },
            retry: { [weak self] ids in Task { await self?.retryAllFailed(trackIds: ids, preferredSource: pin) } }
        )
    }

    /// Splits the failures caused by an unreachable library folder (`“Lexxar” not connected`)
    /// off a batch result: they are waits, not failures (UC-JOB-10).
    static func separatingDriveWaits(_ result: DownloadOrchestrator.BatchResult) -> (DownloadOrchestrator.BatchResult, Set<Int64>) {
        var waiting: Set<Int64> = []
        for id in result.failedTrackIds {
            // Only a named drive that is away waits; an unwritable folder on a present disk fails.
            if case .libraryFolderUnavailable(let volume?) = DownloadFailureReasonText.classify(result.failureReasons[id] ?? "").0,
               !volume.isEmpty {
                waiting.insert(id)
            }
        }
        guard !waiting.isEmpty else { return (result, []) }
        var cleaned = result
        cleaned.failedTrackIds.subtract(waiting)
        cleaned.failed = max(0, cleaned.failed - waiting.count)
        for id in waiting { cleaned.failureReasons[id] = nil }
        return (cleaned, waiting)
    }

    /// The batch's result in Activity: `35 downloaded · 9 failed · 2 skipped`, failures grouped
    /// by their plain cause (`DownloadFailureReasonText`, IMP-029) with the batch's source pin,
    /// and every track's outcome.
    static func activityResult(_ result: DownloadOrchestrator.BatchResult, tracks: [Track],
                               wasCancelled: Bool, pin: DownloadOrchestrator.PreferredSource = .auto) -> ActivityResult {
        let byID = Dictionary(tracks.compactMap { track in track.id.map { ($0, track) } }, uniquingKeysWith: { a, _ in a })
        let failures = result.failedTrackIds.sorted().map { id -> ActivityFailureGrouping.DownloadFailure in
            .init(trackID: id, reason: result.failureReasons[id] ?? "",
                  sourceHint: byID[id].flatMap(DownloadFailureReasonText.sourceHint(for:)))
        }
        let items = tracks.compactMap { track -> ActivityItemOutcome? in
            guard let id = track.id else { return nil }
            let title = "\(track.artist) — \(track.title)"
            if result.downloadedPaths[id] != nil {
                return ActivityItemOutcome(word: "Downloaded", title: title, trackID: id,
                                           reason: result.downloadedMetadata[id].map { $0.format.uppercased() })
            }
            if result.failedTrackIds.contains(id) {
                return ActivityItemOutcome(word: "Download failed", title: title, trackID: id,
                                           reason: DownloadFailureReasonText.plain(result.failureReasons[id] ?? "",
                                                                                   sourceHint: DownloadFailureReasonText.sourceHint(for: track)),
                                           isFailure: true)
            }
            if result.skippedTrackIds.contains(id) {
                return ActivityItemOutcome(word: "Skipped — already downloaded", title: title, trackID: id)
            }
            return ActivityItemOutcome(word: wasCancelled || result.cancelledTrackIds.contains(id) ? "Not downloaded" : "Queued",
                                       title: title, trackID: id)
        }
        var groups = ActivityFailureGrouping.groupDownloads(failures)
        for index in groups.indices { groups[index].sourcePin = pin.storageKey }
        return ActivityResult(
            counts: [ActivityCount(.done, result.succeeded, "downloaded"),
                     ActivityCount(.failed, result.failed, "failed"),
                     ActivityCount(.skipped, result.skipped, "skipped")],
            failureGroups: groups,
            items: items
        )
    }

    /// While the library folder's drive is not connected the operation waits with
    /// `Waiting for “‹volume›”` — re-checked every `driveRecheckInterval` and at once when the
    /// drive is mounted (`.libraryDriveDidMount`); `false` when the user cancelled meanwhile. A
    /// folder on the Mac's own disk never waits.
    private func waitForLibraryFolder(job: ActivityOperationHandle, control: DownloadBatchControl) async -> Bool {
        guard !libraryRoot.isEmpty, let volume = MountObserver.extractVolumePath(from: libraryRoot) else { return true }
        let name = URL(fileURLWithPath: volume).lastPathComponent
        var waited = false
        while !isVolumeMounted(volume) {
            if control.isCancelled { return false }
            if !waited {
                job.setWaiting(.drive(volumeName: name))
                AppLogger.shared.info("Downloads wait for “\(name)” to be connected", source: "Download")
                waited = true
            }
            await DriveMountWait.next(timeout: driveRecheckInterval)
        }
        if waited { job.setWaiting(nil) }
        return !control.isCancelled
    }

    /// Retry failed downloads from the queue.
    func retryFailed() async {
        guard let retryRunner = activeRetryRunner else { return }
        guard !retryRunner.pendingRetryRequests().isEmpty else { return }
        let control = DownloadBatchControl()
        let job = activity.begin(.download, title: "Retry failed downloads", itemNoun: .track,
                                 controls: ActivityControls(cancelStyle: .afterThisTrack, cancel: { [weak self] in
                                     control.cancel()
                                     if control.isRunning { self?.orchestrator?.cancel() }
                                 }),
                                 lane: .downloads)
        guard await job.waitForTurn() else { return }
        ledger.markRunning(job.id)
        let requests = retryRunner.pendingRetryRequests()
        guard !requests.isEmpty else { job.discard(); return }
        guard !control.isCancelled else { job.cancelled(); return }
        let batchID = UUID()
        activeBatchID = batchID
        isDownloading = true

        await PerformanceQueueService.shared.setExternalDownloadActive(true)
        defer {
            Task {
                await PerformanceQueueService.shared.setExternalDownloadActive(false)
            }
        }

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
        orchestrator?.clearCancelRequest()
        control.setRunning(true)
        defer { control.setRunning(false) }

        let result = terminalResult(
            await retryRunner.retryFailed(
                onProgress: { [weak self] index, total, current in
                    guard let self, self.activeBatchID == batchID else { return }
                    self.currentTrack = current
                    self.currentTrackProgress = 0
                    self.progress = Double(index) / Double(max(total, 1))
                    self.completedCount = index
                    if index < self.queueItems.count {
                        self.queueItems[index].status = .downloading
                    }
                },
                onTrackProgress: { [weak self] fraction in
                    guard let self, self.activeBatchID == batchID, self.totalCount > 0 else { return }
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
        finishBatch(finalResult, batchID: batchID)
        job.finish(ActivityResult(
            counts: [ActivityCount(.done, finalResult.succeeded, "downloaded"),
                     ActivityCount(.failed, finalResult.failed, "failed")],
            failureGroups: ActivityFailureGrouping.groupDownloads(finalResult.failedTrackIds.sorted().map {
                .init(trackID: $0, reason: finalResult.failureReasons[$0] ?? "")
            })))
        activity.scheduleFailingRefresh()
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

    private func finishBatch(_ result: DownloadOrchestrator.BatchResult, batchID: UUID) {
        guard activeBatchID == batchID else { return }
        activeBatchID = nil
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
    ///
    /// Cancels **the running batch's own operation** (never a queued one, never a later batch:
    /// with nothing running it does nothing — the orchestrator's flag is no longer left set, S1).
    func cancel() {
        guard let running = ledger.runningOperation else { return }
        activity.perform { $0.cancel(running) }
        AppLogger.shared.log(
            "Download cancel requested",
            level: .info,
            source: "Download"
        )
    }

    /// Cancels the operation that holds `trackID` (queued or running) — a Cancel next to one
    /// track (`Downloading “‹title›” — it will play when it’s ready · Cancel`) stops only its own
    /// batch (S1).
    func cancelDownload(containing trackID: Int64) {
        guard let operation = ledger.operation(containing: trackID) else { return }
        activity.perform { $0.cancel(operation) }
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

    /// Retry every persisted Activity failure in a single batch — with the source policy of the
    /// batch that failed (B2): `auto` (SoundCloud → DAB → Squid → YouTube) unless that batch was
    /// pinned. Fetches each track and hands them to the normal download path.
    func retryAllFailed(trackIds: [Int64], preferredSource: DownloadOrchestrator.PreferredSource = .auto) async {
        guard trackRepository != nil || trackFetchOverride != nil else {
            AppLogger.shared.error(
                "Cannot retry downloads because the track repository is unavailable",
                source: "Download"
            )
            return
        }

        var tracks: [Track] = []
        for trackId in trackIds {
            let track: Track?
            if let fetch = trackFetchOverride { track = await fetch(trackId) }
            else { track = try? await trackRepository?.fetchTrack(id: trackId) }
            if let track, track.isRemote { tracks.append(track) }
        }
        guard !tracks.isEmpty else { return }
        await downloadTracks(tracks, preferredSource: preferredSource,
                             context: DownloadActivityContext(title: "Retry \(ActivityNoun.track.counted(tracks.count))"))
    }

    /// Download a recommended swarm track, extract its metadata, insert it in the DB, and register in track_discovery_log as 'new'.
    func downloadDiscoveryTrack(
        artist: String,
        title: String,
        soundcloudURL: String?,
        source: String,
        seedTrack: Track,
        hold: Bool = true
    ) {
        let key = soundcloudURL ?? "\(artist) - \(title)"

        // Don't duplicate downloads
        if discoveryStatuses[key] == .queued || discoveryStatuses[key] == .downloading {
            return
        }
        guard orchestrator != nil, trackRepository != nil, !libraryRoot.isEmpty else {
            discoveryStatuses[key] = .failed
            discoveryFailureMessages[key] = "Downloads are unavailable until a library is configured."
            AppLogger.shared.error(
                "Rejected discovery download before download dependencies were configured",
                source: "Download"
            )
            return
        }

        let request = DiscoveryDownloadRequest(
            artist: artist,
            title: title,
            soundcloudURL: soundcloudURL,
            source: source,
            seedTrack: seedTrack,
            hold: hold
        )

        discoveryStatuses[key] = .queued
        discoveryFailureMessages.removeValue(forKey: key)
        discoveryQueue.append(request)

        // Claim ownership before spawning so multiple enqueues in the same
        // turn cannot schedule competing queue workers.
        guard !isProcessingDiscoveryQueue else { return }
        isProcessingDiscoveryQueue = true
        Task { await processDiscoveryQueue() }
    }

    private func processDiscoveryQueue() async {
        guard let orchestrator, let trackRepository else {
            isProcessingDiscoveryQueue = false
            return
        }

        defer { isProcessingDiscoveryQueue = false }

        while !discoveryQueue.isEmpty {
            let request = discoveryQueue.removeFirst()
            let key = request.soundcloudURL ?? "\(request.artist) - \(request.title)"
            // Activity (W3-ACT): one operation per recommendation, queued behind running batches.
            // No Cancel: the single download can't be stopped half-way.
            let job = activity.begin(.recommendationDownload,
                                     title: "Download recommendation “\(request.title)”",
                                     subject: .discover, progress: ActivityProgress(total: 1),
                                     itemNoun: .track, lane: .downloads)
            guard await job.waitForTurn() else {
                await MainActor.run { self.discoveryStatuses[key] = .failed }
                continue
            }
            var outcome: (word: String, reason: String?) = ("Download failed", "Reason unknown")
            await PerformanceQueueService.shared.setExternalDownloadActive(true)
            defer {
                // N1: reset only this item's state, before the lane lets the next batch start.
                Task { await PerformanceQueueService.shared.setExternalDownloadActive(false) }
                isDownloading = false
                currentTrack = ""
                progress = 1.0
                if outcome.word == "Downloaded" {
                    job.finish(ActivityResult(counts: [ActivityCount(.done, 1, "downloaded")],
                                              items: [ActivityItemOutcome(word: "Downloaded", title: "\(request.artist) — \(request.title)")]))
                } else {
                    job.fail(cause: outcome.reason ?? "Reason unknown")
                }
            }
            
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
                    outcome.reason = "No match found on any source"
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
                    // No album unless the file has one: the folder's name is not an album (DEC-013).
                    album: metadata?.album ?? "",
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
                
                // Save the track, its held flag and its log row in one transaction (IMP-053): a held
                // recommendation is never listed in All Tracks, not even for an instant. (Fixes the
                // window between the insert and the log row of the old two-step write.)
                let insertedTrack = try await RecommendationRepository(database: trackRepository.writer)
                    .insert(newTrack, hold: request.hold, seedTrackID: request.seedTrack.id, source: request.source)
                guard insertedTrack.id != nil else {
                    await MainActor.run {
                        self.discoveryStatuses[key] = .failed
                    }
                    continue
                }
                
                // Enqueue discovery track for auto-analysis
                await PerformanceQueueService.shared.enqueueAnalysis(track: insertedTrack)
                
                outcome = ("Downloaded", nil)
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
                outcome.reason = DownloadFailureReasonText.plain(
                    DownloadOrchestrator.DownloadFailureReason.failureReason(for: error).userFacingText)
                await MainActor.run {
                    self.discoveryStatuses[key] = .failed
                }
            }
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

// MARK: - Activity context

/// What a download batch is for, so Activity names it (`Import “Dekmantel 2024”`) and links its
/// subject. Callers without one get `Download ‹n› tracks` with the tracks as subject.
struct DownloadActivityContext: Sendable {
    var kind: ActivityKind = .download
    var title: String
    var subject: ActivitySubject?
    var messageName: String = "Download"

    init(kind: ActivityKind = .download, title: String, subject: ActivitySubject? = nil, messageName: String = "Download") {
        self.kind = kind
        self.title = title
        self.subject = subject
        self.messageName = messageName
    }

    /// `Import “‹playlist›”` — a playlist's tracks.
    static func playlist(_ id: Int64, name: String) -> DownloadActivityContext {
        DownloadActivityContext(title: "Import “\(name)”", subject: .playlist(id, name: name), messageName: "Import")
    }
}

/// Cancel state of one batch: before the run (queued, waiting for the drive) only this flag;
/// during the run also the orchestrator's stop-after-this-track.
final class DownloadBatchControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var running = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func setRunning(_ value: Bool) { lock.lock(); running = value; lock.unlock() }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
}

/// The `downloads` lane's track ids → their operation, and the running operation (B1, S1).
final class DownloadLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [Int64: UUID] = [:]
    private var running: UUID?

    /// Claims the ids nobody holds; `anyRunning` = some of the others belong to the running batch.
    func claim(_ ids: [Int64], for operation: UUID) -> (fresh: [Int64], anyRunning: Bool) {
        lock.lock(); defer { lock.unlock() }
        var fresh: [Int64] = []
        var anyRunning = false
        for id in ids {
            if let owner = owners[id] {
                if owner == running { anyRunning = true }
            } else if !fresh.contains(id) {
                owners[id] = operation
                fresh.append(id)
            }
        }
        return (fresh, anyRunning)
    }

    func release(_ ids: Set<Int64>, for operation: UUID) {
        lock.lock(); defer { lock.unlock() }
        for id in ids where owners[id] == operation { owners[id] = nil }
        if running == operation { running = nil }
    }

    func markRunning(_ operation: UUID) {
        lock.lock(); running = operation; lock.unlock()
    }

    var runningOperation: UUID? { lock.lock(); defer { lock.unlock() }; return running }

    func operation(containing trackID: Int64) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return owners[trackID]
    }
}

/// The caller's handle on the batch it asked for: `cancel()` cancels exactly that operation —
/// also before it was registered or while it is queued (S1).
final class DownloadTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var id: UUID?
    private var cancelled = false
    private weak var center: ActivityCenter?

    init() {}

    var operationID: UUID? { lock.lock(); defer { lock.unlock() }; return id }

    func attach(_ operation: UUID, center: ActivityCenter) {
        lock.lock()
        id = operation
        self.center = center
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { center.perform { $0.cancel(operation) } }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let operation = id
        let center = self.center
        lock.unlock()
        if let operation, let center { center.perform { $0.cancel(operation) } }
    }
}

/// Waits for the next `.libraryDriveDidMount` or `timeout`, whichever comes first (N3).
enum DriveMountWait {
    static func next(timeout: TimeInterval) async {
        let once = OnceFlag()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var token: NSObjectProtocol?
            let finish = {
                guard once.claim() else { return }
                if let token { NotificationCenter.default.removeObserver(token) }
                continuation.resume()
            }
            token = NotificationCenter.default.addObserver(forName: .libraryDriveDidMount, object: nil, queue: nil) { _ in finish() }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(timeout, 0)) { finish() }
        }
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
}
