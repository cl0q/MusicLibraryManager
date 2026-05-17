import Foundation
import CryptoKit

/// Shared AAC transcode cache with hardlink-based sync.
///
/// Mirrors the Rust `TranscodeCache`. Cache path: `{cache_dir}/{track_id}.m4a`.
/// Uses hardlinks on the same filesystem, copy fallback for cross-filesystem.
final class TranscodeCache: Sendable {
    private let cacheDir: URL
    private let transcodeService: TranscodeService

    init(cacheDir: URL) {
        self.cacheDir = cacheDir
        self.transcodeService = TranscodeService()
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Cache Path

    /// Deterministic cache path for a track (legacy, non-bitrate-suffixed).
    func cachePath(trackId: Int64) -> URL {
        cacheDir.appendingPathComponent("\(trackId).m4a")
    }

    /// Deterministic cache path for a track at a specific bitrate.
    /// Bitrate-suffixed so 248k and 320k cached versions coexist.
    /// Examples: `{trackId}_248.m4a`, `{trackId}_320.m4a`
    func cachePath(trackId: Int64, bitrateKbps: Int) -> URL {
        // Filename pattern: {trackId}_{bitrateKbps}.m4a  e.g. 42_248.m4a or 42_320.m4a
        cacheDir.appendingPathComponent("\(trackId)_\(bitrateKbps).m4a")
    }

    /// Whether a valid cache entry exists for a track (legacy, non-bitrate-suffixed).
    func isCached(trackId: Int64) -> Bool {
        let path = cachePath(trackId: trackId)
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        // Verify non-zero size
        let attrs = try? FileManager.default.attributesOfItem(atPath: path.path)
        let size = attrs?[.size] as? Int ?? 0
        return size > 0
    }

    // MARK: - Ensure Cached

    /// Ensure a track's AAC version exists in the cache at the given bitrate.
    /// If not cached, transcode the source file.
    ///
    /// - Parameter bitrateKbps: Target AAC bitrate in kbps. Defaults to 248 for back-compat.
    func ensureCached(track: Track, bitrateKbps: Int = 248) async throws -> URL? {
        guard let trackId = track.id else { return nil }
        let cached = cachePath(trackId: trackId, bitrateKbps: bitrateKbps)

        // Check bitrate-suffixed cache entry
        if FileManager.default.fileExists(atPath: cached.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: cached.path)
            let size = attrs?[.size] as? Int ?? 0
            if size > 0 { return cached }
        }

        guard let sourcePath = track.organizedPath ?? (track.isLocal ? track.originalPath : nil) else {
            return nil
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let result = try await transcodeService.transcode(input: sourceURL, outputDir: cacheDir, bitrateKbps: bitrateKbps)

        switch result {
        case .transcoded(let url):
            // Rename to bitrate-suffixed cache name
            if url != cached {
                try? FileManager.default.removeItem(at: cached)
                try FileManager.default.moveItem(at: url, to: cached)
            }
            return cached
        case .skipped:
            // Source is already lossy — copy to bitrate-suffixed cache path
            try? FileManager.default.removeItem(at: cached)
            try FileManager.default.copyItem(at: sourceURL, to: cached)
            return cached
        case .failed:
            return nil
        }
    }

    // MARK: - Link to Profile

    /// Link a cached file to a sync profile output folder.
    ///
    /// Uses hardlink first, falls back to copy for cross-filesystem.
    func linkToProfile(trackId: Int64, destinationPath: URL) throws {
        let cached = cachePath(trackId: trackId)
        guard FileManager.default.fileExists(atPath: cached.path) else {
            throw SyncError.cacheEntryMissing(trackId)
        }

        // Ensure parent directory exists
        try FileManager.default.createDirectory(
            at: destinationPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Remove existing file at destination
        try? FileManager.default.removeItem(at: destinationPath)

        do {
            // Try hardlink first (same filesystem, instant, no disk space)
            try FileManager.default.linkItem(at: cached, to: destinationPath)
        } catch {
            // Fallback to copy (cross-filesystem)
            try FileManager.default.copyItem(at: cached, to: destinationPath)
        }
    }

    // MARK: - Checksum

    /// Compute SHA256 checksum of a file (hex-encoded, 64 chars).
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let bufferSize = 64 * 1024

        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: bufferSize)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Build Profile Path

    /// Build the destination path for a track on a sync profile.
    ///
    /// Preserves library folder hierarchy. Falls back to `Artist/Album/Track.m4a`.
    /// SoundCloud tracks go to `03_Club/SoundCloud/title.m4a`.
    static func buildProfilePath(
        track: Track,
        libraryRoot: String,
        profileOutputFolder: String
    ) -> URL {
        let profileDir = URL(fileURLWithPath: profileOutputFolder)

        if let organizedPath = track.organizedPath {
            // Strip library root prefix
            var relativePath = organizedPath
            if relativePath.hasPrefix(libraryRoot) {
                relativePath = String(relativePath.dropFirst(libraryRoot.count))
                if relativePath.hasPrefix("/") {
                    relativePath = String(relativePath.dropFirst())
                }
            }

            // Change extension to .m4a
            let pathURL = URL(fileURLWithPath: relativePath)
            let m4aPath = pathURL.deletingPathExtension().appendingPathExtension("m4a")
            return profileDir.appendingPathComponent(m4aPath.relativePath)
        }

        // Fallback: Artist/Album/Title.m4a
        let artist = PathSanitizer.sanitizeComponent(track.artist)
        let album = PathSanitizer.sanitizeComponent(track.album)
        let title = PathSanitizer.sanitizeComponent(track.title)
        return profileDir
            .appendingPathComponent(artist)
            .appendingPathComponent(album)
            .appendingPathComponent("\(title).m4a")
    }
}

enum SyncError: LocalizedError {
    case cacheEntryMissing(Int64)
    case insufficientSpace(needed: Int64, available: Int64)
    case profileNotFound(Int64)

    var errorDescription: String? {
        switch self {
        case .cacheEntryMissing(let id): "Cache entry missing for track \(id)"
        case .insufficientSpace(let n, let a): "Insufficient space: need \(n / 1_000_000)MB, have \(a / 1_000_000)MB"
        case .profileNotFound(let id): "Sync profile \(id) not found"
        }
    }
}
