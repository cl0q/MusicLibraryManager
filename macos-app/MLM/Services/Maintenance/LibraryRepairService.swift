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
                AppLogger.shared.info(
                    "LibraryRepair: track \(trackId) repaired — \(organizedPath) → \(newOrganizedPath)",
                    source: "Repair"
                )
                result.repaired += 1
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
            "LibraryRepair: done — inspected \(result.inspected), already-valid \(result.alreadyValid), repaired \(result.repaired), unrepairable \(result.unrepairable)",
            source: "Repair"
        )
        return result
    }
}
