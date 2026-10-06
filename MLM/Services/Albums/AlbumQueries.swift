import Foundation
import GRDB

// What the album surfaces read and write beyond the W4-1 contracts (W4-2). The reads are
// read-only queries over `albums`, `album_tracks` and `tracks` (listed tracks only,
// `TrackVisibility.listedSQL`); the writes are the ones an album page needs that
// `AlbumRepository` / `AlbumTrackRepository` don't have yet (cover path, preference reset,
// disc-aware order with numbers, pruning an emptied album). They live here because
// `MLM/Database/` is W4-1's.

/// How much of an edition the library holds (`‹in› of ‹n› in library`).
struct AlbumEditionStat: Equatable, Sendable {
    let albumID: Int64
    /// Listed tracks of the edition.
    let inLibrary: Int
    /// The tracklist's size when known, else `inLibrary`.
    let total: Int
}

/// What removing albums from the library takes with it (A-ALB-REMOVE, in numbers).
struct AlbumRemovalImpact: Equatable, Sendable {
    /// Listed tracks of the albums, in album order, each once.
    let trackIDs: [Int64]
    let playlists: Int
    let syncProfiles: Int
}

extension AlbumRepository {
    // MARK: Reading

    /// The album's listed tracks in its own order (disc, position) with their disc and the
    /// number the file says.
    func members(of albumID: Int64) async throws -> [AlbumMember] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT tracks.*, album_tracks.disc AS at_disc, album_tracks.track_number AS at_number
                FROM album_tracks JOIN tracks ON tracks.id = album_tracks.track_id
                WHERE album_tracks.album_id = ? AND \(TrackVisibility.listedSQL)
                ORDER BY album_tracks.disc, album_tracks.position, tracks.id
                """, arguments: [albumID])
            return try rows.map { row in
                AlbumMember(track: try Track(row: row), disc: row["at_disc"] ?? 1, number: row["at_number"])
            }
        }
    }

    /// Per album: its listed tracks that have no file and aren't downloading — what `Download ‹n›
    /// Missing` fetches (not downloaded and failed).
    func downloadableCounts() async throws -> [Int64: Int] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT album_tracks.album_id AS album_id, COUNT(*) AS n
                FROM album_tracks JOIN tracks ON tracks.id = album_tracks.track_id
                WHERE \(TrackVisibility.listedSQL) AND \(TrackAvailabilitySQL.noFile) AND NOT \(TrackAvailabilitySQL.downloadingStatus)
                GROUP BY album_tracks.album_id
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { (($0["album_id"] as Int64), ($0["n"] as Int)) })
        }
    }

    /// Per album: its first listed track in album order — the cover's embedded-artwork fallback.
    func firstTrackIDs() async throws -> [Int64: Int64] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT album_id, track_id FROM (
                    SELECT album_tracks.album_id AS album_id, album_tracks.track_id AS track_id,
                           ROW_NUMBER() OVER (PARTITION BY album_tracks.album_id
                                              ORDER BY album_tracks.disc, album_tracks.position, tracks.id) AS rank
                    FROM album_tracks JOIN tracks ON tracks.id = album_tracks.track_id
                    WHERE \(TrackVisibility.listedSQL)
                ) WHERE rank = 1
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { (($0["album_id"] as Int64), ($0["track_id"] as Int64)) })
        }
    }

    /// How much of each album (edition) the library holds.
    func editionStats(ids: [Int64]) async throws -> [Int64: AlbumEditionStat] {
        try await database.read { db in
            var result: [Int64: AlbumEditionStat] = [:]
            for id in ids {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT album_tracks.disc AS disc, album_tracks.track_number AS number
                    FROM album_tracks JOIN tracks ON tracks.id = album_tracks.track_id
                    WHERE album_tracks.album_id = ? AND \(TrackVisibility.listedSQL)
                    """, arguments: [id])
                let members = rows.map { (disc: ($0["disc"] as Int?) ?? 1, number: $0["number"] as Int?) }
                let tracklist = AlbumTracklist(members)
                result[id] = AlbumEditionStat(albumID: id, inLibrary: members.count, total: tracklist.expectedCount ?? members.count)
            }
            return result
        }
    }

    /// What `Remove from Library…` of these albums removes.
    func removalImpact(albumIDs: [Int64]) async throws -> AlbumRemovalImpact {
        try await database.read { db in
            var seen = Set<Int64>()
            var trackIDs: [Int64] = []
            for albumID in albumIDs {
                let ids = try Int64.fetchAll(db, sql: """
                    SELECT tracks.id FROM album_tracks JOIN tracks ON tracks.id = album_tracks.track_id
                    WHERE album_tracks.album_id = ? AND \(TrackVisibility.listedSQL)
                    ORDER BY album_tracks.disc, album_tracks.position, tracks.id
                    """, arguments: [albumID])
                for id in ids where seen.insert(id).inserted { trackIDs.append(id) }
            }
            guard !trackIDs.isEmpty else { return AlbumRemovalImpact(trackIDs: [], playlists: 0, syncProfiles: 0) }
            let marks = Array(repeating: "?", count: trackIDs.count).joined(separator: ", ")
            let arguments = StatementArguments(trackIDs)
            let playlists = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT playlist_id) FROM playlist_tracks WHERE track_id IN (\(marks))",
                                             arguments: arguments) ?? 0
            let profiles = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT profile_id) FROM sync_profile_tracks WHERE track_id IN (\(marks))",
                                            arguments: arguments) ?? 0
            return AlbumRemovalImpact(trackIDs: trackIDs, playlists: playlists, syncProfiles: profiles)
        }
    }

    // MARK: Writing

    /// Sets (or, with nil, clears) `albums.cover_path`; returns the path it had.
    @discardableResult
    func setCoverPath(albumID: Int64, to path: String?) async throws -> String? {
        try await database.write { db in
            let before = try String.fetchOne(db, sql: "SELECT cover_path FROM albums WHERE id = ?", arguments: [albumID])
            try db.execute(sql: "UPDATE albums SET cover_path = ? WHERE id = ?", arguments: [path, albumID])
            return before
        }
    }

    /// The preferred edition of a group, or nothing (undo of the first choice).
    func clearVariantPref(baseAlbumId: Int64, userId: String = "default") async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM user_album_variant_pref WHERE user_id = ? AND base_album_id = ?",
                           arguments: [userId, baseAlbumId])
        }
    }

    /// Deletes each album that has no member left at all (after its last track left the
    /// library), with the rows that point at it. Albums that still have a member — a hidden
    /// version, a track whose file couldn't be trashed — stay. Returns how many went.
    @discardableResult
    func deleteEmpty(ids: [Int64]) async throws -> Int {
        var removed = 0
        for id in Set(ids) {
            let members = try await database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album_tracks WHERE album_id = ?", arguments: [id]) ?? 0
            }
            guard members == 0 else { continue }
            try await delete(id: id)
            removed += 1
        }
        return removed
    }
}

