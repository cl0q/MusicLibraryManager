import Foundation

/// One exclusive lock per library file path, process-wide (W2-E review S9). Everything in MLM
/// that rewrites a library file should hold it while it reads, rewrites and swaps the file, so
/// two rewriters never interleave on one path.
///
/// Today only `TrackTagWriter` takes it. Other rewriters of library files found in the code
/// (to be routed through it by their owners): `ArtworkService.embedArtwork` (cover embedding),
/// the download pipeline's replace of an existing file (Download Again / `markAsDownloaded`),
/// `TranscodeService` when it writes next to a library file, `OrganizedPathMigrationService`
/// (moves). `SyncService.embedMlmUuid` rewrites device copies, not library files.
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
