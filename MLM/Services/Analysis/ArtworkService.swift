import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Album artwork service — extracts embedded art and fetches from MusicBrainz/CAA.
///
/// Mirrors the Rust `ArtworkService`. Two sizes: 500px (iPod embed) and
/// 1200px (high-DPI UI). Rate limit: 1 req/sec to MusicBrainz.
final class ArtworkService: Sendable {

    /// MusicBrainz API endpoint.
    private static let musicBrainzURL = "https://musicbrainz.org/ws/2"
    /// Cover Art Archive endpoint.
    private static let coverArtURL = "https://coverartarchive.org"
    /// User-Agent required by MusicBrainz.
    private static let userAgent = "MusicLibraryManager/1.0 (https://github.com/mlm)"

    /// Standard artwork sizes.
    enum ArtworkSize: Int {
        case small = 500   // iPod Classic
        case large = 1200  // High-DPI UI
    }

    private let cacheDir: URL
    private let session: URLSession

    init(cacheDir: URL) {
        self.cacheDir = cacheDir
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)

        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Cache

    /// Get cached artwork path for a track and size.
    func cachedPath(trackId: Int64, size: ArtworkSize) -> URL {
        cacheDir.appendingPathComponent("\(trackId)_\(size.rawValue).jpg")
    }

    /// Check if artwork is cached for both sizes.
    func isCached(trackId: Int64) -> Bool {
        let small = cachedPath(trackId: trackId, size: .small)
        let large = cachedPath(trackId: trackId, size: .large)
        return FileManager.default.fileExists(atPath: small.path) &&
               FileManager.default.fileExists(atPath: large.path)
    }

    // MARK: - Batch Fetch

    struct BatchResult {
        var fetched: Int = 0
        var alreadyCached: Int = 0
        var notFound: Int = 0
        var failed: Int = 0
    }

