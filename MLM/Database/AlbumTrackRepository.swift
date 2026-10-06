import Foundation
import GRDB

/// An album's `album_tracks` rows (and which tracks point at the album through
/// `tracks.album_id`) exactly as they were — what an undo puts back.
struct AlbumTrackSnapshot: Equatable, Sendable {
    let albumID: Int64
    let rows: [AlbumTrack]
    /// Tracks whose `tracks.album_id` was this album.
    let linkedTrackIDs: [Int64]
}

/// What `setNumbers` did.
struct AlbumNumbering: Equatable, Sendable {
    /// Rows whose disc or number changed.
    let changed: Int
    /// Every member had a number, so the positions were re-sorted by (disc, number).
    let resorted: Bool
}

enum AlbumTrackRepositoryError: Error, Equatable {
    case albumNotFound
    case noRoomForPosition
}

/// An album's track list: membership, order and numbers (`album_tracks`, IMP-067).
///
/// Order is `disc`, then the fractional `position` (same keys and the same renumber-when-no-key-
/// fits rule as `PlaylistRepository`, W3-PL). `tracks.album_id` is kept in step: adding a track
/// that has no album link links it; removing it clears the link when it pointed here.
final class AlbumTrackRepository: Sendable {
    let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    // MARK: - Read

    /// The album's tracks in order (disc, position), listed ones only (`TrackVisibility.listedSQL`).
    func tracks(of albumID: Int64) async throws -> [Track] {
        try await database.read { db in
            try Track.fetchAll(db, sql: """
                SELECT tracks.* FROM album_tracks
                JOIN tracks ON tracks.id = album_tracks.track_id
                WHERE album_tracks.album_id = ? AND \(TrackVisibility.listedSQL)
                ORDER BY album_tracks.disc, album_tracks.position, tracks.id
                """, arguments: [albumID])
        }
    }

    /// Every row of the album in order, hidden tracks included.
    func rows(of albumID: Int64) async throws -> [AlbumTrack] {
        try await database.read { db in try Self.orderedRows(db, albumID: albumID) }
    }

    /// The albums a track is a member of.
    func membership(trackID: Int64) async throws -> [AlbumTrack] {
        try await database.read { db in
            try AlbumTrack.fetchAll(db, sql: "SELECT * FROM album_tracks WHERE track_id = ? ORDER BY album_id", arguments: [trackID])
        }
    }

    static func orderedRows(_ db: Database, albumID: Int64) throws -> [AlbumTrack] {
        try AlbumTrack.fetchAll(db, sql: """
            SELECT * FROM album_tracks WHERE album_id = ? ORDER BY disc, position, track_id
            """, arguments: [albumID])
    }

    // MARK: - Edit

