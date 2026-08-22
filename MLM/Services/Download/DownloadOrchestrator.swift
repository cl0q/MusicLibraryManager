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
    }

    /// Container-format and bitrate metadata for a freshly downloaded file.
    struct DownloadedFileInfo {
        let format: String
        let bitrate: Int?
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
    private let soundCloudDownloader: SoundCloudDownloader
    private let youtubeDownloader: YouTubeDownloader
    private let retryQueue: DownloadQueue
    private var dabClient: DABClient?
    private let squidClient: SquidWtfClient

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

    /// Download a batch of tracks following the fallback chain.
    ///
    /// Processing is sequential (not parallel) to simplify rate limiting.
    /// Chain: SoundCloud (if URL) → DAB → YouTube
    func downloadBatch(
        _ requests: [DownloadRequest],
        onProgress: ((Int, Int, String) -> Void)? = nil,
        onTrackProgress: ((Double) -> Void)? = nil
    ) async -> BatchResult {
        isRunning = true
        cancelRequested = false
        defer { isRunning = false }

        var result = BatchResult()
        let total = requests.count

        guard !requests.isEmpty else {
            progress = 1.0
            return result
        }

        // The staging directory is intentionally hidden and is not part of
        // the managed layout. Source folders are created only in finalization.
        do {
            try FileManager.default.createDirectory(
                at: aacDir.deletingLastPathComponent().appendingPathComponent(".mlm-download-tmp"),
                withIntermediateDirectories: true
            )
        } catch {
            let failureReason = DownloadFailureReason.failureReason(for: error)
            AppLogger.shared.error(
                "Download staging directory is not writable (\(error.localizedDescription)). Library drive offline? root=\(aacDir.deletingLastPathComponent().path)",
                source: "Download"
            )
            result.failed = total
            result.failedTrackIds = Set(requests.map(\.trackId))
            for req in requests {
                result.failureReasons[req.trackId] = failureReason.userFacingText
                retryQueue.enqueue(
                    trackId: req.trackId,
                    query: req.query,
                    source: req.preferredSource.storageKey,
                    error: failureReason.userFacingText,
                    artist: req.artist,
                    title: req.title,
                    preferredSource: req.preferredSource.storageKey,
                    soundcloudURL: req.soundcloudURL,
                    youtubeURL: req.youtubeURL
                )
            }
            return result
        }

        for (index, request) in requests.enumerated() {
            // Check cancellation flag before starting a new download so
            // the running track gets to finish but the next one is
            // skipped — keeps the DB consistent with what's on disk.
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

            currentItem = "\(request.artist) - \(request.title)"
            progress = Double(index) / Double(max(total, 1))
            onProgress?(index, total, currentItem)

            // Reset per-track progress to 0 before the next attempt.
            onTrackProgress?(0)

            // Try the fallback chain
            do {
                let stagingDir = aacDir
                    .deletingLastPathComponent()
                    .appendingPathComponent(".mlm-download-tmp")
                    .appendingPathComponent("\(request.trackId)-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: stagingDir) }

                if let (path, source) = try await downloadWithFallback(
                    request,
                    stagingDir: stagingDir,
                    onTrackProgress: onTrackProgress
                ) {
                    // Route to the source's correct final directory via a
                    // collision-free temp-transcode + atomic move/replace
                    // (SCDL-09) — replaces the old inline
                    // transcodeService.transcode(... outputDir: aacDir) call,
                    // which mis-routed SoundCloud/YouTube output and could
                    // false-skip when input==output aliased.
                    let finalized = try await finalize(sourcePath: path, source: source, request: request)
                    result.downloadedPaths[request.trackId] = finalized.path.path
                    result.downloadedMetadata[request.trackId] = DownloadedFileInfo(
                        format: finalized.format,
                        bitrate: finalized.bitrate
                    )
                    result.succeeded += 1
                } else {
                    let failureReason = Self.failureReasonForExhaustedSources(
                        preferredSource: request.preferredSource,
                        youtubeAvailable: youtubeDownloader.isAvailable
                    )
                    result.failed += 1
                    result.failedTrackIds.insert(request.trackId)
                    result.failureReasons[request.trackId] = failureReason.userFacingText
                    retryQueue.enqueue(
                        trackId: request.trackId,
                        query: request.query,
                        source: request.preferredSource.storageKey,
                        error: failureReason.userFacingText,
                        artist: request.artist,
                        title: request.title,
                        preferredSource: request.preferredSource.storageKey,
                        soundcloudURL: request.soundcloudURL,
                        youtubeURL: request.youtubeURL
                    )
                }
            } catch {
                result.failed += 1
                result.failedTrackIds.insert(request.trackId)
                let failureReason = DownloadFailureReason.failureReason(for: error)
                result.failureReasons[request.trackId] = failureReason.userFacingText
                AppLogger.shared.error(
                    "Download failed for track \(request.trackId) (\(request.artist) - \(request.title)): \(error.localizedDescription) [type=\(String(describing: type(of: error)))]",
                    source: "Download"
                )
                retryQueue.enqueue(
                    trackId: request.trackId,
                    query: request.query,
                    source: request.preferredSource.storageKey,
                    error: failureReason.userFacingText,
                    artist: request.artist,
                    title: request.title,
                    preferredSource: request.preferredSource.storageKey,
                    soundcloudURL: request.soundcloudURL,
                    youtubeURL: request.youtubeURL
                )
            }
        }

        progress = 1.0
        currentItem = ""
        return result
    }

    /// Retry previously failed downloads.
    ///
    /// Rebuilds each request from the QueueItem's stored `preferredSource` +
    /// `soundcloudURL` so a SoundCloud-pinned failure re-enters the
    /// fail-closed `pinned[SC]` branch instead of silently defaulting to
    /// `.auto` and running the full cross-provider chain — see SCDL-01.
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

    /// All persisted legacy queue entries, including entries that reached the
    /// global retry cap. Activity uses this to keep every recoverable failure
    /// visible and offer an explicit per-row retry.
    func persistedRetryItems() -> [DownloadQueue.QueueItem] {
        retryQueue.items
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

    /// Remove retry entries only after the downloaded files were persisted.
    func dequeuePersistedRetries(trackIds: Set<Int64>) {
        retryQueue.dequeue(trackIds: trackIds)
    }

    func enqueuePersistenceFailures(
        requests: [DownloadRequest],
        trackIds: Set<Int64>
    ) {
        for request in requests where trackIds.contains(request.trackId) {
            retryQueue.enqueue(
                trackId: request.trackId,
                query: request.query,
                source: request.preferredSource.storageKey,
                error: "Downloaded file could not be saved to library",
                artist: request.artist,
                title: request.title,
                preferredSource: request.preferredSource.storageKey,
                soundcloudURL: request.soundcloudURL,
                youtubeURL: request.youtubeURL
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
    ///
    /// - Parameters:
    ///   - artist: The track artist
    ///   - title: The track title
    ///   - soundcloudURL: SoundCloud permalink URL, if any
    ///   - targetDir: Directory where the final file should be stored
    /// - Returns: The URL of the downloaded file on success, or nil
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

        // 1. SoundCloud direct (if URL available and scdl installed)
        if let scURL = request.soundcloudURL {
            if soundCloudDownloader.isAvailable {
                AppLogger.shared.log("discovery[SC]: trying \(scURL)", level: .info, source: "Download")
                let scResult = try await soundCloudDownloader.download(
                    trackURL: scURL,
                    outputDir: targetDir,
                    trackId: -999,
                    title: "\(request.artist) - \(request.title)",
                    onProgress: onProgress
                )
                if case .success(let path) = scResult {
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
                            dabTrack: dabTrack,
                            outputDir: targetDir,
                            artist: request.artist,
                            title: request.title
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
                query: request.query,
                artist: request.artist,
                title: request.title
            ) {
                let squidResult = try await squidClient.download(
                    track: squidTrack,
                    outputDir: targetDir,
                    artist: request.artist,
                    title: request.title
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
            let ytResult = try await youtubeDownloader.searchAndDownload(
                query: request.query,
                outputDir: targetDir,
                onProgress: onProgress
            )
            if case .success(let path) = ytResult {
                AppLogger.shared.log("discovery[YT]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                return path
            }
        }

        return nil
    }

    // MARK: - Fallback Chain

    /// Try downloading via SoundCloud → DAB → YouTube.
    ///
    /// Returns the downloaded file's path tagged with the concrete
    /// `DownloadSource` that produced it, so `finalize` can route the file
    /// to its correct final directory (SCDL-09) regardless of whether the
    /// request was pinned or ran the auto chain.
    private func downloadWithFallback(
        _ request: DownloadRequest,
        stagingDir: URL,
        onTrackProgress: ((Double) -> Void)? = nil
    ) async throws -> (URL, DownloadSource)? {
        // Source pinning — when a request is bound to a specific source we
        // do NOT fall through to other providers (SC playlists stay on SC,
        // YT playlists stay on YT).
        switch request.preferredSource {
        case .soundcloud:
            guard let scURL = request.soundcloudURL else {
                AppLogger.shared.log(
                    "pinned[SC]: no SoundCloud URL for track id=\(request.trackId) — \(request.artist) - \(request.title)",
                    level: .warning, source: "Download"
                )
                return nil
            }
            guard soundCloudDownloader.isAvailable else {
                AppLogger.shared.log(
                    "pinned[SC]: scdl not installed — install via `pip install scdl`",
                    level: .warning, source: "Download"
                )
                return nil
            }
            AppLogger.shared.log("pinned[SC]: trying \(scURL)", level: .info, source: "Download")
            let scResult = try await soundCloudDownloader.download(
                trackURL: scURL,
                outputDir: stagingDir,
                trackId: request.trackId,
                title: "\(request.artist) - \(request.title)",
                onProgress: onTrackProgress
            )
            if case .success(let path) = scResult {
                AppLogger.shared.log("pinned[SC]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                return (path, .soundcloud)
            }
            AppLogger.shared.log("pinned[SC]: not found (no cross-source fallback)", level: .warning, source: "Download")
            return nil

        case .youtube:
            guard youtubeDownloader.isAvailable else {
                AppLogger.shared.log(
                    "pinned[YT]: yt-dlp not installed",
                    level: .warning, source: "Download"
                )
                return nil
            }
            let ytResult: YouTubeDownloader.DownloadResult
            if let ytURL = request.youtubeURL {
                AppLogger.shared.log("pinned[YT]: downloading \(ytURL)", level: .info, source: "Download")
                ytResult = try await youtubeDownloader.downloadByURL(ytURL, outputDir: stagingDir)
            } else {
                AppLogger.shared.log("pinned[YT]: searching \(request.query)", level: .info, source: "Download")
                ytResult = try await youtubeDownloader.searchAndDownload(
                    query: request.query,
                    outputDir: stagingDir,
                    onProgress: onTrackProgress
                )
            }
            if case .success(let path) = ytResult {
                AppLogger.shared.log("pinned[YT]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                return (path, .youtube)
            }
            AppLogger.shared.log("pinned[YT]: not found (no cross-source fallback)", level: .warning, source: "Download")
            return nil

        case .auto:
            break  // fall through to the full chain below
        }

        // 1. SoundCloud direct (if URL available and scdl installed)
        if request.soundcloudURL == nil {
            AppLogger.shared.log(
                "chain[SC]: no SoundCloud URL for track id=\(request.trackId) — \(request.artist) - \(request.title)",
                level: .info, source: "Download"
            )
        }
        if let scURL = request.soundcloudURL {
            if soundCloudDownloader.isAvailable {
                AppLogger.shared.log("chain[SC]: trying \(scURL)", level: .info, source: "Download")
                let scResult = try await soundCloudDownloader.download(
                    trackURL: scURL,
                    outputDir: stagingDir,
                    trackId: request.trackId,
                    title: "\(request.artist) - \(request.title)",
                    onProgress: onTrackProgress
                )
                if case .success(let path) = scResult {
                    AppLogger.shared.log("chain[SC]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                    return (path, .soundcloud)
                }
                AppLogger.shared.log("chain[SC]: not found, falling through", level: .info, source: "Download")
            } else {
                AppLogger.shared.log(
                    "chain[SC]: scdl not installed — skipping (install via `pip install scdl`)",
                    level: .warning, source: "Download"
                )
            }
        }

        // 2. DAB Music API — silently skipped if no creds and server requires auth
        if let dab = dabClient {
            do {
                AppLogger.shared.log("chain[DAB]: searching \(request.query)", level: .info, source: "Download")
                if let dabTrack = try await dab.searchTrack(query: request.query) {
                    if dab.matches(dabTrack: dabTrack, artist: request.artist, title: request.title) {
                        let dabResult = try await dab.download(
                            dabTrack: dabTrack,
                            outputDir: stagingDir,
                            artist: request.artist,
                            title: request.title
                        )
                        if case .success(let path) = dabResult {
                            AppLogger.shared.log("chain[DAB]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                            return (path, .dab)
                        }
                    } else {
                        AppLogger.shared.log(
                            "chain[DAB]: hit rejected (artist mismatch): \(dabTrack.artist) - \(dabTrack.title)",
                            level: .info, source: "Download"
                        )
                    }
                }
            } catch {
                AppLogger.shared.log("chain[DAB]: error: \(error)", level: .warning, source: "Download")
            }
        }

        // 3. Squid.wtf (Qobuz mirror) — requires MLM_SQUID_CF_COOKIE env
        //    for the actual download (Cloudflare bot-fight blocks
        //    cookie-less calls with "Captcha required").
        do {
            AppLogger.shared.log("chain[Squid]: searching \(request.query)", level: .info, source: "Download")
            if let squidTrack = try await squidClient.searchTrack(
                query: request.query,
                artist: request.artist,
                title: request.title
            ) {
                let squidResult = try await squidClient.download(
                    track: squidTrack,
                    outputDir: stagingDir,
                    artist: request.artist,
                    title: request.title
                )
                switch squidResult {
                case .success(let path):
                    AppLogger.shared.log("chain[Squid]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                    return (path, .squid)
                case .captchaRequired:
                    AppLogger.shared.log(
                        "chain[Squid]: search hit but download needs captcha_verified_at — set MLM_SQUID_CAPTCHA from your browser's cookie for qobuz.squid.wtf (open dev-tools, Storage → Cookies), then retry",
                        level: .warning, source: "Download"
                    )
                case .notFound:
                    AppLogger.shared.log("chain[Squid]: download endpoint returned nothing usable", level: .info, source: "Download")
                }
            } else {
                AppLogger.shared.log("chain[Squid]: no convincing match for \(request.artist) - \(request.title)", level: .info, source: "Download")
            }
        } catch {
            AppLogger.shared.log("chain[Squid]: error: \(error)", level: .warning, source: "Download")
        }

        // 4. YouTube (last resort)
        if youtubeDownloader.isAvailable {
            AppLogger.shared.log("chain[YT]: searching \(request.query)", level: .info, source: "Download")
            let ytResult = try await youtubeDownloader.searchAndDownload(
                query: request.query,
                outputDir: stagingDir,
                onProgress: onTrackProgress
            )
            if case .success(let path) = ytResult {
                AppLogger.shared.log("chain[YT]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                return (path, .youtube)
            }
            AppLogger.shared.log("chain[YT]: not found", level: .warning, source: "Download")
        }

        return nil
    }

    // MARK: - Finalization (SCDL-09)
    //
    // Each provider's final, DB-referenced file must land in a directory
    // whose name honestly describes its content: true-FLAC (DAB/Squid) in
    // `00_FLAC`, everything else (SoundCloud/YouTube, both lossy) in their
    // own final directories. Provider downloads and transcoding both use
    // per-request staging directories, then deterministic track-ID filenames
    // are atomically moved/replaced in the final directory.

    /// Pure mapping from a concrete download source to its final directory:
    /// `.soundcloud` gets its own directory; `.youtube`/`.dab`/`.squid` all
    /// transcode/finalize into `aacDir` (the shared AAC library copy). For
    /// `.dab`/`.squid` the true-FLAC *original* additionally stays behind in
    /// `flacDir` untouched — see `preservesOriginal(for:)`.
    func finalDirectory(for source: DownloadSource) -> URL {
        switch source {
        case .soundcloud: return soundCloudDir
        case .youtube, .dab, .squid: return aacDir
        }
    }

    /// Whether the original downloaded file for this source must be left
    /// untouched on disk after finalization (true FLAC originals from
    /// DAB/Squid), as opposed to being superseded by its own transcode and
    /// deleted as a now-redundant lossy duplicate (SoundCloud/YouTube).
    func preservesOriginal(for source: DownloadSource) -> Bool {
        switch source {
        case .dab, .squid: return true
        case .soundcloud, .youtube: return false
        }
    }

    /// Moves (or, on a basename collision, atomically replaces) `produced`
    /// into `finalDir`, returning the resulting path.
    ///
    /// Using `replaceItemAt` on collision means finalization always
    /// succeeds — there is never a stale "output already exists" skip
    /// caused by a previous partial run leaving a same-named file behind.
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

    /// Finalizes a successful download: transcodes into a per-request temp
    /// directory (so the transcode output can never alias the source file,
    /// which would otherwise cause `TranscodeService` to falsely report
    /// "output already exists"), then atomically places the result into the
    /// source's correct final directory.
    func finalize(
        sourcePath: URL,
        source: DownloadSource,
        request: DownloadRequest
    ) async throws -> (path: URL, format: String, bitrate: Int?) {
        let fm = FileManager.default
        // Per-request temp dir on the SAME volume as the library root so
        // `placeFinal`'s move is an atomic same-filesystem rename, not a
        // cross-volume copy — the library may live on an external drive.
        let tempDir = aacDir
            .deletingLastPathComponent()
            .appendingPathComponent(".mlm-transcode-tmp")
            .appendingPathComponent("\(request.trackId)-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let transcodeInput: URL
        if preservesOriginal(for: source) {
            transcodeInput = try placeFinal(
                sourcePath,
                into: flacDir,
                fileName: Self.finalFileName(
                    for: request,
                    pathExtension: sourcePath.pathExtension
                )
            )
        } else {
            transcodeInput = sourcePath
        }

        let transcodeResult = try await transcodeService.transcode(
            input: transcodeInput,
            outputDir: tempDir
        )

        switch transcodeResult {
        case .transcoded(let produced):
            let dest = try placeFinal(
                produced,
                into: finalDirectory(for: source),
                fileName: Self.finalFileName(
                    for: request,
                    pathExtension: produced.pathExtension
                )
            )
            return (dest, dest.pathExtension.lowercased(), TranscodeService.targetBitrate)

        case .skipped:
            if preservesOriginal(for: source) {
                let kbps = await transcodeService.detectBitrateKbps(transcodeInput)
                return (
                    transcodeInput,
                    transcodeInput.pathExtension.lowercased(),
                    kbps
                )
            }
            let dest = try placeFinal(
                transcodeInput,
                into: sourceFileDirectory(for: source),
                fileName: Self.finalFileName(
                    for: request,
                    pathExtension: transcodeInput.pathExtension
                )
            )
            let kbps = await transcodeService.detectBitrateKbps(dest)
            return (dest, dest.pathExtension.lowercased(), kbps)

        case .failed(let error):
            AppLogger.shared.log("Transcode failed for \(request.title): \(error)", level: .warning)
            if preservesOriginal(for: source) {
                let kbps = await transcodeService.detectBitrateKbps(transcodeInput)
                return (
                    transcodeInput,
                    transcodeInput.pathExtension.lowercased(),
                    kbps
                )
            }
            let dest = try placeFinal(
                transcodeInput,
                into: sourceFileDirectory(for: source),
                fileName: Self.finalFileName(
                    for: request,
                    pathExtension: transcodeInput.pathExtension
                )
            )
            let kbps = await transcodeService.detectBitrateKbps(dest)
            return (dest, dest.pathExtension.lowercased(), kbps)
        }
    }
}
