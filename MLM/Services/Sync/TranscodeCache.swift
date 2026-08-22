import Foundation
import CryptoKit

/// Shared AAC transcode cache with hardlink-based sync.
///
/// Mirrors the Rust `TranscodeCache`. Cache path: `{cache_dir}/{track_id}.m4a`.
/// Uses hardlinks on the same filesystem, copy fallback for cross-filesystem.
final class TranscodeCache: @unchecked Sendable {
    private var _cacheDir: URL
    private let lock = NSLock()
    private let transcodeService: TranscodeService

    var cacheDir: URL {
        lock.lock()
        defer { lock.unlock() }
        return _cacheDir
    }

    init(cacheDir: URL) {
        self._cacheDir = cacheDir
        self.transcodeService = TranscodeService()
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Thread-safely update the active cache directory.
    func updateCacheDir(to newDir: URL) {
        lock.lock()
        self._cacheDir = newDir
        lock.unlock()
        try? FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
    }

    // MARK: - Cache Path

    /// Deterministic cache path for a track (legacy, non-bitrate-suffixed).
    func cachePath(trackId: Int64) -> URL {
        cacheDir.appendingPathComponent("\(trackId).m4a")
    }

    /// Deterministic cache path for a track at a specific bitrate.
    /// Bitrate-suffixed so 248k and 320k cached versions coexist.
    /// Examples: `{trackId}_248.m4a`, `{trackId}_320.m4a`
    /// When `normalized` is true a `_norm` marker keeps loudness-normalized
    /// exports from colliding with the plain transcode of the same track.
    func cachePath(trackId: Int64, bitrateKbps: Int, normalized: Bool = false) -> URL {
        // Filename pattern: {trackId}_{bitrateKbps}[_norm].m4a  e.g. 42_248.m4a or 42_248_norm.m4a
        let suffix = normalized ? "_norm" : ""
        return cacheDir.appendingPathComponent("\(trackId)_\(bitrateKbps)\(suffix).m4a")
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
    /// - Parameter normalizationGainDB: When non-nil, a loudness gain (dB) is
    ///   baked into the exported audio and the cache entry is `_norm`-suffixed.
    func ensureCached(track: Track, bitrateKbps: Int = 248, libraryRoot: String? = nil, normalizationGainDB: Double? = nil) async throws -> URL? {
        guard let trackId = track.id else {
            AppLogger.shared.warn("ensureCached: track has no id", source: "Sync")
            return nil
        }
        let normalized = normalizationGainDB != nil
        let cached = cachePath(trackId: trackId, bitrateKbps: bitrateKbps, normalized: normalized)

        // Check bitrate-suffixed cache entry
        if FileManager.default.fileExists(atPath: cached.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: cached.path)
            let size = attrs?[.size] as? Int ?? 0
            if size > 0 {
                // Self-healing: verify the cached .m4a file is a valid AAC/MP4 container, not a renamed MP3/FLAC
                if await verifyCacheCodec(cached) {
                    return cached
                } else {
                    AppLogger.shared.warn(
                        "ensureCached: cached file \(cached.lastPathComponent) is not a valid AAC file (possibly stale/fake .m4a from old version); deleting and re-transcoding",
                        source: "Sync"
                    )
                    try? FileManager.default.removeItem(at: cached)
                }
            }
        }

        // Candidate paths to try in order: organized_path (relative to libraryRoot, common case)
        // then original_path (absolute on-disk path, fallback for stale/wrong organized_path).
        var candidatePaths: [String] = []
        if let op = track.organizedPath { candidatePaths.append(op) }
        if track.isLocal { candidatePaths.append(track.originalPath) }

        if candidatePaths.isEmpty {
            AppLogger.shared.error(
                "ensureCached: track \(trackId) has no source path (organizedPath=nil, isLocal=\(track.isLocal), originalPath=\(track.originalPath))",
                source: "Sync"
            )
            return nil
        }

        var sourceURL: URL?
        for candidate in candidatePaths {
            if let url = Self.resolveSourceURL(sourcePath: candidate, libraryRoot: libraryRoot) {
                sourceURL = url
                if candidate != candidatePaths.first {
                    AppLogger.shared.warn(
                        "ensureCached: track \(trackId) organized_path stale; resolved via fallback \(candidate)",
                        source: "Sync"
                    )
                }
                break
            }
        }

        guard let sourceURL else {
            AppLogger.shared.error(
                "ensureCached: source file missing for track \(trackId): tried \(candidatePaths) with libraryRoot='\(libraryRoot ?? "<nil>")'",
                source: "Sync"
            )
            return nil
        }

        let targetName = "\(trackId)_\(bitrateKbps)\(normalized ? "_norm" : "").m4a"
        let result = try await transcodeService.transcode(
            input: sourceURL,
            outputDir: cacheDir,
            outputName: targetName,
            bitrateKbps: bitrateKbps,
            sourceFormat: track.format,
            sourceBitrate: track.bitrate,
            normalizationGainDB: normalizationGainDB
        )

        switch result {
        case .transcoded(let url):
            // Rename to bitrate-suffixed cache name
            if url != cached {
                try? FileManager.default.removeItem(at: cached)
                try FileManager.default.moveItem(at: url, to: cached)
            }
            return cached
        case .skipped(let reason):
            // Source is already lossy — copy to bitrate-suffixed cache path
            AppLogger.shared.info(
                "ensureCached: track \(trackId) skipped transcode (\(reason)); copying source to cache",
                source: "Sync"
            )
            try? FileManager.default.removeItem(at: cached)
            try FileManager.default.copyItem(at: sourceURL, to: cached)
            return cached
        case .failed(let msg):
            AppLogger.shared.error(
                "ensureCached: transcode failed for track \(trackId) (\(sourceURL.lastPathComponent)) at \(bitrateKbps)k: \(msg)",
                source: "Sync"
            )
            return nil
        }
    }

    /// Verify that a cached .m4a file is a valid AAC/MP4/M4A file and not a renamed MP3/FLAC file.
    func verifyCacheCodec(_ url: URL) async -> Bool {
        guard let ffmpeg = ProcessRunner.findExecutable("ffmpeg") else { return true } // Fallback to true if ffmpeg unavailable
        let ffprobe = ffmpeg.replacingOccurrences(of: "ffmpeg", with: "ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe) else { return true }
        
        do {
            let result = try await ProcessRunner.run(
                ffprobe,
                arguments: [
                    "-v", "quiet",
                    "-show_entries", "stream=codec_name",
                    "-of", "json",
                    url.path
                ]
            )
            if result.isSuccess, let data = result.stdout.data(using: .utf8) {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let streams = json?["streams"] as? [[String: Any]],
                   let stream = streams.first {
                    let codec = (stream["codec_name"] as? String ?? "").lowercased()
                    // Cached files always end in .m4a and must be AAC/MP4
                    return codec.contains("aac") || codec.contains("mp4")
                }
            }
        } catch {}
        return false
    }

    // MARK: - Path Resolution

    /// Resolve a DB source path (organizedPath/originalPath) to a real on-disk URL.
    ///
    /// Handles three cases observed in the wild:
    /// 1. Absolute path that already includes libraryRoot (`/Volumes/Lexxar/Music/…`)
    /// 2. Relative path without leading slash (`01_SoundCloud/foo.m4a`)
    /// 3. Relative path that erroneously starts with a slash (`/01_SoundCloud/foo.m4a`)
    ///
    /// Returns nil only if no candidate resolves to an existing file.
    static func resolveSourceURL(sourcePath: String, libraryRoot: String?) -> URL? {
        let fm = FileManager.default

        // Candidate 1: as-is (handles already-absolute paths)
        if fm.fileExists(atPath: sourcePath) {
            return URL(fileURLWithPath: sourcePath)
        }

        // Candidates 2 + 3: prepend libraryRoot
        if let root = libraryRoot, !root.isEmpty {
            // Normalize: strip trailing slash on root, ensure leading slash on path
            let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
            let normalizedPath = sourcePath.hasPrefix("/") ? sourcePath : "/" + sourcePath
            let candidate = normalizedRoot + normalizedPath
            if fm.fileExists(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }

    // MARK: - Link to Profile

    /// Link a cached file to a sync profile output folder.
    ///
    /// Uses hardlink first, falls back to copy for cross-filesystem.
    /// Looks up the bitrate-suffixed cache entry; falls back to the legacy
    /// non-suffixed path for back-compat with pre-Phase-38 cache entries.
    func linkToProfile(trackId: Int64, bitrateKbps: Int, destinationPath: URL, normalized: Bool = false) throws {
        let cached: URL
        let suffixed = cachePath(trackId: trackId, bitrateKbps: bitrateKbps, normalized: normalized)
        let legacy = cachePath(trackId: trackId)
        if FileManager.default.fileExists(atPath: suffixed.path) {
            cached = suffixed
        } else if FileManager.default.fileExists(atPath: legacy.path) {
            cached = legacy
        } else {
            AppLogger.shared.error(
                "linkToProfile: no cache entry for track \(trackId) at \(bitrateKbps)k (looked at \(suffixed.lastPathComponent) and \(legacy.lastPathComponent))",
                source: "Sync"
            )
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
            // Fallback to copy (cross-filesystem) — common for iPod/FAT32 destinations
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
    /// Preserves library folder hierarchy. Falls back to `Artist/Album/Track.m4a`
    /// when `organized_path` is missing or looks like a stale internal path
    /// (Tauri-era `.mlm_staging/`, `.ln/` staging dirs, or dot-prefixed
    /// hidden folders). Such paths would otherwise leak into the
    /// destination layout and the generated M3U8 playlists.
    static func buildProfilePath(
        track: Track,
        libraryRoot: String,
        profileOutputFolder: String,
        transcodeMode: TranscodeMode = .aac248
    ) -> URL {
        let profileDir = URL(fileURLWithPath: profileOutputFolder)

        if let organizedPath = track.organizedPath,
           !Self.isStaleOrganizedPath(organizedPath) {
            // Strip library root prefix
            var relativePath = organizedPath
            if relativePath.hasPrefix(libraryRoot) {
                relativePath = String(relativePath.dropFirst(libraryRoot.count))
                if relativePath.hasPrefix("/") {
                    relativePath = String(relativePath.dropFirst())
                }
            }

            // Split relativePath into components
            let components = relativePath.split(separator: "/").map(String.init)
            if !components.isEmpty {
                // Sanitize all directory components
                let sanitizedDirs = components.dropLast().map { PathSanitizer.sanitizeComponent($0) }
                
                // Extract and sanitize filename stem
                let filename = components.last!
                var stem = filename
                
                // Extract original extension
                var originalExtension = "m4a"
                if let dotIndex = filename.lastIndex(of: ".") {
                    originalExtension = String(filename[filename.index(after: dotIndex)...]).lowercased()
                }
                
                // Peel extensions (up to 2 levels e.g. .mp3.m4a -> .m4a)
                var extensionsPeeled = 0
                while let dotIndex = stem.lastIndex(of: "."), extensionsPeeled < 2 {
                    let ext = String(stem[stem.index(after: dotIndex)...]).lowercased()
                    if extensionsPeeled == 0 || Self.codecExtensions.contains(ext) {
                        stem = String(stem[..<dotIndex])
                        extensionsPeeled += 1
                    } else {
                        break
                    }
                }
                
                let sanitizedStem = PathSanitizer.sanitizeComponent(stem)
                let finalExtension = transcodeMode == .keepOriginals ? originalExtension : "m4a"
                let sanitizedFilename = "\(sanitizedStem).\(finalExtension)"
                
                var finalURL = profileDir
                for dir in sanitizedDirs {
                    finalURL = finalURL.appendingPathComponent(dir)
                }
                return finalURL.appendingPathComponent(sanitizedFilename)
            }
        }

        // SoundCloud routing parity check (Phase 38 Plan parity)
        let ext = transcodeMode == .keepOriginals ? (track.format.isEmpty ? "m4a" : track.format.lowercased()) : "m4a"
        if track.originalPath.lowercased().contains("soundcloud.com") {
            let title = PathSanitizer.sanitizeComponent(track.title)
            return profileDir
                .appendingPathComponent("03_Club")
                .appendingPathComponent("SoundCloud")
                .appendingPathComponent("\(title).\(ext)")
        }

        // Fallback: Artist/Album/Title.ext
        let artist = PathSanitizer.sanitizeComponent(track.artist)
        let album = PathSanitizer.sanitizeComponent(track.album)
        let title = PathSanitizer.sanitizeComponent(track.title)
        return profileDir
            .appendingPathComponent(artist)
            .appendingPathComponent(album)
            .appendingPathComponent("\(title).\(ext)")
    }

    /// Library-relative paths that are internal staging dirs from earlier
    /// pipeline iterations. A row with one of these prefixes should be
    /// treated as if it had no organized_path at all.
    private static let stalePathPrefixes: [String] = [
        ".mlm_staging/",
        ".ln/",
    ]

    /// Audio extensions we treat as codec hints when collapsing a legacy
    /// "Stem.mp3.m4a" -> "Stem.m4a".
    private static let codecExtensions: Set<String> = [
        "mp3", "flac", "wav", "ogg", "opus", "aac", "alac", "m4a", "wma"
    ]

    /// Decide whether `organized_path` points at an internal staging
    /// location we should never write back into a sync destination or a
    /// generated M3U8 entry.
    static func isStaleOrganizedPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains(".mlm_staging/") || lower.contains(".ln/")
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
