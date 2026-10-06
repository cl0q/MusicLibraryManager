import Foundation

/// Central download coordinator implementing the DAB → SoundCloud → YouTube
/// fallback chain.
///
/// Mirrors the Rust `DownloadOrchestrator`. Downloads source audio (FLAC/AAC),
/// then transcodes to 248kbps AAC for the library.
@Observable
final class DownloadOrchestrator {

    // MARK: - Types

    /// Which source the download should be pinned to.
    ///
    /// - `.auto`: run the full fallback chain (SoundCloud → DAB → Squid → YouTube).
    /// - `.soundcloud`: only attempt scdl with `soundcloudURL`; no cross-source fallback.
    /// - `.youtube`: download `youtubeURL` directly via yt-dlp; skip SC/DAB/Squid.
    enum PreferredSource: Equatable {
        case auto
        case soundcloud
        case youtube

        /// Stable wire key persisted to `.retry_queue.json`. Pinned so a
        /// future rename of these cases cannot silently break decoding of
        /// old queues — see SCDL-01.
        var storageKey: String {
            switch self {
            case .auto: return "auto"
            case .soundcloud: return "soundcloud"
            case .youtube: return "youtube"
            }
        }

        /// Rebuilds a `PreferredSource` from its persisted storage key.
        /// Fails safe to `.auto` for `nil` or any unrecognized string —
        /// never crashes, never silently escalates an unknown key to a
        /// stronger pin than the caller can prove.
        init(storageKey: String?) {
            switch storageKey {
            case "soundcloud": self = .soundcloud
            case "youtube": self = .youtube
            default: self = .auto
            }
        }
    }

    /// Which concrete provider actually produced a successful download.
    /// Tagged on the `downloadWithFallback` result so `finalize` can route
    /// the file to the correct final directory (SCDL-09) regardless of
    /// whether the request was pinned or ran the auto chain.
    enum DownloadSource {
        case soundcloud
        case youtube
        case dab
        case squid
    }

    /// The bounded, user-facing explanation for a terminal download failure.
    /// Keep raw provider/process messages in the Logs tab; persisted records
    /// and Activity use only the binding plain-language copy.
    enum DownloadFailureReason: Equatable, Sendable {
        case videoUnavailable
        case videoUnavailableInRegion
        case privateVideo
        case ytDlpUnavailable
        case network
        case sourcesExhausted

        var userFacingText: String {
            switch self {
            case .videoUnavailable, .sourcesExhausted:
                return "Video unavailable"
            case .videoUnavailableInRegion:
                return "Video unavailable in your region"
            case .privateVideo:
                return "Private video"
            case .ytDlpUnavailable:
                return "yt-dlp not installed — open Settings"
            case .network:
                return "Network error"
            }
        }

        /// Classifies existing provider and transport errors without exposing
        /// implementation details, status codes, or raw command output in UI.
        static func failureReason(for error: Error?) -> DownloadFailureReason {
            guard let error else { return .sourcesExhausted }

            if let urlError = error as? URLError, isNetworkError(urlError) {
                return .network
            }

            let message = error.localizedDescription.lowercased()
            if message.contains("private video") {
                return .privateVideo
            }
            if message.contains("not available in your region") ||
                message.contains("not available in your country") ||
                message.contains("geographic restriction") {
                return .videoUnavailableInRegion
            }
            if message.contains("yt-dlp") &&
                (message.contains("not installed") ||
                 message.contains("not found") ||
                 message.contains("no such file")) {
                return .ytDlpUnavailable
            }
            if message.contains("network") ||
                message.contains("timed out") ||
                message.contains("connection") ||
                message.contains("dns") ||
                message.contains("offline") ||
                message.contains("cannot connect") {
                return .network
            }
            if message.contains("video unavailable") ||
                message.contains("video is unavailable") ||
                message.contains("no video results") ||
                message.contains("private") ||
                message.contains("not available") ||
                message.contains("not found") ||
                message.contains("404") {
                return .videoUnavailable
            }

            // An unrecognized provider error has no truthful technical copy
            // in the UI vocabulary. It is presented as an unavailable result
            // while its original detail remains available in Logs.
            return .sourcesExhausted
        }

        private static func isNetworkError(_ error: URLError) -> Bool {
            switch error.code {
            case .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .notConnectedToInternet,
                 .timedOut:
                return true
            default:
                return false
            }
        }
    }

    /// A request to download a single track.
    struct DownloadRequest {
        let trackId: Int64
        let artist: String
        let title: String
        let query: String
        let soundcloudURL: String?
        let userId: String?
        /// Pin the download to a specific source. Defaults to `.auto`.
        var preferredSource: PreferredSource = .auto
        /// Direct YouTube video URL, used when `preferredSource == .youtube`.
        var youtubeURL: String? = nil
        /// Artwork/thumbnail URL to embed into the downloaded file after finalize.
        var artworkURL: String? = nil
        /// Attempts already recorded by a legacy retry-queue item before this
        /// request starts. Fresh requests use zero and derive their count from
        /// the database record instead.
        var previousAttemptCount: Int = 0
    }

    /// Aggregate result of a batch download.
    struct BatchResult {
        var succeeded: Int = 0
        var failed: Int = 0
        var skipped: Int = 0
        var downloadedPaths: [Int64: String] = [:]
        var failedTrackIds: Set<Int64> = []
        /// User-facing terminal reason for each failed track. This is the
        /// handoff from provider-level outcomes to durable DB persistence.
        var failureReasons: [Int64: String] = [:]
        var skippedTrackIds: Set<Int64> = []
        var cancelledTrackIds: Set<Int64> = []
        /// Per-track metadata for DB updates — `format` is the container
        /// extension without the dot (e.g. `"m4a"`, `"flac"`) and `bitrate`
        /// is in kbps.
        var downloadedMetadata: [Int64: DownloadedFileInfo] = [:]
        /// Tracks not tried (or interrupted) because the library drive went away — waits, not
        /// failures (UC-JOB-10): no failure is recorded, nothing is enqueued for retry (W3-ACT S3).
        var driveWaitingTrackIds: Set<Int64> = []
    }

    /// Container-format and bitrate metadata for a freshly downloaded file.
    struct DownloadedFileInfo {
        let format: String
        let bitrate: Int?
    }

    // MARK: - Provider protocols (dependency injection for tests)

    /// The slice of `SoundCloudDownloader` the chain actually calls.
    /// Tests inject a fake; production uses the real class via the
    /// extension at the bottom of this file.
    protocol SoundCloudProviding: Sendable {
        var isAvailable: Bool { get }
        func download(
            trackURL: String, outputDir: URL, trackId: Int64,
            title: String, onProgress: ((Double) -> Void)?
        ) async throws -> DownloadOutcome
    }

