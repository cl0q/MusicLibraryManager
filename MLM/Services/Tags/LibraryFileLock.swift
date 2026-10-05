import Foundation

/// One exclusive lock per library file path, process-wide (W2-E review S9). Everything in MLM
/// that rewrites a library file should hold it while it reads, rewrites and swaps the file, so
/// two rewriters never interleave on one path.
///
/// Today only `TrackTagWriter` takes it. Other code that rewrites or moves library files (to be
/// routed through it by its owners): `ArtworkService.embedArtwork` (Services/Analysis, cover
/// embedding), `DownloadOrchestrator.embedArtworkIfNeeded` and the orchestrator's move of a
/// finished download into the library folder (also the Download Again replace),
/// `SoundCloudDownloader` / `SquidWtfClient` / `DownloadQueue` moves, `TranscodeService` when
/// its output lands in the library, `OrganizedPathMigrationService` (moves) and Remove from
/// Library (Trash). `SyncService.embedMlmUuid` / `TranscodeCache` rewrite device or cache
/// copies, not library files.
actor LibraryFileLock {
    static let shared = LibraryFileLock()

    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Wait until `path` is free and take it.
    func acquire(_ path: String) async {
        guard held.contains(path) else {
            held.insert(path)
            return
        }
        await withCheckedContinuation { waiters[path, default: []].append($0) }
    }

    /// Hand `path` to the next waiter, or free it.
    func release(_ path: String) {
        if var queue = waiters[path], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[path] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            held.remove(path)
        }
    }

    func isHeld(_ path: String) -> Bool { held.contains(path) }
}
