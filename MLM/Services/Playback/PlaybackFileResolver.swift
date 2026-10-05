import Foundation

/// Where a track's file is, checked once when it is about to play (a use-time check — never
/// per row or per scroll, UC-TABLE-20).
///
/// Fixes the old join bug (`PlaybackViewModel` ~165 at v0.9): an **absolute**
/// `organized_path` is used as it is; only a relative one is joined to the library folder.
/// Before, root + "/Volumes/…" produced a path that never existed, so such rows only played
/// through the original-path fallback.
enum PlaybackFileResolver {
    enum Lookup: Equatable, Sendable {
        case file(URL)
        /// The stored path doesn't exist although its folder / disk can be read.
        case missing
        /// The disk holding the file (or the library folder) can't be reached; `volumePath` is
        /// `/Volumes/‹name›` when known.
        case driveNotConnected(volumePath: String?)
        /// The track has no file (not downloaded).
        case noFile
    }

    /// Paths to try, in order: the organized path (absolute as is, relative inside the library
    /// folder), then an absolute original path (imports that were never organized).
    static func candidatePaths(_ track: Track, libraryRoot: String?) -> [String] {
        var paths: [String] = []
        if let organized = track.organizedPath, !organized.isEmpty {
            if (organized as NSString).isAbsolutePath {
                paths.append(organized)
            } else if let libraryRoot, !libraryRoot.isEmpty {
                paths.append(URL(fileURLWithPath: libraryRoot).appendingPathComponent(organized).path)
            }
        }
        let raw = track.originalPath
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let expanded = (raw as NSString).expandingTildeInPath
            if !paths.contains(expanded) { paths.append(expanded) }
        }
        return paths
    }

    static func lookup(_ track: Track, libraryRoot: String?, fileExists: (String) -> Bool) -> Lookup {
        for path in candidatePaths(track, libraryRoot: libraryRoot) where fileExists(path) {
            return .file(URL(fileURLWithPath: path))
        }
        guard let organized = track.organizedPath, !organized.isEmpty else { return .noFile }
        // Why isn't it there? A disk that is away is never a missing file (DEC-014).
        if (organized as NSString).isAbsolutePath {
            if let volume = MountObserver.extractVolumePath(from: organized), !fileExists(volume) {
                return .driveNotConnected(volumePath: volume)
            }
            return .missing
        }
        guard let libraryRoot, !libraryRoot.isEmpty else { return .missing }
        // The library folder's disk is away. (A missing folder on a mounted disk or on this
        // Mac is `Not found` in Settings, IMP-024 — for the track that is a missing file, and
        // `recordMissingAtUse` refuses to flag it while the folder can't be read.)
        if !fileExists(libraryRoot), let volume = MountObserver.extractVolumePath(from: libraryRoot), !fileExists(volume) {
            return .driveNotConnected(volumePath: volume)
        }
        return .missing
    }
}
