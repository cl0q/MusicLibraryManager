import Foundation

/// Central download coordinator implementing the DAB → SoundCloud → YouTube
/// fallback chain.
///
/// Mirrors the Rust `DownloadOrchestrator`. Downloads source audio (FLAC/AAC),
/// then transcodes to 248kbps AAC for the library.
@Observable
final class DownloadOrchestrator {

    // MARK: - Types

    /// A request to download a single track.
    struct DownloadRequest {
        let trackId: Int64
        let artist: String
        let title: String
        let query: String
        let soundcloudURL: String?
        let userId: String?
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

        // Create directories
        try? FileManager.default.createDirectory(at: flacDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: aacDir, withIntermediateDirectories: true)

        // Once-at-boot DAB endpoint reachability log so the Logs tab tells
        // the user whether the FLAC step is live or has degraded to the
        // YouTube fallback. Background task — never blocks init.
        let endpoint = DABClient.baseURL
        Task.detached(priority: .background) {
            if endpoint.isEmpty {
                AppLogger.shared.info(
                    "DAB endpoint disabled (MLM_DAB_API_BASE = \"\")",
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
                    "DAB endpoint reachable: \(endpoint) (HTTP \(code))",
                    source: "Download"
                )
            } catch {
                AppLogger.shared.warn(
                    "DAB endpoint NOT reachable: \(endpoint) — \(error.localizedDescription). Pipeline will skip DAB and fall through to YouTube. Set MLM_DAB_API_BASE to override.",
                    source: "Download"
                )
            }
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

        // 3. YouTube (last resort)
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
