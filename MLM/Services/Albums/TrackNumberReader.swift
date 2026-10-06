import Foundation
import GRDB

/// `Read Track Numbers` (W4-1, IMP-067): fills `album_tracks.track_number` / `disc` from the
/// files' `track` and `disc` tags for the tracks of albums, and — per album, as soon as every
/// member has a number — re-sorts the album's positions by (disc, number).
///
/// Resumable by construction: it only looks at rows whose number is still unset, and writes
/// each album's numbers when that album is done (or the job is cancelled), so a stop or a
/// relaunch loses at most the album in hand. Reads files, so it waits for the library drive
/// (the same rule as the other file jobs: the menu item is disabled while the drive is away,
/// and a run that loses the drive pauses until it is back instead of marking anything).
struct TrackNumberReader: Sendable {
    /// What a run did.
    struct Outcome: Equatable, Sendable {
        /// Tracks whose number was written.
        var read = 0
        /// Tracks whose file has no track number tag (they stay unnumbered).
        var withoutNumber = 0
        /// Tracks whose file could not be found or read.
        var unreadable = 0
        /// Albums whose positions were re-sorted because every track now has a number.
        var albumsSorted = 0
        var cancelled = false
    }

    private struct Pending: Sendable {
        let albumID: Int64
        let trackID: Int64
        let disc: Int
        let path: String
        let title: String
        let artist: String
    }

    let database: any DatabaseWriter
    /// The library folder (`organized_path` is relative to it).
    var libraryRoot: String?
    /// Reads the numbers of one file.
    var extract: @Sendable (URL) async throws -> TrackNumbers = { try await MetadataExtractor.extractNumbers(from: $0) }
    /// Whether the library's drive is connected right now.
    var isDriveConnected: @Sendable () async -> Bool = { true }
    /// Pauses while the drive is away (injected so tests do not wait).
    var pause: @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(2)) }

    init(database: any DatabaseWriter, libraryRoot: String?) {
        self.database = database
        self.libraryRoot = libraryRoot
    }

    /// Tracks the job would read: a number is unset and the track has a file.
    static func unreadCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM album_tracks
            JOIN tracks ON tracks.id = album_tracks.track_id
            WHERE album_tracks.track_number IS NULL AND tracks.organized_path IS NOT NULL
            """) ?? 0
    }

    /// `Nothing to read — every album track has a number` when `count` is 0.
    static let nothingToRead = "Nothing to read — every album track has a number"

    /// The reason the job can't run (nil = it can): nothing is left to read.
    static func blockedReason(_ db: Database) throws -> String? {
        try unreadCount(db) == 0 ? nothingToRead : nil
    }

    func run(progress: @Sendable (MaintenanceProgressTracker.ProgressState) -> Void = { _ in }) async -> Outcome {
        var outcome = Outcome()
        let pending: [Pending]
        do {
            pending = try await database.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT album_tracks.album_id, album_tracks.track_id, album_tracks.disc,
                           tracks.organized_path, tracks.title, tracks.artist
                    FROM album_tracks JOIN tracks ON tracks.id = album_tracks.track_id
                    WHERE album_tracks.track_number IS NULL AND tracks.organized_path IS NOT NULL
                    ORDER BY album_tracks.album_id, album_tracks.disc, album_tracks.position
                    """).map { row in
                    Pending(albumID: row["album_id"], trackID: row["track_id"], disc: row["disc"],
                            path: row["organized_path"], title: row["title"], artist: row["artist"])
                }
            }
        } catch {
            AppLogger.shared.error("Read Track Numbers: \(error.localizedDescription)", source: "Albums")
            return outcome
        }

        var state = MaintenanceProgressTracker.ProgressState()
        state.update(current: 0, total: pending.count)
        progress(state)

        var batch: [Int64: (disc: Int, number: Int)] = [:]
        var batchAlbum: Int64?
        func flush() async {
            guard let album = batchAlbum, !batch.isEmpty else { batch = [:]; return }
            let numbers = batch
            batch = [:]
            do {
                let result = try await database.write { db in
                    try AlbumTrackRepository.writeNumbers(db, albumID: album, numbers)
                }
                if result.resorted { outcome.albumsSorted += 1 }
            } catch {
                AppLogger.shared.error("Read Track Numbers: could not save album \(album): \(error.localizedDescription)", source: "Albums")
            }
        }

        for (index, item) in pending.enumerated() {
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            if batchAlbum != item.albumID {
                await flush()
                batchAlbum = item.albumID
            }
            // Waits for the drive; leaves when cancelled meanwhile.
            while !(await isDriveConnected()) {
                if Task.isCancelled { break }
                await pause()
            }
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            if let url = TranscodeCache.resolveSourceURL(sourcePath: item.path, libraryRoot: libraryRoot) {
                do {
                    let numbers = try await extract(url)
                    if let track = numbers.track {
                        batch[item.trackID] = (numbers.disc ?? item.disc, track)
                        outcome.read += 1
                    } else {
                        outcome.withoutNumber += 1
                    }
                } catch {
                    outcome.unreadable += 1
                }
            } else {
                outcome.unreadable += 1
            }
            state.setCurrentTrack(title: item.title, artist: item.artist)
            state.update(current: index + 1, total: pending.count)
            progress(state)
        }
        await flush()
        return outcome
    }
}
