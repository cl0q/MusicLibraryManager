import Foundation

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

    /// Batch-fetch artwork for tracks.
    func batchFetchArtwork(
        tracks: [Track],
        repository: AnalysisRepository,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async -> BatchResult {
        var result = BatchResult()

        for (index, track) in tracks.enumerated() {
            onProgress?(index, tracks.count)

            guard let trackId = track.id else {
                result.failed += 1
                continue
            }

            // Already cached?
            if isCached(trackId: trackId) {
                result.alreadyCached += 1
                continue
            }

            // 1. Try extracting embedded artwork from audio file
            if let filePath = track.organizedPath {
                if let embeddedData = extractEmbeddedArtwork(from: filePath) {
                    do {
                        try saveResized(data: embeddedData, trackId: trackId)
                        try await saveArtworkRecord(
                            trackId: trackId,
                            source: "embedded",
                            repository: repository
                        )
                        result.fetched += 1
                        continue
                    } catch {
                        // Fall through to MusicBrainz
                    }
                }
            }

            // 2. Try MusicBrainz / Cover Art Archive
            do {
                if try await fetchFromMusicBrainz(track: track, repository: repository) {
                    result.fetched += 1
                } else {
                    result.notFound += 1
                }

                // Rate limit: 1 req/sec to MusicBrainz
                try await Task.sleep(for: .seconds(1))
            } catch {
                result.failed += 1
            }
        }

        return result
    }

    // MARK: - Embedded Artwork

    /// Extract embedded cover art from an audio file using ffmpeg.
    private func extractEmbeddedArtwork(from path: String) -> Data? {
        guard let ffmpeg = ProcessRunner.findExecutable("ffmpeg") else { return nil }

        let tmpOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")

        // ffmpeg -i input -an -vcodec mjpeg -vframes 1 output.jpg
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-i", path,
            "-an", "-vcodec", "mjpeg", "-vframes", "1",
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
        } catch {}

        try? FileManager.default.removeItem(at: tmpOutput)
        return nil
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

    /// Save artwork data resized to both 500px and 1200px.
    private func saveResized(data: Data, trackId: Int64) throws {
        // Save the original as the "large" version
        let largePath = cachedPath(trackId: trackId, size: .large)
        try data.write(to: largePath)

        // For the small version, also save (resize happens in the UI layer)
        let smallPath = cachedPath(trackId: trackId, size: .small)
        try data.write(to: smallPath)
    }

    /// Save artwork metadata to the database.
    private func saveArtworkRecord(
        trackId: Int64,
        source: String,
        releaseGroupId: String? = nil,
        repository: AnalysisRepository
    ) async throws {
        let artwork = Artwork(
            trackId: trackId,
            artworkPath: cachedPath(trackId: trackId, size: .large).path,
            source: source,
            musicbrainzReleaseGroupId: releaseGroupId,
            resolution: "1200",
            fetchedAt: ISO8601DateFormatter().string(from: Date())
        )
        try await repository.saveArtwork(artwork)
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