extension AlbumTrackRepository {
    /// Edit Order's Done (IMP-081): the listed tracks take the given discs and numbers 1, 2, 3…
    /// within each disc, and the album's order becomes (disc, the order given). Members that
    /// aren't listed (hidden versions) keep their number and follow the listed ones of their
    /// disc. One transaction; undo restores `snapshot` exactly. Returns whether anything changed.
    @discardableResult
    func applyLayout(albumID: Int64, _ ordered: [(trackID: Int64, disc: Int, number: Int)]) async throws -> Bool {
        try await database.write { db in
            let before = try Self.orderedRows(db, albumID: albumID)
            let layout = Dictionary(ordered.map { ($0.trackID, $0) }, uniquingKeysWith: { first, _ in first })
            // The new full order: listed members as given, hidden ones after their disc's.
            var full: [AlbumTrack] = []
            for row in before {
                if let new = layout[row.trackId] {
                    var updated = row
                    updated.disc = new.disc
                    updated.trackNumber = new.number
                    full.append(updated)
                } else {
                    full.append(row)
                }
            }
            let order = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.trackID, $0.offset) })
            let sorted = full.enumerated().sorted { a, b in
                if a.element.disc != b.element.disc { return a.element.disc < b.element.disc }
                switch (order[a.element.trackId], order[b.element.trackId]) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return a.offset < b.offset
                }
            }.map(\.element)
            let keys = FractionalIndexer.evenlySpaced(count: sorted.count)
            for (row, key) in zip(sorted, keys) {
                try db.execute(sql: """
                    UPDATE album_tracks SET position = ?, disc = ?, track_number = ?
                    WHERE album_id = ? AND track_id = ?
                    """, arguments: [key, row.disc, row.trackNumber, albumID, row.trackId])
            }
            return try Self.orderedRows(db, albumID: albumID) != before
        }
    }
}