    /// The slice of `YouTubeDownloader` the chain actually calls.
    protocol YouTubeProviding: Sendable {
        var isAvailable: Bool { get }
        func searchAndDownload(
            query: String, outputDir: URL,
            onProgress: ((Double) -> Void)?
        ) async throws -> DownloadOutcome
        func downloadByURL(_ url: String, outputDir: URL) async throws -> DownloadOutcome
    }

    /// The slice of `DABClient` the chain actually calls.
    protocol DABProviding: Sendable {
        func searchTrack(query: String) async throws -> DabTrack?
        func matches(dabTrack: DabTrack, artist: String, title: String) -> Bool
        func download(
            dabTrack: DabTrack, outputDir: URL,
            artist: String, title: String
        ) async throws -> DABClient.DownloadResult
    }

    /// The slice of `SquidWtfClient` the chain actually calls.
    protocol SquidProviding: Sendable {
        func searchTrack(
            query: String, artist: String, title: String
        ) async throws -> SquidTrack?
        func download(
            track: SquidTrack, outputDir: URL,
            artist: String, title: String
        ) async throws -> SquidWtfClient.DownloadResult
    }

    /// Abstraction over `Task.sleep` so tests can verify retry backoff
    /// without actually waiting. Production uses `WallClock`; tests use
    /// `ImmediateClock` (no-op) or a counting clock.
    protocol DownloaderClock: Sendable {
        func sleep(_ seconds: Double) async
    }

    struct WallClock: DownloaderClock {
        func sleep(_ seconds: Double) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    /// Internal result of the fallback chain: either a downloaded file
    /// tagged with its source, or the terminal classified failure.
    /// Replaces the old `(URL, DownloadSource)?` return so the caller
    /// receives the failure instead of `nil`.
    enum FallbackResult {
        case success(URL, DownloadSource)
        case failure(DownloadFailure)
    }

    // MARK: - State

    private(set) var isRunning = false
    private(set) var currentItem: String = ""
    private(set) var progress: Double = 0

    /// Set to `true` by `cancel()` — the batch loop checks this between
    /// each request and exits cleanly without starting a new download.
    /// Reset to `false` at the start of each batch.
    private var cancelRequested = false

    // MARK: - Dependencies

    private let flacDir: URL
    private let aacDir: URL
    /// Destination for new SoundCloud downloads (kept-as-is OR transcoded —
    /// the final DB-referenced file always lives here, never in `aacDir`
    /// or `flacDir`). See SCDL-09.
    private let soundCloudDir: URL
    let transcodeService: TranscodeService
    private let soundCloudDownloader: any SoundCloudProviding
    private let youtubeDownloader: any YouTubeProviding
    private let retryQueue: DownloadQueue
    private let dabClient: (any DABProviding)?
    private let squidClient: any SquidProviding
    private let clock: any DownloaderClock

    init(
        libraryRoot: String,
        tokenStorage: TokenStorage
    ) {
        let root = URL(fileURLWithPath: libraryRoot)
        self.flacDir = root.appendingPathComponent(ManagedLibraryLayout.transcodeOriginals)
        self.aacDir = root.appendingPathComponent(ManagedLibraryLayout.youtubeDownloads)
        self.soundCloudDir = root.appendingPathComponent(ManagedLibraryLayout.soundCloudDownloads)

        self.transcodeService = TranscodeService()
        self.soundCloudDownloader = SoundCloudDownloader()
        self.youtubeDownloader = YouTubeDownloader()
        self.retryQueue = DownloadQueue(directory: flacDir)
        self.dabClient = DABClient(tokenStorage: tokenStorage)
        self.squidClient = SquidWtfClient()
        self.clock = WallClock()

        // Once-at-boot endpoint reachability logs for the optional FLAC
        // stages (DAB + Squid) so the Logs tab tells the user up front
        // which stages are live and whether the chain has degraded.
        let dabEndpoint = DABClient.baseURL
        let squidEndpoint = SquidWtfClient.baseURL
        let squidHasCookie = SquidWtfClient.cfClearance != nil
        Task.detached(priority: .background) {
            await Self.healthCheck(label: "DAB", endpoint: dabEndpoint, configKey: "MLM_DAB_API_BASE")
            await Self.healthCheck(label: "Squid", endpoint: squidEndpoint, configKey: "MLM_SQUID_API_BASE")
            if !squidHasCookie {
                AppLogger.shared.info(
                    "Squid: no MLM_SQUID_CAPTCHA set — search will run, but download needs the `captcha_verified_at` cookie. Trigger any download once at qobuz.squid.wtf, open dev-tools → Storage → Cookies → copy the value of captcha_verified_at, then export MLM_SQUID_CAPTCHA=…",
                    source: "Download"
                )
            }
        }
    }

    /// Test-only initializer — injects fake providers and a no-op clock
    /// so the chain can be exercised without network or subprocess access.
    init(
        libraryRoot: String,
        soundCloudDownloader: any SoundCloudProviding,
        youtubeDownloader: any YouTubeProviding,
        dabClient: (any DABProviding)?,
        squidClient: any SquidProviding,
        clock: any DownloaderClock
    ) {
        let root = URL(fileURLWithPath: libraryRoot)
        self.flacDir = root.appendingPathComponent(ManagedLibraryLayout.transcodeOriginals)
        self.aacDir = root.appendingPathComponent(ManagedLibraryLayout.youtubeDownloads)
        self.soundCloudDir = root.appendingPathComponent(ManagedLibraryLayout.soundCloudDownloads)
        self.transcodeService = TranscodeService()
        self.soundCloudDownloader = soundCloudDownloader
        self.youtubeDownloader = youtubeDownloader
        self.retryQueue = DownloadQueue(directory: root)
        self.dabClient = dabClient
        self.squidClient = squidClient
        self.clock = clock
    }

    private static func healthCheck(label: String, endpoint: String, configKey: String) async {
        if endpoint.isEmpty {
            AppLogger.shared.info(
                "\(label) endpoint disabled (\(configKey) = \"\")",
                source: "Download"
            )
            return
        }
        guard let url = URL(string: endpoint) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 8
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            AppLogger.shared.info(
                "\(label) endpoint reachable: \(endpoint) (HTTP \(code))",
                source: "Download"
            )
        } catch {
            AppLogger.shared.warn(
                "\(label) endpoint NOT reachable: \(endpoint) — \(error.localizedDescription). Pipeline will skip this stage. Set \(configKey) to override.",
                source: "Download"
            )
        }
    }

