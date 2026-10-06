import Foundation

/// One exclusive lock per library file path, process-wide (W2-E review S9). Everything in MLM
/// that rewrites a library file should hold it while it reads, rewrites and swaps the file, so
/// two rewriters never interleave on one path.
///
/// Adopters (W5-F1), each through `holding(_:_:)` so the lock is released on every exit:
/// `TrackTagWriter`, `ArtworkService.embedArtwork` (the audio file), `DownloadOrchestrator.placeFinal`
/// (the destination, incl. the Download Again replace), `TranscodeService.transcode` (its output
/// path), Remove from Library (`TrackLibraryRemoval`), Review's Trash mode and put back
/// (`ReviewConsequences`). Not adopters, on purpose: the
/// downloaders (`SoundCloudDownloader`, `DABClient`, `SquidWtfClient`) write into a per-download
/// staging folder, `DownloadQueue` writes its own JSON, `OrganizedPathMigrationService` only
/// edits database rows, and `SyncService.embedMlmUuid` / `TranscodeCache` rewrite device or
/// cache copies, not library files.
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

    /// How many callers wait for `path` (tests wait for this instead of sleeping).
    func waiterCount(_ path: String) -> Int { waiters[path]?.count ?? 0 }

    /// The key a file is locked under: standardised and symlink-resolved, the same spelling
    /// `TrackTagWriter` uses, so two writers reaching one file by two paths still meet.
    nonisolated static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Run `body` holding the lock on `url` (waiting while another writer has it) and release
    /// it afterwards, also when `body` throws.
    nonisolated static func holding<T>(
        _ url: URL,
        in lock: LibraryFileLock = .shared,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let path = key(for: url)
        await lock.acquire(path)
        do {
            let result = try await body()
            await lock.release(path)
            return result
        } catch {
            await lock.release(path)
            throw error
        }
    }
}