    /// Thread-safe result collector for batch operations.
///
/// Uses an actor to ensure safe concurrent mutations from parallel tasks.
actor BatchResultCollector {
    private var result: BatchResult
    
    init() {
        self.result = BatchResult()
    }
    
    func addFetched() { result.fetched += 1 }
    func addAlreadyCached() { result.alreadyCached += 1 }
    func addNotFound() { result.notFound += 1 }
    func addFailed() { result.failed += 1 }
    
    func getResult() -> BatchResult { result }
}    /// Batch-fetch artwork for tracks with turbo mode and true parallelism.
    /// Note: MusicBrainz is rate-limited to 1 req/sec, so turbo mode primarily helps with embedded artwork extraction.
    func batchFetchArtwork(
        tracks: [Track],
        repository: AnalysisRepository,
        libraryRoot: String? = nil,
        turboMode: Bool = false,
        progressHandler: ((MaintenanceProgressTracker.ProgressState) -> Void)? = nil
    ) async -> BatchResult {
        let tracker = MaintenanceProgressTracker(total: tracks.count, turboMode: turboMode, progressHandler: progressHandler)
        let resultCollector = BatchResultCollector()
        
        let limiter = BatchControl.limiter(turboMode: turboMode)
        let workerCount = BatchControl.workerCount(turboMode: turboMode)
        
        AppLogger.shared.info("Starting artwork batch: \(tracks.count) tracks, \(workerCount) workers (turbo: \(turboMode))", source: "Artwork")
        
        // Bridge Swift task cancellation to the tracker so the loop's
        // isCancelled gates actually fire when the user taps Cancel.
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for track in tracks {
                    if tracker.isCancelled {
                        AppLogger.shared.info("Artwork batch cancelled", source: "Artwork")
                        return
                    }

                    group.addTask {
                        await limiter.run {
                            await self.processSingleArtwork(
                                track: track,
                                repository: repository,
                                libraryRoot: libraryRoot,
                                tracker: tracker,
                                collector: resultCollector
                            )
                        }
                    }
                }
            }
        } onCancel: {
            tracker.cancel()
        }

        let result = await resultCollector.getResult()
        AppLogger.shared.info("Artwork batch complete: \(result.fetched) fetched, \(result.alreadyCached) cached, \(result.notFound) not found, \(result.failed) failed", source: "Artwork")
        return result
    }
    
    /// Process a single track artwork with progress tracking
    private func processSingleArtwork(
        track: Track,
        repository: AnalysisRepository,
        libraryRoot: String?,
        tracker: MaintenanceProgressTracker,
        collector: BatchResultCollector
    ) async {
        guard let trackId = track.id else {
            await collector.addFailed()
            tracker.updateProgress(
                trackId: 0,
                trackTitle: track.title,
                trackArtist: track.artist,
                savedToDb: false
            )
            return
        }

        // Already cached?
        if isCached(trackId: trackId) {
            await collector.addAlreadyCached()
            tracker.updateProgress(
                trackId: trackId,
                trackTitle: track.title,
                trackArtist: track.artist,
                savedToDb: false
            )
            return
        }

        // Resolve absolute track path (organizedPath is relative to libraryRoot)
        let filePath: String?
        if let organized = track.organizedPath {
            if let root = libraryRoot, !root.isEmpty {
                filePath = URL(fileURLWithPath: root).appendingPathComponent(organized).path
            } else {
                filePath = organized
            }
        } else {
            filePath = track.isLocal ? track.originalPath : nil
        }

        // 1. Try extracting embedded artwork from audio file
        if let resolvedPath = filePath, !resolvedPath.isEmpty {
            let trackURL = URL(fileURLWithPath: resolvedPath)
            if let embeddedData = await Self.extractEmbeddedArtwork(from: trackURL) {
                do {
                    try saveResized(data: embeddedData, trackId: trackId)
                    try await saveArtworkRecord(
                        trackId: trackId,
                        source: "embedded",
                        repository: repository
                    )
                    await collector.addFetched()
                    tracker.updateProgress(
                        trackId: trackId,
                        trackTitle: track.title,
                        trackArtist: track.artist,
                        savedToDb: true
                    )
                    AppLogger.shared.debug("Artwork [\(tracker.currentState.current)/\(tracker.currentState.total)] \(track.artist) - \(track.title) → embedded ✓", source: "Artwork")
                    return
                } catch {
                    // Fall through to MusicBrainz
                }
            }
        }

        // 2. Prefer the artwork URL supplied by SoundCloud.
        let remoteURLString: String?
        do {
            remoteURLString = try await repository.remoteArtworkURL(trackId: trackId)
        } catch {
            AppLogger.shared.warn(
                "Could not read retained artwork URL for track \(trackId): \(error.localizedDescription)",
                source: "Artwork"
            )
            remoteURLString = nil
        }

        if let remoteURLString,
           let remoteURL = URL(string: remoteURLString),
           remoteURL.scheme?.lowercased() == "https" {
            do {
                let (data, response) = try await session.data(from: remoteURL)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      !data.isEmpty else {
                    throw ArtworkFetchError.invalidProviderResponse
                }

                try saveResized(data: data, trackId: trackId)
                try await saveArtworkRecord(
                    trackId: trackId,
                    source: "soundcloud",
                    repository: repository
                )
                await collector.addFetched()
                tracker.updateProgress(
                    trackId: trackId,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: true
                )
                return
            } catch {
                AppLogger.shared.warn(
                    "SoundCloud artwork fetch failed for track \(trackId): \(error.localizedDescription)",
                    source: "Artwork"
                )
            }
        }

        // 3. Try MusicBrainz / Cover Art Archive
        do {
            if try await fetchFromMusicBrainz(track: track, repository: repository) {
                await collector.addFetched()
                tracker.updateProgress(
                    trackId: trackId,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: true
                )
            } else {
                await collector.addNotFound()
                tracker.updateProgress(
                    trackId: trackId,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: false
                )
            }

            // Rate limit: 1 req/sec to MusicBrainz
            try await Task.sleep(for: .seconds(1))
        } catch {
            await collector.addFailed()
            tracker.updateProgress(
                trackId: trackId,
                trackTitle: track.title,
                trackArtist: track.artist,
                savedToDb: false
            )
        }
    }

    // MARK: - Embedded Artwork

    /// Extract embedded cover art from an audio file using ffmpeg.
    ///
    /// Static and async so callers on @MainActor can call without blocking the UI.
    /// Runs in Task.detached to isolate the blocking Process.waitUntilExit() call.
    /// Returns nil silently if ffmpeg is not installed (D-07) or if no embedded art exists.
    /// Download artwork from a URL and embed it into an audio file.
    /// Uses ffmpeg to attach the image as cover art. Works for m4a, mp3, flac, ogg.
    static func embedArtwork(from imageURL: URL, into audioURL: URL) async -> Bool {
        await Task.detached(priority: .utility) { () -> Bool in
            let fm = FileManager.default
            let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do { try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true) } catch { return false }
            defer { try? fm.removeItem(at: tmpDir) }

            // 1. Download the image
            let coverPath = tmpDir.appendingPathComponent("cover.jpg")
            do {
                let (data, _) = try await URLSession.shared.data(from: imageURL)
                guard !data.isEmpty else { return false }
                try data.write(to: coverPath)
            } catch {
                return false
            }

            // 2. Embed via ffmpeg
            guard let ffmpeg = ProcessRunner.findExecutable("ffmpeg") else { return false }

            let outputPath = tmpDir.appendingPathComponent("out" + audioURL.pathExtension)
            let ext = audioURL.pathExtension.lowercased()

            var args: [String] = [
                "-i", audioURL.path,
                "-i", coverPath.path,
                "-map", "0:a",
                "-map", "1:0",
                "-c", "copy",
            ]
            if ext == "m4a" || ext == "aac" {
                args += ["-disposition:v:0", "attached_pic"]
            } else if ext == "mp3" {
                args += ["-id3v2_version", "3", "-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)"]
            } else {
                args += ["-disposition:v:0", "attached_pic"]
            }
            args += ["-y", outputPath.path]

            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0, fm.fileExists(atPath: outputPath.path) else { return false }

                // 3. Replace the original with the artwork-embedded version
                try fm.removeItem(at: audioURL)
                try fm.moveItem(at: outputPath, to: audioURL)
                return true
            } catch {
                return false
            }
        }.value
    }

    static func extractEmbeddedArtwork(from url: URL) async -> Data? {
        return await Task.detached(priority: .utility) { () -> Data? in
            guard let ffmpeg = ProcessRunner.findExecutable("ffmpeg") else {
                AppLogger.shared.warn("ffmpeg not found — artwork extraction disabled")
                return nil
            }

            let tmpOutput = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".jpg")

            // ffmpeg -i input -an -vcodec mjpeg -vframes 1 output.jpg
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = [
                "-i", url.path,
                "-an", "-vcodec", "mjpeg", "-vframes", "1",
                "-update", "1",
                "-y", tmpOutput.path
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: tmpOutput.path) {
                    let data = try Data(contentsOf: tmpOutput)
                    try? FileManager.default.removeItem(at: tmpOutput)
                    return data.isEmpty ? nil : data
                }
            } catch {
                AppLogger.shared.warn("ffmpeg extraction error: \(error.localizedDescription)")
            }

            try? FileManager.default.removeItem(at: tmpOutput)
            return nil
        }.value
    }

    // MARK: - MusicBrainz

    /// Search MusicBrainz for album art and download from Cover Art Archive.
    private func fetchFromMusicBrainz(track: Track, repository: AnalysisRepository) async throws -> Bool {
        guard let trackId = track.id else { return false }

        // Search for release group
        let query = "\(track.album) AND artist:\(track.artist)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let searchURL = URL(string: "\(Self.musicBrainzURL)/release-group?query=\(query)&fmt=json&limit=1")!

        var request = URLRequest(url: searchURL)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }

        let searchResult = try JSONDecoder().decode(MBReleaseGroupSearch.self, from: data)
        guard let releaseGroup = searchResult.releaseGroups?.first else { return false }

        // Fetch cover art from CAA
        for size in [1200, 500] {
            let caaURL = URL(string: "\(Self.coverArtURL)/release-group/\(releaseGroup.id)/front-\(size)")!
            var caaRequest = URLRequest(url: caaURL)
            caaRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

            do {
                let (imageData, imgResponse) = try await session.data(for: caaRequest)
                guard (imgResponse as? HTTPURLResponse)?.statusCode == 200 else { continue }

                try saveResized(data: imageData, trackId: trackId)
                try await saveArtworkRecord(
                    trackId: trackId,
                    source: "musicbrainz",
                    releaseGroupId: releaseGroup.id,
                    repository: repository
                )
                return true
            } catch {
                continue
            }
        }

        return false
    }

    // MARK: - Helpers

    /// Save artwork data resized to both small (≤256 px max side) and large (original).
    internal func saveResized(data: Data, trackId: Int64) throws {
        // Save the original as the "large" version
        let largePath = cachedPath(trackId: trackId, size: .large)
        try data.write(to: largePath)

        // Downscale the small version to max 256 px on its longest side.
        let smallPath = cachedPath(trackId: trackId, size: .small)
        if let downscaled = Self.downscaleJPEG(data: data, maxPixelSize: 256) {
            try downscaled.write(to: smallPath)
        } else {
            // Fallback: write the original data if downscaling fails
            try data.write(to: smallPath)
        }
    }

    /// Downscale image data to a JPEG with maxPixelSize on the longest side.
    /// Returns nil if the source data cannot be decoded.
    internal static func downscaleJPEG(data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    /// Save artwork metadata to the database.
    private func saveArtworkRecord(
        trackId: Int64,
        source: String,
        releaseGroupId: String? = nil,
        repository: AnalysisRepository
    ) async throws {
        let retainedRemoteURL = try await repository.remoteArtworkURL(trackId: trackId)
        let artwork = Artwork(
            trackId: trackId,
            artworkPath: cachedPath(trackId: trackId, size: .large).path,
            source: source,
            musicbrainzReleaseGroupId: releaseGroupId,
            resolution: "1200",
            fetchedAt: ISO8601DateFormatter().string(from: Date()),
            remoteUrl: retainedRemoteURL
        )
        try await repository.saveArtwork(artwork)
    }
}

private enum ArtworkFetchError: LocalizedError {
    case invalidProviderResponse

    var errorDescription: String? {
        "Provider returned no usable artwork"
    }
}

// MARK: - MusicBrainz Models

private struct MBReleaseGroupSearch: Codable {
    let releaseGroups: [MBReleaseGroup]?

    enum CodingKeys: String, CodingKey {
        case releaseGroups = "release-groups"
    }
}

private struct MBReleaseGroup: Codable {
    let id: String
    let title: String?
    let primaryType: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case primaryType = "primary-type"
    }
}
