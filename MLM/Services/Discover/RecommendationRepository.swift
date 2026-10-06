import Foundation
import GRDB

/// The verdicts on held recommendations (V-INBOX, IMP-053…055).
///
/// A recommendation is a downloaded track that waits in Discover until the user keeps or
/// dismisses it: `tracks.is_pending_recommendation = 1` hides it from every library list
/// (`TrackVisibility.listedSQL`) and `track_discovery_log.status` says where it stands:
/// `new` (waiting) · `kept` · `dismissed`. Every verdict is **one transaction**; nothing here
/// touches a file (the Trash move belongs to `RecommendationVerdicts`, after the commit).
/// Foreign keys are off, so deleting is manual (`TrackRepository.delete`).
final class RecommendationRepository: Sendable {
    enum Status {
        static let waiting = "new"
        static let kept = "kept"
        static let dismissed = "dismissed"
    }

    /// A dismissed recommendation: what the file move needs.
    struct Dismissed: Equatable, Sendable {
        var trackID: Int64
        var organizedPath: String?
    }

    private let database: any DatabaseWriter
    private let tracks: TrackRepository

    init(database: any DatabaseWriter) {
        self.database = database
        self.tracks = TrackRepository(database: database)
    }

    // MARK: Holding

    /// A download started for Discover: the track is held and its log row says `new`. One
    /// transaction (`Download` in Similar ▸ Online and `Find Recommendations…`).
    func markHeld(trackID: Int64, seedTrackID: Int64?, source: String) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE tracks SET is_pending_recommendation = 1 WHERE id = ?", arguments: [trackID])
            var row = TrackDiscoveryLog(discoveredTrackId: trackID, seedTrackId: seedTrackID,
                                        discoverySource: source, status: Status.waiting)
            try row.insert(db, onConflict: .replace)
        }
    }

    /// Insert a freshly downloaded recommendation: the track row, its held flag and its log row in
    /// **one transaction**, so it is never listed in All Tracks, not even for an instant
    /// (`hold == false`: `Keep` in Similar ▸ Online — a library track whose log row says `kept`).
    func insert(_ track: Track, hold: Bool, seedTrackID: Int64?, source: String) async throws -> Track {
        try await database.write { db in
            var track = track
            track.searchText = DatabaseManager.foldedSearchText(track.rawSearchText)
            try track.insert(db)
            guard let id = track.id else { return track }
            try db.execute(sql: "UPDATE tracks SET is_pending_recommendation = ? WHERE id = ?", arguments: [hold ? 1 : 0, id])
            // W4-3: a kept download joins its album now; a held one when it is kept (`keep`).
            if !hold { AlbumTrackRepository.linkNewTrack(db, track) }
            var row = TrackDiscoveryLog(discoveredTrackId: id, seedTrackId: seedTrackID, discoverySource: source,
                                        status: hold ? Status.waiting : Status.kept)
            try row.insert(db, onConflict: .replace)
            return track
        }
    }

    /// A download made for the library directly (`Keep` in Similar ▸ Online): a log row that
    /// is already `kept`; the track is not held.
    func recordKept(trackID: Int64, seedTrackID: Int64?, source: String) async throws {
        try await database.write { db in
            var row = TrackDiscoveryLog(discoveredTrackId: trackID, seedTrackId: seedTrackID,
                                        discoverySource: source, status: Status.kept)
            try row.insert(db, onConflict: .replace)
            try db.execute(sql: "UPDATE tracks SET is_pending_recommendation = 0 WHERE id = ?", arguments: [trackID])
        }
    }

    // MARK: Keep

    /// Keep the waiting ones among `ids`: they join the library. Returns the ids that changed
    /// (a second Keep on the same ids changes nothing).
    @discardableResult
    func keep(ids: [Int64]) async throws -> [Int64] {
        try await database.write { db in
            let waiting = try Self.ids(in: ids, withStatus: Status.waiting, db)
            for id in waiting {
                try db.execute(sql: "UPDATE tracks SET is_pending_recommendation = 0 WHERE id = ?", arguments: [id])
                try db.execute(sql: "UPDATE track_discovery_log SET status = ? WHERE discovered_track_id = ?",
                               arguments: [Status.kept, id])
                if let kept = try Track.fetchOne(db, key: id) { AlbumTrackRepository.linkNewTrack(db, kept) }
                // What the user keeps teaches Similar (the old thumbs-up, now the real gesture):
                // the seed's score for this track is boosted. Undo removes the row again.
                if let seed = try Int64.fetchOne(db, sql: "SELECT seed_track_id FROM track_discovery_log WHERE discovered_track_id = ?",
                                                 arguments: [id]) {
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO track_similarity_feedback (seed_track_id, target_track_id, feedback_value)
                        VALUES (?, ?, 1)
                    """, arguments: [seed, id])
                }
            }
            return waiting
        }
    }

    /// Undo `keep`: back to waiting, held again.
    func undoKeep(ids: [Int64]) async throws {
        try await database.write { db in
            for id in Self.unique(ids) {
                try db.execute(sql: "UPDATE tracks SET is_pending_recommendation = 1 WHERE id = ?", arguments: [id])
                try db.execute(sql: "UPDATE track_discovery_log SET status = ? WHERE discovered_track_id = ?",
                               arguments: [Status.waiting, id])
                try db.execute(sql: "DELETE FROM track_similarity_feedback WHERE target_track_id = ? AND feedback_value = 1",
                               arguments: [id])
            }
        }
    }

    // MARK: Dismiss

    /// Dismiss the waiting ones among `ids`: `status = dismissed`, the flag stays 1 so they
    /// stay out of every list. Returns what the file move needs. The rows are purged at the
    /// next launch (`purgeDismissed`).
    func dismiss(ids: [Int64]) async throws -> [Dismissed] {
        try await database.write { db in
            let waiting = try Self.ids(in: ids, withStatus: Status.waiting, db)
            var result: [Dismissed] = []
            for id in waiting {
                try db.execute(sql: "UPDATE track_discovery_log SET status = ?, trash_url = NULL WHERE discovered_track_id = ?",
                               arguments: [Status.dismissed, id])
                let path = try String.fetchOne(db, sql: "SELECT organized_path FROM tracks WHERE id = ?", arguments: [id])
                result.append(Dismissed(trackID: id, organizedPath: path))
            }
            return result
        }
    }

    /// The file of a dismissed recommendation went to the Trash here.
    func recordTrash(trackID: Int64, url: String) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE track_discovery_log SET trash_url = ? WHERE discovered_track_id = ?",
                           arguments: [url, trackID])
        }
    }

    /// `trash_url` per dismissed track (what Undo moves back).
    func trashURLs(for ids: [Int64]) async throws -> [Int64: String] {
        try await database.read { db in
            var map: [Int64: String] = [:]
            for id in Self.unique(ids) {
                if let url = try String.fetchOne(db, sql: "SELECT trash_url FROM track_discovery_log WHERE discovered_track_id = ?",
                                                 arguments: [id]), !url.isEmpty {
                    map[id] = url
                }
            }
            return map
        }
    }

    /// Undo `dismiss`: waiting again, no Trash record.
    func undoDismiss(ids: [Int64]) async throws {
        try await database.write { db in
            for id in Self.unique(ids) {
                try db.execute(sql: "UPDATE track_discovery_log SET status = ?, trash_url = NULL WHERE discovered_track_id = ?",
                               arguments: [Status.waiting, id])
            }
        }
    }

    /// Remove the dismissed recommendations for good — track row, log row, artwork rows and the
    /// rest of the manual cascade — **without touching files** (they went to the Trash when
    /// dismissed). Run once per launch by the library's post-open housekeeping. Returns how many.
    @discardableResult
    func purgeDismissed() async throws -> Int {
        let ids = try await database.read { db in
            try Int64.fetchAll(db, sql: "SELECT discovered_track_id FROM track_discovery_log WHERE status = ?",
                               arguments: [Status.dismissed])
        }
        guard !ids.isEmpty else { return 0 }
        try await tracks.delete(ids: ids)
        return ids.count
    }

    // MARK: Reading

    /// One waiting recommendation with where it came from.
    struct Item: Equatable, Sendable, Identifiable {
        var track: Track
        var source: String
        var seedTrackID: Int64?
        var seedTitle: String?
        var seedArtist: String?
        var loggedAt: Date
        /// Analysis finished (the energy bucket exists).
        var isAnalysed: Bool { track.energyBucket != nil }
        var id: Int64 { track.id ?? 0 }
    }

    /// Everything waiting (`status = new`), newest first. Two plain queries (the old join
    /// selected both tables' `date_added` into one row).
    func waiting() async throws -> [Item] {
        try await database.read { db in
            let logs = try TrackDiscoveryLog.fetchAll(
                db, sql: "SELECT * FROM track_discovery_log WHERE status = ? ORDER BY date_added DESC",
                arguments: [Status.waiting])
            guard !logs.isEmpty else { return [] }
            let ids = Set(logs.map(\.discoveredTrackId)).union(logs.compactMap(\.seedTrackId))
            let found = try Track.fetchAll(db, keys: Array(ids))
            let byID = Dictionary(found.compactMap { track in track.id.map { ($0, track) } },
                                  uniquingKeysWith: { first, _ in first })
            return logs.compactMap { log in
                guard let track = byID[log.discoveredTrackId] else { return nil }
                let seed = log.seedTrackId.flatMap { byID[$0] }
                return Item(track: track, source: log.discoverySource, seedTrackID: seed?.id,
                            seedTitle: seed?.title, seedArtist: seed?.artist, loggedAt: log.dateAdded)
            }
        }
    }

    /// `status` per discovered track (the Similar view's online rows show where a download is).
    func statuses(for ids: [Int64]) async throws -> [Int64: String] {
        try await database.read { db in
            var map: [Int64: String] = [:]
            for id in Self.unique(ids) {
                if let status = try String.fetchOne(db, sql: "SELECT status FROM track_discovery_log WHERE discovered_track_id = ?",
                                                    arguments: [id]) {
                    map[id] = status
                }
            }
            return map
        }
    }

    // MARK: Helpers

    private static func unique(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func ids(in ids: [Int64], withStatus status: String, _ db: Database) throws -> [Int64] {
        try unique(ids).filter { id in
            try String.fetchOne(db, sql: "SELECT status FROM track_discovery_log WHERE discovered_track_id = ?",
                                arguments: [id]) == status
        }
    }
}
