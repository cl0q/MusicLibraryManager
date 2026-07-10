import Foundation

/// Maintenance service that finds tracks whose `organized_path` no longer
/// points at an existing file on disk and rewrites the column from
/// `original_path` when that path is still resolvable inside the library
/// root.
///
/// Background: Phase 38 surfaced rows where `organized_path` was a stale
/// pre-import value (e.g. `"various artists/unknown album/[s] told em.m4a"`)
/// while `original_path` correctly pointed to the file inside
/// `/Volumes/Lexxar/Music/…`. The sync pipeline now silently falls back to
/// `original_path`, but the DB column itself stays wrong. This service is
/// the explicit "fix the column" path.
@Observable
final class LibraryRepairService {

    struct RepairResult {
        var inspected: Int = 0
        var alreadyValid: Int = 0
        var repaired: Int = 0
        /// Streaming-source rows whose stale organized_path was cleared
        /// (track demoted back to remote-only).
        var demotedToRemote: Int = 0
        var unrepairable: Int = 0
        /// `(trackId, reason)` for rows that could not be repaired.
        var failures: [(Int64, String)] = []
    }

    private let trackRepository: TrackRepository
    private let configRepository: ConfigRepository

    init(trackRepository: TrackRepository, configRepository: ConfigRepository) {
        self.trackRepository = trackRepository
        self.configRepository = configRepository
    }

