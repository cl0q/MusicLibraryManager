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
    enum PreferredSource {
        case auto
        case soundcloud
        case youtube
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
    }

    /// Aggregate result of a batch download.
    struct BatchResult {
        var succeeded: Int = 0
        var failed: Int = 0
        var skipped: Int = 0
        var downloadedPaths: [Int64: String] = [:]
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
    private let transcodeService: TranscodeService
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
        self.flacDir = root.appendingPathComponent("00_FLAC")
        self.aacDir = root.appendingPathComponent("00_Artists")

        self.transcodeService = TranscodeService()
        self.soundCloudDownloader = SoundCloudDownloader()
        self.youtubeDownloader = YouTubeDownloader()
        self.retryQueue = DownloadQueue(directory: flacDir)
        self.dabClient = DABClient(tokenStorage: tokenStorage)
        self.squidClient = SquidWtfClient()

        // Create directories
        try? FileManager.default.createDirectory(at: flacDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: aacDir, withIntermediateDirectories: true)

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

        // Bail out loudly if the download directories can't be created
        // (most likely the library drive isn't mounted right now). The
        // previous behaviour was to swallow the createDirectory throw
        // inside each per-track call, which made every track fail in
        // ~0.3 ms with no log lines other than "chain[SC]: trying".
        do {
            try FileManager.default.createDirectory(at: flacDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: aacDir, withIntermediateDirectories: true)
        } catch {
            AppLogger.shared.error(
                "Download dirs not writable (\(error.localizedDescription)). Library drive offline? aacDir=\(aacDir.path) flacDir=\(flacDir.path)",
                source: "Download"
            )
            result.failed = total
            for req in requests {
                retryQueue.enqueue(
                    trackId: req.trackId,
                    query: req.query,
                    source: "youtube",
                    error: "Library drive not writable: \(error.localizedDescription)"
                )
            }
            return result
        }

        for (index, request) in requests.enumerated() {
            // Check cancellation flag before starting a new download so
            // the running track gets to finish but the next one is
            // skipped — keeps the DB consistent with what's on disk.
            if cancelRequested {
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

            // Check if already downloaded (skip)
            let expectedFilename = PathSanitizer.sanitizeComponent("\(request.artist) - \(request.title).flac")
            let expectedPath = flacDir.appendingPathComponent(expectedFilename)
            if FileManager.default.fileExists(atPath: expectedPath.path) {
                result.skipped += 1
                continue
            }

            // Reset per-track progress to 0 before the next attempt.
            onTrackProgress?(0)

            // Try the fallback chain
            do {
                if let path = try await downloadWithFallback(request, onTrackProgress: onTrackProgress) {
                    // Transcode to AAC
                    let transcodeResult = try await transcodeService.transcode(
                        input: path,
                        outputDir: aacDir
                    )

                    switch transcodeResult {
                    case .transcoded(let aacPath):
                        result.downloadedPaths[request.trackId] = aacPath.path
                        result.downloadedMetadata[request.trackId] = DownloadedFileInfo(
                            format: aacPath.pathExtension.lowercased(),
                            bitrate: TranscodeService.targetBitrate
                        )
                        result.succeeded += 1
                    case .skipped:
                        // Source was already lossy and below threshold — use as-is.
                        // Probe the file so the DB row reflects the actual quality.
                        let kbps = await transcodeService.detectBitrateKbps(path)
                        result.downloadedPaths[request.trackId] = path.path
                        result.downloadedMetadata[request.trackId] = DownloadedFileInfo(
                            format: path.pathExtension.lowercased(),
                            bitrate: kbps
                        )
                        result.succeeded += 1
                    case .failed(let error):
                        // Download succeeded but transcode failed — keep the source file.
                        let kbps = await transcodeService.detectBitrateKbps(path)
                        result.downloadedPaths[request.trackId] = path.path
                        result.downloadedMetadata[request.trackId] = DownloadedFileInfo(
                            format: path.pathExtension.lowercased(),
                            bitrate: kbps
                        )
                        result.succeeded += 1
                        AppLogger.shared.log("Transcode failed for \(request.title): \(error)", level: .warning)
                    }
                } else {
                    result.failed += 1
                    retryQueue.enqueue(
                        trackId: request.trackId,
                        query: request.query,
                        source: "youtube",
                        error: "All sources exhausted"
                    )
                }
            } catch {
                result.failed += 1
                AppLogger.shared.error(
                    "Download failed for track \(request.trackId) (\(request.artist) - \(request.title)): \(error.localizedDescription) [type=\(String(describing: type(of: error)))]",
                    source: "Download"
                )
                retryQueue.enqueue(
                    trackId: request.trackId,
                    query: request.query,
                    source: "youtube",
                    error: error.localizedDescription
                )
            }
        }

        progress = 1.0
        currentItem = ""
        return result
    }

    /// Retry previously failed downloads.
    func retryFailed() async -> BatchResult {
        let retryable = retryQueue.retryableItems()
        let requests = retryable.map { item in
            DownloadRequest(
                trackId: item.trackId,
                artist: "",
                title: "",
                query: item.query,
                soundcloudURL: nil,
                userId: nil
            )
        }
        return await downloadBatch(requests)
    }

    // MARK: - Fallback Chain

    /// Try downloading via SoundCloud → DAB → YouTube.
    private func downloadWithFallback(
        _ request: DownloadRequest,
        onTrackProgress: ((Double) -> Void)? = nil
    ) async throws -> URL? {
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
                outputDir: aacDir,
                trackId: request.trackId,
                title: request.title,
                onProgress: onTrackProgress
            )
            if case .success(let path) = scResult {
                AppLogger.shared.log("pinned[SC]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                return path
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
                ytResult = try await youtubeDownloader.downloadByURL(ytURL, outputDir: flacDir)
            } else {
                AppLogger.shared.log("pinned[YT]: searching \(request.query)", level: .info, source: "Download")
                ytResult = try await youtubeDownloader.searchAndDownload(
                    query: request.query,
                    outputDir: flacDir,
                    onProgress: onTrackProgress
                )
            }
            if case .success(let path) = ytResult {
                AppLogger.shared.log("pinned[YT]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                return path
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
                    outputDir: aacDir,
                    trackId: request.trackId,
                    title: request.title,
                    onProgress: onTrackProgress
                )
                if case .success(let path) = scResult {
                    AppLogger.shared.log("chain[SC]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                    return path
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
                            outputDir: flacDir,
                            artist: request.artist,
                            title: request.title
                        )
                        if case .success(let path) = dabResult {
                            AppLogger.shared.log("chain[DAB]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                            return path
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
                    outputDir: flacDir,
                    artist: request.artist,
                    title: request.title
                )
                switch squidResult {
                case .success(let path):
                    AppLogger.shared.log("chain[Squid]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                    return path
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
                outputDir: flacDir,
                onProgress: onTrackProgress
            )
            if case .success(let path) = ytResult {
                AppLogger.shared.log("chain[YT]: success → \(path.lastPathComponent)", level: .info, source: "Download")
                return path
            }
            AppLogger.shared.log("chain[YT]: not found", level: .warning, source: "Download")
        }

        return nil
    }
}
