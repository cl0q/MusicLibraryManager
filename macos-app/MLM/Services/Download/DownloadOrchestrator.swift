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
    }

    // MARK: - Download Batch

    /// Download a batch of tracks following the fallback chain.
    ///
    /// Processing is sequential (not parallel) to simplify rate limiting.
    /// Chain: SoundCloud (if URL) → DAB → YouTube
    func downloadBatch(
        _ requests: [DownloadRequest],
        onProgress: ((Int, Int, String) -> Void)? = nil
    ) async -> BatchResult {
        isRunning = true
        defer { isRunning = false }

        var result = BatchResult()
        let total = requests.count

        for (index, request) in requests.enumerated() {
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

            // Try the fallback chain
            do {
                if let path = try await downloadWithFallback(request) {
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
                        // Source was already lossy and below threshold — use as-is
                        result.downloadedPaths[request.trackId] = path.path
                        result.downloadedMetadata[request.trackId] = DownloadedFileInfo(
                            format: path.pathExtension.lowercased(),
                            bitrate: nil  // Unknown — keep DB bitrate untouched
                        )
                        result.succeeded += 1
                    case .failed(let error):
                        // Download succeeded but transcode failed
                        result.downloadedPaths[request.trackId] = path.path
                        result.downloadedMetadata[request.trackId] = DownloadedFileInfo(
                            format: path.pathExtension.lowercased(),
                            bitrate: nil
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
    private func downloadWithFallback(_ request: DownloadRequest) async throws -> URL? {
        // 1. SoundCloud direct (if URL available and scdl installed)
        if let scURL = request.soundcloudURL, soundCloudDownloader.isAvailable {
            let scResult = try await soundCloudDownloader.download(
                trackURL: scURL,
                outputDir: aacDir,
                trackId: request.trackId,
                title: request.title
            )
            if case .success(let path) = scResult {
                return path
            }
        }

        // 2. DAB Music API
        if let dab = dabClient {
            do {
                if let dabTrack = try await dab.searchTrack(query: request.query) {
                    if dab.matches(dabTrack: dabTrack, artist: request.artist, title: request.title) {
                        let dabResult = try await dab.download(
                            dabTrack: dabTrack,
                            outputDir: flacDir,
                            artist: request.artist,
                            title: request.title
                        )
                        if case .success(let path) = dabResult {
                            return path
                        }
                    }
                }
            } catch {
                AppLogger.shared.log("DAB failed for \(request.query): \(error)", level: .warning)
            }
        }

        // 3. YouTube (last resort)
        if youtubeDownloader.isAvailable {
            let ytResult = try await youtubeDownloader.searchAndDownload(
                query: request.query,
                outputDir: flacDir
            )
            if case .success(let path) = ytResult {
                return path
            }
        }

        return nil
    }
}
