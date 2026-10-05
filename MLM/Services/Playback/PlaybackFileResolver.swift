import Foundation

/// Where a track's file is, checked once when it is about to play (a use-time check — never
/// per row or per scroll, UC-TABLE-20).
///
/// Fixes the old join bug (`PlaybackViewModel` ~165 at v0.9): an **absolute**
/// `organized_path` is used as it is; only a relative one is joined to the library folder.
///
/// "The disk is away" is decided like the file check does (`TrackAvailabilityReconciler`):
/// a `/Volumes/‹name›` path counts only while that volume is really mounted
/// (`MountObserver.isVolumeMounted`), and the library folder only while
/// `LibraryRootReachability` says it can be read — an empty leftover mount-point directory is
/// never "the files are gone". `lookupOffMain` runs it off the main actor, so a stalling disk
/// can't hang the app.
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

    /// The file-system questions a lookup asks (live: FileManager / mount checks).
    struct Probe: Sendable {
        var fileExists: @Sendable (String) -> Bool
        var isVolumeMounted: @Sendable (String) -> Bool
        var isLibraryRootReachable: @Sendable (String) -> Bool

        static let live = Probe(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isVolumeMounted: { MountObserver.isVolumeMounted($0) },
            isLibraryRootReachable: { LibraryRootReachability.isReachable($0) }
        )
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

    static func lookup(_ track: Track, libraryRoot: String?, probe: Probe) -> Lookup {
        for path in candidatePaths(track, libraryRoot: libraryRoot) where probe.fileExists(path) {
            return .file(URL(fileURLWithPath: path))
        }
        guard let organized = track.organizedPath, !organized.isEmpty else { return .noFile }
        // Why isn't it there? A disk that is away is never a missing file (DEC-014).
        if (organized as NSString).isAbsolutePath {
            if let volume = MountObserver.extractVolumePath(from: organized), !probe.isVolumeMounted(volume) {
                return .driveNotConnected(volumePath: volume)
            }
            return .missing
        }
        guard let libraryRoot, !libraryRoot.isEmpty else { return .missing }
        if !probe.isLibraryRootReachable(libraryRoot) {
            if let volume = MountObserver.extractVolumePath(from: libraryRoot), !probe.isVolumeMounted(volume) {
                return .driveNotConnected(volumePath: volume)
            }
            // The folder is gone on a mounted disk (`Not found` in Settings, IMP-024): it reads
            // as missing, but `recordMissingAtUse` refuses to flag anything while the folder
            // can't be read, and two misses in a row stop a queue advance (circuit breaker).
        }
        return .missing
    }

    /// `lookup` on a background thread.
    static func lookupOffMain(_ track: Track, libraryRoot: String?, probe: Probe) async -> Lookup {
        await Task.detached(priority: .userInitiated) {
            lookup(track, libraryRoot: libraryRoot, probe: probe)
        }.value
    }
}