    /// Scan every track that has a non-null `organized_path` and repair
    /// rows whose path no longer resolves to an existing file.
    ///
    /// Strategy:
    /// 1. If `organized_path` resolves via `TranscodeCache.resolveSourceURL`
    ///    to an existing file, the row is healthy — count and continue.
    /// 2. Otherwise check `original_path`. If that resolves to a file inside
    ///    `libraryRoot`, take the relative segment, sanitise it (PathSanitizer),
    ///    and rewrite `organized_path` to that new value.
    /// 3. If neither resolves, log a warning and count as unrepairable.
    func repairStaleOrganizedPaths() async throws -> RepairResult {
        let libraryRoot = try await configRepository.getLibraryRoot() ?? ""
        guard !libraryRoot.isEmpty else {
            AppLogger.shared.warn(
                "LibraryRepair: library root not configured — aborting",
                source: "Repair"
            )
            return RepairResult()
        }

        let normalizedRoot = libraryRoot.hasSuffix("/")
            ? String(libraryRoot.dropLast())
            : libraryRoot

        let tracks = try await trackRepository.fetchLocalTracks()
        var result = RepairResult()
        result.inspected = tracks.count

        AppLogger.shared.info(
            "LibraryRepair: scanning \(tracks.count) tracks with organized_path",
            source: "Repair"
        )

        // Build a cache of all files in libraryRoot for fast lookup in case of renamed directories
        var fileCache: [String: String] = [:]
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: normalizedRoot)
        AppLogger.shared.info("LibraryRepair: building file cache for fast lookup...", source: "Repair")
        if let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: nil
        ) {
            for case let fileURL as URL in enumerator {
                let path = fileURL.path
                if path.hasPrefix(normalizedRoot + "/") {
                    let relative = String(path.dropFirst(normalizedRoot.count + 1))
                    let filename = fileURL.lastPathComponent.lowercased()
                    fileCache[filename] = relative
                }
            }
        }
        AppLogger.shared.info("LibraryRepair: indexed \(fileCache.count) files on disk", source: "Repair")

        for track in tracks {
            guard let trackId = track.id, let organizedPath = track.organizedPath else {
                continue
            }

            // Step 1 — current organized_path resolves AND is not a known
            // internal staging path. `.mlm_staging/...` / `.ln/...` entries
            // are Tauri-era leftovers — even if the file happens to exist
            // we want to rewrite them to the proper library-relative path
            // so the M3U8 generator stops emitting them.
            let pathIsStale = TranscodeCache.isStaleOrganizedPath(organizedPath)
            if !pathIsStale,
               TranscodeCache.resolveSourceURL(sourcePath: organizedPath, libraryRoot: normalizedRoot) != nil {
                result.alreadyValid += 1
                continue
            }

            // Step 2 — original_path resolvable inside libraryRoot?
            let originalPath = track.originalPath
            guard
                let resolved = TranscodeCache.resolveSourceURL(
                    sourcePath: originalPath,
                    libraryRoot: normalizedRoot
                )
            else {
                // Step 2.5 — Check if the file exists elsewhere in the library due to a directory rename
                let filename = URL(fileURLWithPath: organizedPath).lastPathComponent
                if let relativeNewPath = fileCache[filename.lowercased()] {
                    let absoluteNewPath = normalizedRoot + "/" + relativeNewPath
                    do {
                        try await trackRepository.setPathsOnly(
                            trackId: trackId,
                            organizedPath: relativeNewPath,
                            originalPath: absoluteNewPath
                        )
                        result.repaired += 1
                        AppLogger.shared.info(
                            "LibraryRepair: track \(trackId) (\(filename)) resolved and repaired via directory-rename to \(relativeNewPath)",
                            source: "Repair"
                        )
                        continue
                    } catch {
                        AppLogger.shared.error(
                            "LibraryRepair: failed to update paths for track \(trackId): \(error.localizedDescription)",
                            source: "Repair"
                        )
                    }
                }

                // If original_path is a streaming URL there was never a
                // local file — the stale organized_path is just leftover
                // download-pipeline metadata. Demote the row back to
                // remote-only instead of treating it as a failure.
                if Self.isStreamingSource(originalPath) {
                    do {
                        try await trackRepository.demoteToRemote(trackId: trackId)
                        result.demotedToRemote += 1
                    } catch {
                        result.unrepairable += 1
                        result.failures.append((trackId, "Demote failed: \(error.localizedDescription)"))
                    }
                    continue
                }
                AppLogger.shared.warn(
                    "LibraryRepair: track \(trackId) unrepairable — neither organized_path (\(organizedPath)) nor original_path (\(originalPath)) resolve",
                    source: "Repair"
                )
                result.unrepairable += 1
                result.failures.append((trackId, "Beide Pfade nicht auffindbar"))
                continue
            }

            let resolvedPath = resolved.path
            guard resolvedPath.hasPrefix(normalizedRoot + "/") else {
                AppLogger.shared.warn(
                    "LibraryRepair: track \(trackId) skipped — original_path resolved outside libraryRoot (\(resolvedPath))",
                    source: "Repair"
                )
                result.unrepairable += 1
                result.failures.append((trackId, "Pfad liegt außerhalb der Library"))
                continue
            }

            let newOrganizedPath = String(resolvedPath.dropFirst(normalizedRoot.count + 1))

            do {
                try await trackRepository.setOrganizedPathOnly(
                    trackId: trackId,
                    organizedPath: newOrganizedPath
                )
                result.repaired += 1
                // Per-track repair logs spammed the Logs tab (one line per
                // row across thousands of tracks). Roll up into a single
                // progress line every 500 rows instead.
                if result.repaired % 500 == 0 {
                    AppLogger.shared.info(
                        "LibraryRepair: \(result.repaired) tracks repaired so far…",
                        source: "Repair"
                    )
                }
            } catch {
                AppLogger.shared.error(
                    "LibraryRepair: failed to write track \(trackId): \(error.localizedDescription)",
                    source: "Repair"
                )
                result.unrepairable += 1
                result.failures.append((trackId, error.localizedDescription))
            }
        }

        AppLogger.shared.info(
            "LibraryRepair: done — inspected \(result.inspected), already-valid \(result.alreadyValid), repaired \(result.repaired), demoted-to-remote \(result.demotedToRemote), unrepairable \(result.unrepairable)",
            source: "Repair"
        )
        return result
    }

    /// True if the path looks like a streaming-service identifier (http,
    /// soundcloud://, spotify:track:, youtube:, etc) rather than a real
    /// local file. Such tracks were never downloaded, so their stale
    /// organized_path is meaningless and should be cleared.
    private static func isStreamingSource(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return true
        }
        for scheme in ["soundcloud:", "spotify:", "youtube:", "ytmusic:", "applemusic:", "apple-music:"] {
            if lower.hasPrefix(scheme) {
                return true
            }
        }
        return false
    }

    /// Re-read audio tags from all local files and update their metadata in the database.
    func rescanMetadata(
        turboMode: Bool = false,
        progressHandler: ((MaintenanceProgressTracker.ProgressState) -> Void)? = nil
    ) async throws -> (succeeded: Int, failed: Int) {
        let libraryRoot = try await configRepository.getLibraryRoot() ?? ""
        guard !libraryRoot.isEmpty else {
            AppLogger.shared.warn(
                "LibraryRepair: library root not configured — aborting",
                source: "Repair"
            )
            return (0, 0)
        }

        let normalizedRoot = libraryRoot.hasSuffix("/")
            ? String(libraryRoot.dropLast())
            : libraryRoot

        let tracks = try await trackRepository.fetchLocalTracks()
        
        let tracker = MaintenanceProgressTracker(
            total: tracks.count,
            turboMode: turboMode,
            progressHandler: progressHandler
        )

        var succeeded = 0
        var failed = 0

        AppLogger.shared.info(
            "Rescan Metadata: scanning \(tracks.count) tracks...",
            source: "Repair"
        )

        for (index, var track) in tracks.enumerated() {
            guard !tracker.isCancelled else { break }

            // Resolve track file
            guard let resolvedURL = resolveLocalURL(for: track, normalizedRoot: normalizedRoot) else {
                tracker.updateProgress(
                    current: index + 1,
                    trackId: track.id ?? 0,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: false
                )
                failed += 1
                continue
            }

            do {
                // Extract metadata
                let metadata = try await MetadataExtractor.extract(from: resolvedURL)

                // Update track fields
                track.artist = metadata.artist
                track.albumArtist = metadata.albumArtist
                track.album = metadata.album
                track.title = metadata.title
                track.genre = metadata.genre
                track.year = metadata.year
                track.bitrate = metadata.bitrate
                track.duration = metadata.duration
                track.format = metadata.format

                // Save to database
                try await trackRepository.update(track)

                tracker.updateProgress(
                    current: index + 1,
                    trackId: track.id ?? 0,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: true
                )
                succeeded += 1
            } catch {
                AppLogger.shared.error(
                    "Rescan Metadata: Error for \(track.artist) - \(track.title) [\(resolvedURL.lastPathComponent)]: \(error.localizedDescription)",
                    source: "Repair"
                )
                tracker.updateProgress(
                    current: index + 1,
                    trackId: track.id ?? 0,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: false
                )
                failed += 1
            }
        }

        return (succeeded, failed)
    }

    private func resolveLocalURL(for track: Track, normalizedRoot: String) -> URL? {
        if let organized = track.organizedPath, !organized.isEmpty {
            if let resolved = TranscodeCache.resolveSourceURL(sourcePath: organized, libraryRoot: normalizedRoot) {
                return resolved
            }
        }
        let originalPath = track.originalPath
        if let resolved = TranscodeCache.resolveSourceURL(sourcePath: originalPath, libraryRoot: normalizedRoot) {
            return resolved
        }
        return nil
    }
}