    // MARK: - Download Batch

    /// Request that the in-flight batch stop after the current track.
    ///
    /// The flag is checked between requests — the currently running
    /// scdl/yt-dlp/ffmpeg invocation is allowed to finish so the database
    /// and on-disk state stay consistent. Safe to call from any thread.
    func cancel() {
        cancelRequested = true
    }

    /// Removes leftovers in MLM's own hidden staging folders (`.mlm-download-tmp`,
    /// `.mlm-transcode-tmp`) older than an hour — e.g. a track interrupted when the drive went
    /// away — so no partial file stays in the library folder (W3-ACT S3). Batches run one at a
    /// time, so nothing that old is in use.
    private func removeStaleStaging(now: Date = Date()) {
        let fm = FileManager.default
        let root = aacDir.deletingLastPathComponent()
        for folder in [".mlm-download-tmp", ".mlm-transcode-tmp"] {
            let dir = root.appendingPathComponent(folder)
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for entry in entries {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                if now.timeIntervalSince(modified) > 3600 { try? fm.removeItem(at: entry) }
            }
        }
    }

    /// Clears a stop request left from an earlier batch, right before a new batch starts — a
    /// cancel belongs to one batch only (W3-ACT S1).
    func clearCancelRequest() {
        cancelRequested = false
    }

    /// A track that has a file by the time its turn comes is skipped (W3-ACT B1). Set by
    /// `DownloadViewModel.configure`.
    var isAlreadyLocal: (@Sendable (Int64) async -> Bool)?

    /// Whether `/Volumes/<name>` is mounted — the reconciler's check (`MountObserver`); tests
    /// fake it.
    var isVolumeMounted: @Sendable (String) -> Bool = { MountObserver.isVolumeMounted($0) }

    /// The library drive is away (the folder is under `/Volumes/<name>` and that volume isn't
    /// mounted). A folder on the Mac's own disk is never away.
    private var isLibraryDriveAway: Bool {
        guard let volume = MountObserver.extractVolumePath(from: aacDir.deletingLastPathComponent().path) else { return false }
        return !isVolumeMounted(volume)
    }