    /// Adds the tracks (that exist and are not members yet) after the album's last row, disc 1,
    /// no number, in the given order. Returns the rows it inserted. Throws if the album is gone.
    @discardableResult
    func add(trackIDs: [Int64], to albumID: Int64) async throws -> [AlbumTrack] {
        try await database.write { db in
            guard try Self.albumExists(db, albumID) else { throw AlbumTrackRepositoryError.albumNotFound }
            var seen = Set<Int64>()
            var fresh: [Int64] = []
            for id in trackIDs where seen.insert(id).inserted {
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tracks WHERE id = ?)", arguments: [id]) ?? false
                let member = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM album_tracks WHERE album_id = ? AND track_id = ?)",
                                               arguments: [albumID, id]) ?? false
                if exists, !member { fresh.append(id) }
            }
            guard !fresh.isEmpty else { return [] }
            let (keys, disc) = try Self.positionKeys(db, albumID: albumID, count: fresh.count, at: nil, disc: nil, excluding: [])
            var inserted: [AlbumTrack] = []
            for (id, key) in zip(fresh, keys) {
                let row = AlbumTrack(albumId: albumID, trackId: id, disc: disc, position: key, trackNumber: nil)
                try row.insert(db)
                try db.execute(sql: "UPDATE tracks SET album_id = ? WHERE id = ? AND album_id IS NULL", arguments: [albumID, id])
                inserted.append(row)
            }
            return inserted
        }
    }

    /// Removes the tracks from the album; returns the rows removed.
    @discardableResult
    func remove(trackIDs: [Int64], from albumID: Int64) async throws -> [AlbumTrack] {
        try await database.write { db in
            var removed: [AlbumTrack] = []
            for id in Set(trackIDs) {
                guard let row = try AlbumTrack.fetchOne(db, sql: "SELECT * FROM album_tracks WHERE album_id = ? AND track_id = ?",
                                                        arguments: [albumID, id]) else { continue }
                try db.execute(sql: "DELETE FROM album_tracks WHERE album_id = ? AND track_id = ?", arguments: [albumID, id])
                try db.execute(sql: "UPDATE tracks SET album_id = NULL WHERE id = ? AND album_id = ?", arguments: [id, albumID])
                removed.append(row)
            }
            return removed.sorted { ($0.disc, $0.position) < ($1.disc, $1.position) }
        }
    }

    /// Places `trackIDs` (members, in this order) so the first lands at `index` among the album's
    /// other rows in (disc, position) order (`index` past the end = last). A moved row takes the
    /// disc of the row before it. When no key fits, the album's rows are renumbered first
    /// (evenly spaced, same order) — never an out-of-order key. Returns whether the order changed.
    @discardableResult
    func move(trackIDs: [Int64], to index: Int, in albumID: Int64) async throws -> Bool {
        try await database.write { db in
            let before = try Self.orderedRows(db, albumID: albumID)
            let members = Set(before.map(\.trackId))
            var seen = Set<Int64>()
            let moving = trackIDs.filter { members.contains($0) && seen.insert($0).inserted }
            guard !moving.isEmpty else { return false }
            let movingSet = Set(moving)
            let (keys, disc) = try Self.positionKeys(db, albumID: albumID, count: moving.count, at: index, disc: nil, excluding: movingSet)
            for (id, key) in zip(moving, keys) {
                try db.execute(sql: "UPDATE album_tracks SET position = ?, disc = ? WHERE album_id = ? AND track_id = ?",
                               arguments: [key, disc, albumID, id])
            }
            let after = try Self.orderedRows(db, albumID: albumID)
            return after.map(\.trackId) != before.map(\.trackId)
                || zip(after, before).contains { $0.disc != $1.disc }
        }
    }

    /// Writes disc and track numbers (from the files) for members. When every member of the
    /// album has a number afterwards, positions are re-sorted by (disc, number) — ties keep their
    /// order — so the album plays in its own order.
    @discardableResult
    func setNumbers(albumID: Int64, _ numbers: [Int64: (disc: Int, number: Int)]) async throws -> AlbumNumbering {
        try await database.write { db in
            var changed = 0
            for (trackID, value) in numbers {
                try db.execute(sql: """
                    UPDATE album_tracks SET disc = ?, track_number = ?
                    WHERE album_id = ? AND track_id = ? AND (disc <> ? OR track_number IS NOT ?)
                    """, arguments: [value.disc, value.number, albumID, trackID, value.disc, value.number])
                changed += db.changesCount
            }
            let rows = try Self.orderedRows(db, albumID: albumID)
            guard !rows.isEmpty, rows.allSatisfy({ $0.trackNumber != nil }) else {
                return AlbumNumbering(changed: changed, resorted: false)
            }
            let sorted = rows.enumerated().sorted { a, b in
                let l = a.element, r = b.element
                if l.disc != r.disc { return l.disc < r.disc }
                if l.trackNumber != r.trackNumber { return l.trackNumber! < r.trackNumber! }
                return a.offset < b.offset
            }.map(\.element)
            let keys = FractionalIndexer.evenlySpaced(count: sorted.count)
            for (row, key) in zip(sorted, keys) where row.position != key {
                try db.execute(sql: "UPDATE album_tracks SET position = ? WHERE album_id = ? AND track_id = ?",
                               arguments: [key, albumID, row.trackId])
            }
            return AlbumNumbering(changed: changed, resorted: true)
        }
    }

    // MARK: - Undo (exact rows)

    func snapshot(albumID: Int64) async throws -> AlbumTrackSnapshot {
        try await database.read { db in try Self.snapshot(db, albumID: albumID) }
    }

    /// Puts the album's rows back exactly as the snapshot had them (rows of tracks that left the
    /// library meanwhile are skipped; rows added since are removed, their `tracks.album_id`
    /// link with them).
    func restore(_ snapshot: AlbumTrackSnapshot) async throws {
        try await database.write { db in
            let albumID = snapshot.albumID
            let wanted = Set(snapshot.rows.map(\.trackId))
            for row in try Self.orderedRows(db, albumID: albumID) where !wanted.contains(row.trackId) {
                try db.execute(sql: "UPDATE tracks SET album_id = NULL WHERE id = ? AND album_id = ?", arguments: [row.trackId, albumID])
            }
            try db.execute(sql: "DELETE FROM album_tracks WHERE album_id = ?", arguments: [albumID])
            for row in snapshot.rows {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tracks WHERE id = ?)", arguments: [row.trackId]) ?? false else { continue }
                try row.insert(db)
            }
            for id in snapshot.linkedTrackIDs {
                try db.execute(sql: "UPDATE tracks SET album_id = ? WHERE id = ? AND album_id IS NULL", arguments: [albumID, id])
            }
        }
    }

    static func snapshot(_ db: Database, albumID: Int64) throws -> AlbumTrackSnapshot {
        AlbumTrackSnapshot(
            albumID: albumID,
            rows: try orderedRows(db, albumID: albumID),
            linkedTrackIDs: try Int64.fetchAll(db, sql: "SELECT id FROM tracks WHERE album_id = ? ORDER BY id", arguments: [albumID]))
    }

    // MARK: - Positions (the W3-PL rule)

    private static func albumExists(_ db: Database, _ id: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM albums WHERE id = ?)", arguments: [id]) ?? false
    }

    /// Keys for `count` rows placed, in order, at `index` among the rows other than `moving`
    /// (nil = at the end), and the disc they take (the disc of the row before; the first row's
    /// at the start; 1 for an empty album). Renumbers every row of the album first when no key
    /// fits (equal / reversed keys across discs, a key ending in `0…`, a very long key).
    static func positionKeys(_ db: Database, albumID: Int64, count: Int, at index: Int?, disc forcedDisc: Int?,
                             excluding moving: Set<Int64>) throws -> (keys: [String], disc: Int) {
        func attempt(_ rows: [AlbumTrack]) -> (keys: [String], disc: Int)? {
            let remaining = rows.filter { !moving.contains($0.trackId) }
            let insertAt = min(max(index ?? remaining.count, 0), remaining.count)
            let previous = insertAt > 0 ? remaining[insertAt - 1] : nil
            let next = insertAt < remaining.count ? remaining[insertAt] : nil
            let disc = forcedDisc ?? previous?.disc ?? next?.disc ?? 1
            var left = previous.flatMap { $0.disc == disc ? $0.position : nil }
            let right = next.flatMap { $0.disc == disc ? $0.position : nil }
            var keys: [String] = []
            for _ in 0..<count {
                guard let key = FractionalIndexer.key(between: left, and: right) else { return nil }
                keys.append(key)
                left = key
            }
            return (keys, disc)
        }
        var rows = try orderedRows(db, albumID: albumID)
        func renumber() throws {
            let keys = FractionalIndexer.evenlySpaced(count: rows.count)
            for (row, key) in zip(rows, keys) where row.position != key {
                try db.execute(sql: "UPDATE album_tracks SET position = ? WHERE album_id = ? AND track_id = ?",
                               arguments: [key, albumID, row.trackId])
            }
            rows = try orderedRows(db, albumID: albumID)
        }
        var renumbered = false
        if rows.contains(where: { $0.position.utf8.count > FractionalIndexer.renumberLength }) {
            try renumber()
            renumbered = true
        }
        if let result = attempt(rows) { return result }
        if !renumbered {
            try renumber()
            if let result = attempt(rows) { return result }
        }
        throw AlbumTrackRepositoryError.noRoomForPosition
    }
}