    /// Download a batch of tracks following the fallback chain.
    ///
    /// Processing is sequential (not parallel) to simplify rate limiting.
    /// Chain: SoundCloud (if URL) → DAB → Squid → YouTube
    func downloadBatch(
        _ requests: [DownloadRequest],
        onProgress: ((Int, Int, String) -> Void)? = nil,
        onTrackProgress: ((Double) -> Void)? = nil
    ) async -> BatchResult {
        guard !isRunning else {
            var rejected = BatchResult()
            rejected.failed = requests.count
            rejected.failedTrackIds = Set(requests.map(\.trackId))
            for request in requests {
                rejected.failureReasons[request.trackId] = "Another download batch is already running."
            }
            AppLogger.shared.warn(
                "Rejected concurrent download batch with \(requests.count) request(s)",
                source: "Download"
            )
            return rejected
        }
        isRunning = true
        // cancelRequested is NOT reset here — if cancel() was called
        // before downloadBatch, the flag must survive into the loop so
        // the first iteration sees it. Reset in defer instead.
        defer {
            isRunning = false
            cancelRequested = false
        }

        var result = BatchResult()
        let total = requests.count

        guard !requests.isEmpty else {
            progress = 1.0
            return result
        }

        // The drive is away before anything starts: every track waits for it (W3-ACT S3).
        if isLibraryDriveAway {
            result.driveWaitingTrackIds = Set(requests.map(\.trackId))
            AppLogger.shared.info("Library drive not connected — \(total) download(s) wait for it", source: "Download")
            return result
        }
        removeStaleStaging()

        // The staging directory is intentionally hidden and is not part of
        // the managed layout. Source folders are created only in finalization.
        do {
            try FileManager.default.createDirectory(
                at: aacDir.deletingLastPathComponent().appendingPathComponent(".mlm-download-tmp"),
                withIntermediateDirectories: true
            )
        } catch {
            // The library folder can't be written — mostly its disk is away. Say so instead of
            // the catch-all `Video unavailable` (W2-B, UC-JOB-10/11).
            let reason = Self.stagingFailureReason(libraryRoot: aacDir.deletingLastPathComponent())
            AppLogger.shared.error(
                "Download staging directory is not writable (\(error.localizedDescription)). Library drive offline? root=\(aacDir.deletingLastPathComponent().path)",
                source: "Download"
            )
            result.failed = total
            result.failedTrackIds = Set(requests.map(\.trackId))
            for req in requests {
                result.failureReasons[req.trackId] = reason
                enqueueRetry(req, error: reason)
            }
            return result
        }

        trackLoop: for (index, request) in requests.enumerated() {
            if cancelRequested {
                result.cancelledTrackIds.formUnion(
                    requests[index...].map(\.trackId)
                )
                AppLogger.shared.log(
                    "Download batch cancelled at \(index)/\(total)",
                    level: .info,
                    source: "Download"
                )
                break
            }

            // The drive went away: this track and the rest wait for it (S3).
            if isLibraryDriveAway {
                result.driveWaitingTrackIds.formUnion(requests[index...].map(\.trackId))
                AppLogger.shared.info("Library drive went away — \(total - index) download(s) wait for it", source: "Download")
                break
            }

            currentItem = "\(request.artist) - \(request.title)"
            progress = Double(index) / Double(max(total, 1))
            onProgress?(index, total, currentItem)
            onTrackProgress?(0)

            // Already downloaded meanwhile (another path): don't download it again (B1).
            if let isAlreadyLocal, await isAlreadyLocal(request.trackId) {
                result.skipped += 1
                result.skippedTrackIds.insert(request.trackId)
                continue
            }

            do {
                let stagingDir = aacDir
                    .deletingLastPathComponent()
                    .appendingPathComponent(".mlm-download-tmp")
                    .appendingPathComponent("\(request.trackId)-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: stagingDir) }

                let fallbackResult = try await downloadWithFallback(
                    request,
                    stagingDir: stagingDir,
                    onTrackProgress: onTrackProgress
                )
                // Cancellation may have been set during the chain
                // (between sources inside downloadWithFallback). Route
                // the track to cancelledTrackIds, not failedTrackIds —
                // a user-cancelled track is not a failure and must not
                // be enqueued to the retry queue.
                if cancelRequested {
                    result.cancelledTrackIds.insert(request.trackId)
                    AppLogger.shared.log(
                        "Download cancelled mid-chain for track \(request.trackId)",
                        level: .info,
                        source: "Download"
                    )
                    continue
                }
                switch fallbackResult {
                case .success(let path, let source):
                    let finalized = try await finalize(sourcePath: path, source: source, request: request)
                    result.downloadedPaths[request.trackId] = finalized.path.path
                    result.downloadedMetadata[request.trackId] = DownloadedFileInfo(
                        format: finalized.format,
                        bitrate: finalized.bitrate
                    )
                    result.succeeded += 1
                case .failure(let failure):
                    if isLibraryDriveAway {
                        // Not this track's fault: it and the rest wait for the drive (S3).
                        result.driveWaitingTrackIds.formUnion(requests[index...].map(\.trackId))
                        break trackLoop
                    }
                    result.failed += 1
                    result.failedTrackIds.insert(request.trackId)
                    let terminalMessage = failure.userMessage
                    result.failureReasons[request.trackId] = terminalMessage
                    AppLogger.shared.log(
                        "chain terminal failure for track \(request.trackId) (\(request.artist) - \(request.title)): \(failure.klass) [\(failure.source)] heal=\(failure.heal) — \(terminalMessage)",
                        level: .warning,
                        source: "Download"
                    )
                    enqueueRetry(request, error: terminalMessage)
                }
            } catch {
                if cancelRequested {
                    result.cancelledTrackIds.insert(request.trackId)
                    AppLogger.shared.log(
                        "Download cancelled during track \(request.trackId) (error: \(error.localizedDescription))",
                        level: .info,
                        source: "Download"
                    )
                    continue
                }
                if isLibraryDriveAway {
                    // The drive went away mid-track: no failure is recorded; it and the rest
                    // wait (S3). Its staging/transcode folders are cleaned when a later batch starts.
                    result.driveWaitingTrackIds.formUnion(requests[index...].map(\.trackId))
                    AppLogger.shared.info("Library drive went away during track \(request.trackId) — waiting", source: "Download")
                    break trackLoop
                }
                result.failed += 1
                result.failedTrackIds.insert(request.trackId)
                let failureReason = DownloadFailureReason.failureReason(for: error)
                result.failureReasons[request.trackId] = failureReason.userFacingText
                AppLogger.shared.error(
                    "Download failed for track \(request.trackId) (\(request.artist) - \(request.title)): \(error.localizedDescription) [type=\(String(describing: type(of: error)))]",
                    source: "Download"
                )
                enqueueRetry(request, error: failureReason.userFacingText)
            }
        }

        progress = 1.0
        currentItem = ""
        return result
    }

    /// Retry previously failed downloads.
    func pendingRetryRequests() -> [DownloadRequest] {
        retryQueue.retryableItems().map { item in
            let parsedIdentity = Self.parseIdentity(from: item.query)
            return DownloadRequest(
                trackId: item.trackId,
                artist: item.artist ?? parsedIdentity.artist,
                title: item.title ?? parsedIdentity.title,
                query: item.query,
                soundcloudURL: item.soundcloudURL,
                userId: nil,
                preferredSource: PreferredSource(storageKey: item.preferredSource),
                youtubeURL: item.youtubeURL,
                previousAttemptCount: item.attemptCount
            )
        }
    }

    func persistedRetryItems() -> [DownloadQueue.QueueItem] {
        retryQueue.items
    }

    /// The stored reason when the library folder can't take the download: `“Lexxar” not
    /// connected` while its disk (`/Volumes/<name>`) is not mounted, else `Library folder not
    /// reachable`. `DownloadFailureReasonText` shows both as they are.
    static func stagingFailureReason(
        libraryRoot: URL,
        isMounted: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        if let volumePath = MountObserver.extractVolumePath(from: libraryRoot.path), !isMounted(volumePath) {
            return "“\(URL(fileURLWithPath: volumePath).lastPathComponent)” not connected"
        }
        return "Library folder not reachable"
    }

    /// Distinguish a missing yt-dlp binary from an ordinary exhausted search
    /// before the nil provider result is flattened into a terminal failure.
    static func failureReasonForExhaustedSources(
        preferredSource: PreferredSource,
        youtubeAvailable: Bool
    ) -> DownloadFailureReason {
        if preferredSource != .soundcloud && !youtubeAvailable {
            return .ytDlpUnavailable
        }
        return .sourcesExhausted
    }

    func retryFailed(
        onProgress: ((Int, Int, String) -> Void)? = nil,
        onTrackProgress: ((Double) -> Void)? = nil
    ) async -> BatchResult {
        await downloadBatch(
            pendingRetryRequests(),
            onProgress: onProgress,
            onTrackProgress: onTrackProgress
        )
    }

    func dequeuePersistedRetries(trackIds: Set<Int64>) {
        do {
            try retryQueue.dequeue(trackIds: trackIds)
        } catch {
            AppLogger.shared.error(
                "Failed to persist retry-queue dequeue; queue state was restored: \(error.localizedDescription)",
                source: "Download"
            )
        }
    }

    func enqueuePersistenceFailures(
        requests: [DownloadRequest],
        trackIds: Set<Int64>
    ) {
        for request in requests where trackIds.contains(request.trackId) {
            enqueueRetry(request, error: "Downloaded file could not be saved to library")
        }
    }

    private func enqueueRetry(_ request: DownloadRequest, error: String) {
        do {
            try retryQueue.enqueue(
                trackId: request.trackId,
                query: request.query,
                source: request.preferredSource.storageKey,
                error: error,
                artist: request.artist,
                title: request.title,
                preferredSource: request.preferredSource.storageKey,
                soundcloudURL: request.soundcloudURL,
                youtubeURL: request.youtubeURL
            )
        } catch {
            AppLogger.shared.error(
                "Failed to persist retry queue; in-memory change was rolled back: \(error.localizedDescription)",
                source: "Download"
            )
        }
    }

    static func parseIdentity(from query: String) -> (artist: String, title: String) {
        guard let separator = query.range(of: " - ") else {
            return ("", query)
        }
        return (
            String(query[..<separator.lowerBound]),
            String(query[separator.upperBound...])
        )
    }

    /// Download a single discovery track to a custom output directory.
    func downloadDiscoveryTrack(
        artist: String,
        title: String,
        soundcloudURL: String?,
        targetDir: URL,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> URL? {
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let query = "\(artist) - \(title)"
        let request = DownloadRequest(
            trackId: -999,
            artist: artist,
            title: title,
            query: query,
            soundcloudURL: soundcloudURL,
            userId: nil
        )

        // 1. SoundCloud direct
        if let scURL = request.soundcloudURL {
            if soundCloudDownloader.isAvailable {
                AppLogger.shared.log("discovery[SC]: trying \(scURL)", level: .info, source: "Download")
                let scOutcome = try await soundCloudDownloader.download(
                    trackURL: scURL, outputDir: targetDir,
                    trackId: -999, title: "\(request.artist) - \(request.title)",
                    onProgress: onProgress
                )
                if case .success(let path) = scOutcome {
                    AppLogger.shared.log("discovery[SC]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                    return path
                }
            }
        }

        // 2. DAB Music API
        if let dab = dabClient {
            do {
                AppLogger.shared.log("discovery[DAB]: searching \(request.query)", level: .info, source: "Download")
                if let dabTrack = try await dab.searchTrack(query: request.query) {
                    if dab.matches(dabTrack: dabTrack, artist: request.artist, title: request.title) {
                        let dabResult = try await dab.download(
                            dabTrack: dabTrack, outputDir: targetDir,
                            artist: request.artist, title: request.title
                        )
                        if case .success(let path) = dabResult {
                            AppLogger.shared.log("discovery[DAB]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                            return path
                        }
                    }
                }
            } catch {
                AppLogger.shared.log("discovery[DAB]: error: \(error)", level: .warning, source: "Download")
            }
        }

        // 3. Squid.wtf
        do {
            AppLogger.shared.log("discovery[Squid]: searching \(request.query)", level: .info, source: "Download")
            if let squidTrack = try await squidClient.searchTrack(
                query: request.query, artist: request.artist, title: request.title
            ) {
                let squidResult = try await squidClient.download(
                    track: squidTrack, outputDir: targetDir,
                    artist: request.artist, title: request.title
                )
                if case .success(let path) = squidResult {
                    AppLogger.shared.log("discovery[Squid]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                    return path
                }
            }
        } catch {
            AppLogger.shared.log("discovery[Squid]: error: \(error)", level: .warning, source: "Download")
        }

        // 4. YouTube
        if youtubeDownloader.isAvailable {
            AppLogger.shared.log("discovery[YT]: searching \(request.query)", level: .info, source: "Download")
            let ytOutcome = try await youtubeDownloader.searchAndDownload(
                query: request.query, outputDir: targetDir, onProgress: onProgress
            )
            if case .success(let path) = ytOutcome {
                AppLogger.shared.log("discovery[YT]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                return path
            }
        }

        return nil
    }

    // MARK: - Fallback Chain

    /// Maximum number of same-source retries before falling through.
    static let maxSameSourceRetries = 2

    /// Base delay in seconds for exponential backoff between same-source
    /// retries. Actual delay = base × 2^attempt + random jitter (0–0.5s).
    static let retryBaseDelay: Double = 1.0

    /// Try downloading via the fallback chain (or a pinned source).
    ///
    /// Returns `.success(URL, DownloadSource)` on success, or
    /// `.failure(DownloadFailure)` carrying the terminal classified failure.
    ///
    /// Chain decision table (per `DownloadFailureClass`):
    /// | Class              | Action                                        |
    /// |--------------------|-----------------------------------------------|
    /// | drmProtected       | STOP (permanent)                              |
    /// | contentRemoved     | STOP (permanent)                              |
    /// | geoBlocked         | STOP (permanent)                              |
    /// | downloadsDisabled  | STOP (permanent)                              |
    /// | mediaCorrupt       | STOP (quarantine)                             |
    /// | rateLimited        | RETRY same source (<=2x), then fall through  |
    /// | networkTimeout     | RETRY same source (<=2x), then fall through  |
    /// | networkUnreachable | RETRY same source (<=2x), then fall through  |
    /// | serverError        | RETRY same source (<=2x), then fall through  |
    /// | toolStale          | fall through (TODO: ExternalToolHealth)       |
    /// | toolMissing        | fall through                                  |
    /// | authExpired        | fall through                                  |
    /// | formatUnavailable  | fall through                                  |
    /// | outputMissing      | fall through                                  |
    /// | unknown            | fall through                                  |
    private func downloadWithFallback(
        _ request: DownloadRequest,
        stagingDir: URL,
        onTrackProgress: ((Double) -> Void)? = nil
    ) async throws -> FallbackResult {
        var trace: [DownloadFailure] = []

        // Source pinning — no cross-source fallback (existing intended behaviour).
        switch request.preferredSource {
        case .soundcloud:
            guard let scURL = request.soundcloudURL else {
                AppLogger.shared.log(
                    "pinned[SC]: no SoundCloud URL for track id=\(request.trackId)",
                    level: .warning, source: "Download"
                )
                return .failure(DownloadFailure(
                    klass: .unknown, source: "soundcloud",
                    detail: "no SoundCloud URL provided for pinned download",
                    userMessage: "No SoundCloud URL — cannot download (pinned to SoundCloud)",
                    heal: .none))
            }
            guard soundCloudDownloader.isAvailable else {
                return .failure(DownloadFailure(
                    klass: .toolMissing, source: "soundcloud",
                    detail: "scdl not found on PATH",
                    userMessage: "scdl not installed — install via `pip install scdl`",
                    heal: .installTool))
            }
            let scOutcome = try await soundCloudDownloader.download(
                trackURL: scURL, outputDir: stagingDir,
                trackId: request.trackId,
                title: "\(request.artist) - \(request.title)",
                onProgress: onTrackProgress
            )
            switch scOutcome {
            case .success(let path):
                return .success(path, .soundcloud)
            case .failure(let f):
                AppLogger.shared.log(
                    "pinned[SC]: \(f.klass) heal=\(f.heal) — \(f.userMessage) (no cross-source fallback)",
                    level: .warning, source: "Download"
                )
                return .failure(f)
            }

        case .youtube:
            guard youtubeDownloader.isAvailable else {
                return .failure(DownloadFailure(
                    klass: .toolMissing, source: "youtube",
                    detail: "yt-dlp not found on PATH",
                    userMessage: "yt-dlp not installed — open Settings",
                    heal: .installTool))
            }
            let ytOutcome: DownloadOutcome
            if let ytURL = request.youtubeURL {
                ytOutcome = try await youtubeDownloader.downloadByURL(ytURL, outputDir: stagingDir)
            } else {
                ytOutcome = try await youtubeDownloader.searchAndDownload(
                    query: request.query, outputDir: stagingDir,
                    onProgress: onTrackProgress
                )
            }
            switch ytOutcome {
            case .success(let path):
                return .success(path, .youtube)
            case .failure(let f):
                AppLogger.shared.log(
                    "pinned[YT]: \(f.klass) heal=\(f.heal) — \(f.userMessage) (no cross-source fallback)",
                    level: .warning, source: "Download"
                )
                return .failure(f)
            }

        case .auto:
            break
        }

        // -- Auto chain: SoundCloud -> DAB -> Squid -> YouTube --

        // 1. SoundCloud
        if cancelRequested {
            return .failure(DownloadFailure(
                klass: .unknown, source: "all",
                detail: "cancelled before SoundCloud stage",
                userMessage: "Download cancelled",
                heal: .none))
        }
        if let scURL = request.soundcloudURL, soundCloudDownloader.isAvailable {
            AppLogger.shared.log("chain[SC]: trying \(scURL)", level: .info, source: "Download")
            let scOutcome = try await attemptWithRetry(
                source: "soundcloud",
                operation: {
                    try await self.soundCloudDownloader.download(
                        trackURL: scURL, outputDir: stagingDir,
                        trackId: request.trackId,
                        title: "\(request.artist) - \(request.title)",
                        onProgress: onTrackProgress
                    )
                }
            )
            switch scOutcome {
            case .success(let path):
                AppLogger.shared.log("chain[SC]: success -> \(path.lastPathComponent)", level: .info, source: "Download")
                return .success(path, .soundcloud)
            case .failure(let f):
                trace.append(f)
                AppLogger.shared.log(
                    "chain[SC]: \(f.klass) heal=\(f.heal) — \(f.userMessage) — continuing to next source",
                    level: .warning, source: "Download"
                )
                // TODO(coordinator): when f.klass == .toolStale, consult
                // ExternalToolHealth here. If scdl is stale, surface the
                // update remedy in userMessage before falling through.
            }
        } else if request.soundcloudURL == nil {
            AppLogger.shared.log(
                "chain[SC]: no SoundCloud URL for track id=\(request.trackId)",
                level: .info, source: "Download"
            )
        } else {
            AppLogger.shared.log(
                "chain[SC]: scdl not installed — skipping",
                level: .warning, source: "Download"
            )
        }

        // 2. DAB
        if cancelRequested {
            return .failure(DownloadFailure(
                klass: .unknown, source: "all",
                detail: "cancelled before DAB stage",
                userMessage: "Download cancelled",
                heal: .none))
        }
        if let dab = dabClient {
            let dabResult = await attemptDAB(dab, request: request, stagingDir: stagingDir)
            switch dabResult {
            case .success(let path):
                AppLogger.shared.log("chain[DAB]: success -> \(path.lastPathComponent)", level: .info, source: "Download")
                return .success(path, .dab)
            case .classifiedFailure(let f):
                trace.append(f)
                AppLogger.shared.log(
                    "chain[DAB]: \(f.klass) heal=\(f.heal) — \(f.userMessage) — continuing to next source",
                    level: .warning, source: "Download"
                )
            case .noResults:
                AppLogger.shared.log("chain[DAB]: no matching track found", level: .info, source: "Download")
            case .captchaRequired:
                // DAB does not produce captcha, but StageResult is shared
                // with Squid which does. Handle exhaustively: classify as
                // authExpired and continue to the next source.
                let captchaFailure = DownloadFailure(
                    klass: .authExpired, source: "dab",
                    detail: "captcha/cookie required — set MLM_SQUID_CAPTCHA from browser dev-tools → Storage → Cookies for qobuz.squid.wtf",
                    userMessage: "DAB requires a captcha cookie — try another source",
                    heal: .refreshAuthThenRetry)
                trace.append(captchaFailure)
                AppLogger.shared.log(
                    "chain[DAB]: captchaRequired — \(captchaFailure.userMessage)",
                    level: .warning, source: "Download"
                )
            }
        }

        // 3. Squid
        if cancelRequested {
            return .failure(DownloadFailure(
                klass: .unknown, source: "all",
                detail: "cancelled before Squid stage",
                userMessage: "Download cancelled",
                heal: .none))
        }
        let squidResult = await attemptSquid(request: request, stagingDir: stagingDir)
        switch squidResult {
        case .success(let path):
            AppLogger.shared.log("chain[Squid]: success -> \(path.lastPathComponent)", level: .info, source: "Download")
            return .success(path, .squid)
        case .classifiedFailure(let f):
            trace.append(f)
            AppLogger.shared.log(
                "chain[Squid]: \(f.klass) heal=\(f.heal) — \(f.userMessage) — continuing to next source",
                level: .warning, source: "Download"
            )
        case .noResults:
            AppLogger.shared.log("chain[Squid]: no convincing match for \(request.artist) - \(request.title)", level: .info, source: "Download")
        case .captchaRequired:
            let captchaDetail = "captcha_verified_at needed — set MLM_SQUID_CAPTCHA from your browser's cookie for qobuz.squid.wtf (open dev-tools, Storage → Cookies), then retry"
            let captchaFailure = DownloadFailure(
                klass: .authExpired, source: "squid",
                detail: captchaDetail,
                userMessage: "Squid requires a captcha cookie — set MLM_SQUID_CAPTCHA from browser dev-tools",
                heal: .refreshAuthThenRetry)
            trace.append(captchaFailure)
            AppLogger.shared.log(
                "chain[Squid]: \(captchaFailure.klass) — \(captchaDetail)",
                level: .warning, source: "Download"
            )
        }

        // 4. YouTube (last resort)
        if cancelRequested {
            return .failure(DownloadFailure(
                klass: .unknown, source: "all",
                detail: "cancelled before YouTube stage",
                userMessage: "Download cancelled",
                heal: .none))
        }
        if youtubeDownloader.isAvailable {
            AppLogger.shared.log("chain[YT]: searching \(request.query)", level: .info, source: "Download")
            let ytOutcome = try await attemptWithRetry(
                source: "youtube",
                operation: {
                    try await self.youtubeDownloader.searchAndDownload(
                        query: request.query, outputDir: stagingDir,
                        onProgress: onTrackProgress
                    )
                }
            )
            switch ytOutcome {
            case .success(let path):
                AppLogger.shared.log("chain[YT]: success -> \(path.lastPathComponent)", level: .info, source: "Download")
                return .success(path, .youtube)
            case .failure(let f):
                trace.append(f)
                AppLogger.shared.log(
                    "chain[YT]: \(f.klass) heal=\(f.heal) — \(f.userMessage)",
                    level: .warning, source: "Download"
                )
                // TODO(coordinator): when f.klass == .toolStale, consult
                // ExternalToolHealth here. If yt-dlp is stale, surface the
                // update remedy in userMessage.
                // YouTube is the last source — select the best failure
                // from the entire trace, not just YouTube's.
                return .failure(Self.selectTerminalFailure(from: trace))
            }
        } else {
            AppLogger.shared.log("chain[YT]: yt-dlp not installed — skipping", level: .warning, source: "Download")
        }

        // All sources exhausted.
        let traceSummary = trace.map { "\($0.source)=\($0.klass)" }.joined(separator: ", ")
        AppLogger.shared.log(
            "chain: all sources exhausted for track \(request.trackId) [\(traceSummary)]",
            level: .warning, source: "Download"
        )
        if !youtubeDownloader.isAvailable && request.preferredSource != .soundcloud {
            return .failure(DownloadFailure(
                klass: .toolMissing, source: "youtube",
                detail: "yt-dlp not found; all sources exhausted",
                userMessage: "yt-dlp not installed — open Settings",
                heal: .installTool))
        }
        // Select the most informative failure from the trace.
        if !trace.isEmpty {
            return .failure(Self.selectTerminalFailure(from: trace))
        }
        return .failure(DownloadFailure(
            klass: .outputMissing, source: "all",
            detail: "all sources exhausted; trace: \(traceSummary)",
            userMessage: "Track not found on any source",
            heal: .none))
    }

    // MARK: - Chain helpers

    /// Select the most informative failure from the per-source trace to
    /// present as the terminal reason to the user.
    ///
    /// **Why not last-wins:** the last source in the chain (YouTube) often
    /// returns a generic "no results" or a transport error from a dead
    /// endpoint, discarding the more specific diagnosis from an earlier
    /// source (e.g. SoundCloud's HTTP 403 → toolStale). The user sees the
    /// least actionable message instead of the one that tells them what
    /// to fix.
    ///
    /// Selection rule (first match wins):
    /// 1. **Permanent failure** — strongest statement about the content
    ///    (e.g. DRM-protected, content removed). The chain tries every
    ///    source regardless, but when all fail the most definitive
    ///    diagnosis wins.
    /// 2. **First non-`.unknown` classified failure** — earliest source
    ///    with a positive diagnosis, which is the user's preferred source
    ///    and the one most likely to be right.
    /// 3. **Last failure** — fallback when everything was `.unknown`.
    ///
    /// The full trace is always logged regardless of which failure is
    /// selected, so discarded diagnoses remain diagnosable.
    static func selectTerminalFailure(from trace: [DownloadFailure]) -> DownloadFailure {
        guard !trace.isEmpty else {
            return DownloadFailure(
                klass: .outputMissing, source: "all",
                detail: "no failures recorded",
                userMessage: "Track not found on any source",
                heal: .none)
        }
        // Rule 1: permanent failure wins.
        if let permanent = trace.first(where: { $0.isPermanent }) {
            return permanent
        }
        // Rule 2: first non-unknown classified failure wins.
        if let diagnosed = trace.first(where: { $0.klass != .unknown }) {
            return diagnosed
        }
        // Rule 3: last failure.
        return trace.last!
    }

    /// Distinguishes "endpoint returned a classified failure" from
    /// "searched and found no matching track" — the semantic collapse
    /// that made 5,031 log lines of dead-endpoint probes indistinguishable
    /// from legitimate no-match results.
    private enum StageResult {
        case success(URL)
        case classifiedFailure(DownloadFailure)
        case noResults
        case captchaRequired
    }

    /// Retry a DownloadOutcome-returning operation on transient failures
    /// (heal == .retrySameSource) with exponential backoff plus jitter.
    /// Bounded to `maxSameSourceRetries`. Honours `cancelRequested`.
    private func attemptWithRetry(
        source: String,
        operation: () async throws -> DownloadOutcome
    ) async throws -> DownloadOutcome {
        var lastOutcome: DownloadOutcome?
        for attempt in 0...Self.maxSameSourceRetries {
            if cancelRequested {
                return lastOutcome ?? .failure(DownloadFailure(
                    klass: .unknown, source: source,
                    detail: "cancelled between retries",
                    userMessage: "Download cancelled",
                    heal: .none))
            }
            let outcome = try await operation()
            switch outcome {
            case .success:
                return outcome
            case .failure(let f):
                lastOutcome = outcome
                guard f.heal == .retrySameSource else {
                    return outcome
                }
                if attempt == Self.maxSameSourceRetries {
                    return outcome
                }
                let delay = Self.retryBaseDelay * pow(2.0, Double(attempt))
                    + Double.random(in: 0...0.5)
                AppLogger.shared.log(
                    "chain[\(source)]: \(f.klass) — retrying in \(String(format: "%.1f", delay))s (attempt \(attempt + 1)/\(Self.maxSameSourceRetries))",
                    level: .info, source: "Download"
                )
                await clock.sleep(delay)
            }
        }
        return lastOutcome ?? .failure(DownloadFailure(
            klass: .unknown, source: source,
            detail: "retry loop exited unexpectedly",
            userMessage: "Download failed — reason unknown",
            heal: .fallThroughToNextSource))
    }

    /// Attempt the DAB stage: search -> match -> download.
    private func attemptDAB(
        _ dab: any DABProviding,
        request: DownloadRequest,
        stagingDir: URL
    ) async -> StageResult {
        AppLogger.shared.log("chain[DAB]: searching \(request.query)", level: .info, source: "Download")
        do {
            guard let dabTrack = try await dab.searchTrack(query: request.query) else {
                return .noResults
            }
            if !dab.matches(dabTrack: dabTrack, artist: request.artist, title: request.title) {
                AppLogger.shared.log(
                    "chain[DAB]: hit rejected (artist mismatch): \(dabTrack.artist) - \(dabTrack.title)",
                    level: .info, source: "Download"
                )
                return .noResults
            }
            let dabResult = try await dab.download(
                dabTrack: dabTrack, outputDir: stagingDir,
                artist: request.artist, title: request.title
            )
            switch dabResult {
            case .success(let path):
                return .success(path)
            case .notFound:
                return .noResults
            }
        } catch let urlError as URLError {
            let f = DownloadFailureClassifier.classifyTransport(source: "dab", error: urlError)
            return .classifiedFailure(f)
        } catch let dabError as DABError {
            switch dabError {
            case .httpStatus(let code, let body):
                let f = DownloadFailureClassifier.classifyHTTP(source: "dab", status: code, body: body)
                return .classifiedFailure(f)
            case .noCredentials:
                return .noResults
            case .loginFailed:
                return .classifiedFailure(DownloadFailure(
                    klass: .authExpired, source: "dab",
                    detail: "DAB login failed",
                    userMessage: "DAB authentication failed",
                    heal: .refreshAuthThenRetry))
            case .invalidStreamURL(let value):
                return .classifiedFailure(DownloadFailure(
                    klass: .unknown, source: "dab",
                    detail: "DAB returned an unusable stream URL: \(value)",
                    userMessage: "DAB returned an invalid download link — trying another source",
                    heal: .none))
            }
        } catch {
            let f = DownloadFailureClassifier.classifyTransport(source: "dab", error: error)
            return .classifiedFailure(f)
        }
    }

    /// Attempt the Squid stage: search -> download.
    private func attemptSquid(
        request: DownloadRequest,
        stagingDir: URL
    ) async -> StageResult {
        AppLogger.shared.log("chain[Squid]: searching \(request.query)", level: .info, source: "Download")
        do {
            guard let squidTrack = try await squidClient.searchTrack(
                query: request.query, artist: request.artist, title: request.title
            ) else {
                return .noResults
            }
            let squidResult = try await squidClient.download(
                track: squidTrack, outputDir: stagingDir,
                artist: request.artist, title: request.title
            )
            switch squidResult {
            case .success(let path):
                return .success(path)
            case .captchaRequired:
                return .captchaRequired
            case .notFound:
                return .noResults
            }
        } catch let urlError as URLError {
            let f = DownloadFailureClassifier.classifyTransport(source: "squid", error: urlError)
            return .classifiedFailure(f)
        } catch let squidError as SquidWtfClient.SearchError {
            switch squidError {
            case .httpStatus(let code, let body):
                let f = DownloadFailureClassifier.classifyHTTP(source: "squid", status: code, body: body)
                return .classifiedFailure(f)
            }
        } catch {
            let f = DownloadFailureClassifier.classifyTransport(source: "squid", error: error)
            return .classifiedFailure(f)
        }
    }

    // MARK: - Finalization (SCDL-09)

    func finalDirectory(for source: DownloadSource) -> URL {
        switch source {
        case .soundcloud: return soundCloudDir
        case .youtube, .dab, .squid: return aacDir
        }
    }

    func preservesOriginal(for source: DownloadSource) -> Bool {
        switch source {
        case .dab, .squid: return true
        case .soundcloud, .youtube: return false
        }
    }

    func placeFinal(
        _ produced: URL,
        into finalDir: URL,
        fileName: String? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: finalDir, withIntermediateDirectories: true)
        let dest = finalDir.appendingPathComponent(fileName ?? produced.lastPathComponent)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: produced)
        } else {
            try fm.moveItem(at: produced, to: dest)
        }
        return dest
    }

    func sourceFileDirectory(for source: DownloadSource) -> URL {
        switch source {
        case .soundcloud: return soundCloudDir
        case .youtube: return aacDir
        case .dab, .squid: return flacDir
        }
    }

    static func finalFileName(
        for request: DownloadRequest,
        pathExtension: String
    ) -> String {
        let identity = PathSanitizer.sanitizeComponent(
            "\(request.artist) - \(request.title)"
        )
        let normalizedExtension = pathExtension.lowercased()
        let suffix = normalizedExtension.isEmpty
            ? " [\(request.trackId)]"
            : " [\(request.trackId)].\(normalizedExtension)"
        let maxIdentityLength = max(1, 255 - suffix.count)
        return "\(identity.prefix(maxIdentityLength))\(suffix)"
    }

    /// Embed artwork from the request's artworkURL into the finalized file.
    private func embedArtworkIfNeeded(request: DownloadRequest, at path: URL) async {
        guard let artworkStr = request.artworkURL,
              let artworkURL = URL(string: artworkStr) else { return }
        _ = await ArtworkService.embedArtwork(from: artworkURL, into: path)
    }

    func finalize(
        sourcePath: URL,
        source: DownloadSource,
        request: DownloadRequest
    ) async throws -> (path: URL, format: String, bitrate: Int?) {
        let fm = FileManager.default
        let tempDir = aacDir
            .deletingLastPathComponent()
            .appendingPathComponent(".mlm-transcode-tmp")
            .appendingPathComponent("\(request.trackId)-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let transcodeInput: URL
        if preservesOriginal(for: source) {
            transcodeInput = try placeFinal(
                sourcePath, into: flacDir,
                fileName: Self.finalFileName(for: request, pathExtension: sourcePath.pathExtension)
            )
        } else {
            transcodeInput = sourcePath
        }

        let transcodeResult = try await transcodeService.transcode(
            input: transcodeInput, outputDir: tempDir
        )

        switch transcodeResult {
        case .transcoded(let produced):
            let dest = try placeFinal(
                produced, into: finalDirectory(for: source),
                fileName: Self.finalFileName(for: request, pathExtension: produced.pathExtension)
            )
            await embedArtworkIfNeeded(request: request, at: dest)
            return (dest, dest.pathExtension.lowercased(), TranscodeService.targetBitrate)

        case .skipped:
            if preservesOriginal(for: source) {
                let kbps = await transcodeService.detectBitrateKbps(transcodeInput)
                await embedArtworkIfNeeded(request: request, at: transcodeInput)
                return (transcodeInput, transcodeInput.pathExtension.lowercased(), kbps)
            }
            let dest = try placeFinal(
                transcodeInput, into: sourceFileDirectory(for: source),
                fileName: Self.finalFileName(for: request, pathExtension: transcodeInput.pathExtension)
            )
            let kbps = await transcodeService.detectBitrateKbps(dest)
            await embedArtworkIfNeeded(request: request, at: dest)
            return (dest, dest.pathExtension.lowercased(), kbps)

        case .failed(let error):
            // Deliberate: preserve the original un-transcoded file when
            // ffmpeg fails — the user gets *something* playable rather
            // than nothing. The log carries trackId, artist/title, source
            // format and the ffmpeg error so the failure is diagnosable.
            AppLogger.shared.log(
                "Transcode failed for track \(request.trackId) (\(request.artist) - \(request.title), source=\(source), format=\(sourcePath.pathExtension)): \(error) — placing original un-transcoded file",
                level: .warning,
                source: "Download"
            )
            if preservesOriginal(for: source) {
                let kbps = await transcodeService.detectBitrateKbps(transcodeInput)
                return (transcodeInput, transcodeInput.pathExtension.lowercased(), kbps)
            }
            let dest = try placeFinal(
                transcodeInput, into: sourceFileDirectory(for: source),
                fileName: Self.finalFileName(for: request, pathExtension: transcodeInput.pathExtension)
            )
            let kbps = await transcodeService.detectBitrateKbps(dest)
            return (dest, dest.pathExtension.lowercased(), kbps)
        }
    }
}

// MARK: - Protocol conformance for production providers

extension SoundCloudDownloader: DownloadOrchestrator.SoundCloudProviding {}
extension YouTubeDownloader: DownloadOrchestrator.YouTubeProviding {}
extension DABClient: DownloadOrchestrator.DABProviding {}
extension SquidWtfClient: DownloadOrchestrator.SquidProviding {}
