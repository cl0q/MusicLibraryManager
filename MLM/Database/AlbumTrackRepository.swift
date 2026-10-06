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

enum AlbumTrackRepositoryError: Error, Equatable, PlainCauseError {
    case albumNotFound
    case noRoomForPosition

    var plainCause: String {
        switch self {
        case .albumNotFound: "the album no longer exists"
        case .noRoomForPosition: "the track order couldn’t be changed"
        }
    }
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
        try await database.write { db in try Self.addRows(db, trackIDs: trackIDs, to: albumID) }
    }

    /// `add` inside a transaction.
    @discardableResult
    static func addRows(_ db: Database, trackIDs: [Int64], to albumID: Int64) throws -> [AlbumTrack] {
        guard try albumExists(db, albumID) else { throw AlbumTrackRepositoryError.albumNotFound }
        var seen = Set<Int64>()
        var fresh: [Int64] = []
        for id in trackIDs where seen.insert(id).inserted {
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tracks WHERE id = ?)", arguments: [id]) ?? false
            let member = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM album_tracks WHERE album_id = ? AND track_id = ?)",
                                           arguments: [albumID, id]) ?? false
            if exists, !member { fresh.append(id) }
        }
        guard !fresh.isEmpty else { return [] }
        let (keys, disc) = try positionKeys(db, albumID: albumID, count: fresh.count, at: nil, disc: nil, excluding: [])
        var inserted: [AlbumTrack] = []
        for (id, key) in zip(fresh, keys) {
            let row = AlbumTrack(albumId: albumID, trackId: id, disc: disc, position: key, trackNumber: nil)
            try row.insert(db)
            try db.execute(sql: "UPDATE tracks SET album_id = ? WHERE id = ? AND album_id IS NULL", arguments: [albumID, id])
            inserted.append(row)
        }
        return inserted
    }

    /// Removes the tracks from the album; returns the rows removed.
    @discardableResult
    func remove(trackIDs: [Int64], from albumID: Int64) async throws -> [AlbumTrack] {
        try await database.write { db in try Self.removeRows(db, trackIDs: trackIDs, from: albumID) }
    }

    /// `remove` inside a transaction. A track that is still a member of another album is linked
    /// to that album, not left without one.
    @discardableResult
    static func removeRows(_ db: Database, trackIDs: [Int64], from albumID: Int64) throws -> [AlbumTrack] {
        var removed: [AlbumTrack] = []
        for id in Set(trackIDs) {
            guard let row = try AlbumTrack.fetchOne(db, sql: "SELECT * FROM album_tracks WHERE album_id = ? AND track_id = ?",
                                                    arguments: [albumID, id]) else { continue }
            try db.execute(sql: "DELETE FROM album_tracks WHERE album_id = ? AND track_id = ?", arguments: [albumID, id])
            let other = try Int64.fetchOne(db, sql: "SELECT MIN(album_id) FROM album_tracks WHERE track_id = ?", arguments: [id])
            try db.execute(sql: "UPDATE tracks SET album_id = ? WHERE id = ? AND album_id = ?", arguments: [other, id, albumID])
            removed.append(row)
        }
        return removed.sorted { ($0.disc, $0.position) < ($1.disc, $1.position) }
    }

    /// Places `trackIDs` (members, in this order) so the first lands at `index` among the album's
    /// other rows in (disc, position) order (`index` past the end = last). A moved row takes the
    /// disc of the row before it. When no key fits, the album's rows are renumbered first
    /// (evenly spaced, same order) — never an out-of-order key. Returns whether the order changed.
    @discardableResult
    func move(trackIDs: [Int64], to index: Int, in albumID: Int64) async throws -> Bool {
        try await database.write { db in try Self.moveRows(db, trackIDs: trackIDs, to: index, in: albumID) }
    }

    /// `move` inside a transaction.
    @discardableResult
    static func moveRows(_ db: Database, trackIDs: [Int64], to index: Int, in albumID: Int64) throws -> Bool {
        let before = try orderedRows(db, albumID: albumID)
        let members = Set(before.map(\.trackId))
        var seen = Set<Int64>()
        let moving = trackIDs.filter { members.contains($0) && seen.insert($0).inserted }
        guard !moving.isEmpty else { return false }
        let movingSet = Set(moving)
        let (keys, disc) = try positionKeys(db, albumID: albumID, count: moving.count, at: index, disc: nil, excluding: movingSet)
        for (id, key) in zip(moving, keys) {
            try db.execute(sql: "UPDATE album_tracks SET position = ?, disc = ? WHERE album_id = ? AND track_id = ?",
                           arguments: [key, disc, albumID, id])
        }
        let after = try orderedRows(db, albumID: albumID)
        return after.map(\.trackId) != before.map(\.trackId)
            || zip(after, before).contains { $0.disc != $1.disc }
    }

    /// One album edit as one transaction: the rows before, the edit, the rows after. An import
    /// that links a track into the album meanwhile can't become part of the step.
    func edit(albumID: Int64, _ body: @escaping @Sendable (Database) throws -> Void) async throws -> (before: AlbumTrackSnapshot, after: AlbumTrackSnapshot) {
        try await database.write { db in
            let before = try Self.snapshot(db, albumID: albumID)
            try body(db)
            return (before, try Self.snapshot(db, albumID: albumID))
        }
    }

    /// Writes disc and track numbers (from the files) for members. When every member of the
    /// album has a number afterwards, positions are re-sorted by (disc, number) — ties keep their
    /// order — so the album plays in its own order.
    @discardableResult
    func setNumbers(albumID: Int64, _ numbers: [Int64: (disc: Int, number: Int)]) async throws -> AlbumNumbering {
        try await database.write { db in try Self.writeNumbers(db, albumID: albumID, numbers) }
    }

    /// `setNumbers` inside a transaction.
    static func writeNumbers(_ db: Database, albumID: Int64, _ numbers: [Int64: (disc: Int, number: Int)]) throws -> AlbumNumbering {
        var changed = 0
        for (trackID, value) in numbers {
            try db.execute(sql: """
                UPDATE album_tracks SET disc = ?, track_number = ?
                WHERE album_id = ? AND track_id = ? AND (disc <> ? OR track_number IS NOT ?)
                """, arguments: [value.disc, value.number, albumID, trackID, value.disc, value.number])
            changed += db.changesCount
        }
        return AlbumNumbering(changed: changed, resorted: try resortIfNumbered(db, albumID: albumID))
    }

    /// When every member of the album has a track number, re-sorts the positions by (disc,
    /// number) — ties keep their order — and returns true.
    static func resortIfNumbered(_ db: Database, albumID: Int64) throws -> Bool {
        let rows = try orderedRows(db, albumID: albumID)
        guard !rows.isEmpty, rows.allSatisfy({ $0.trackNumber != nil }) else { return false }
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
        return true
    }

    /// A track imported with album text (the import path, inside its write): finds or creates the
    /// album, links `tracks.album_id` and appends the track with the file's disc and track number.
    /// Nothing for a track without an album (DEC-021). Returns the album id.
    @discardableResult
    static func linkImportedTrack(_ db: Database, trackID: Int64, artist: String, albumArtist: String, album: String,
                                  year: Int?, disc: Int?, number: Int?) throws -> Int64? {
        guard !AlbumKey.isNoAlbum(album) else { return nil }
        // A savepoint: a failure part-way leaves no new album row, no link and no join row behind.
        var linked: Int64?
        try db.inSavepoint {
            let albumID = try AlbumKey.findOrCreate(db, artist: artist, albumArtist: albumArtist, title: album, year: year)
            linked = albumID
            let alreadyMember = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM album_tracks WHERE album_id = ? AND track_id = ?)",
                                                  arguments: [albumID, trackID]) ?? false
            try db.execute(sql: "UPDATE tracks SET album_id = ? WHERE id = ? AND album_id IS NULL", arguments: [albumID, trackID])
            if !alreadyMember {
                let (keys, usedDisc) = try positionKeys(db, albumID: albumID, count: 1, at: nil, disc: disc, excluding: [])
                try AlbumTrack(albumId: albumID, trackId: trackID, disc: usedDisc, position: keys[0], trackNumber: number).insert(db)
                if number != nil { _ = try resortIfNumbered(db, albumID: albumID) }
            }
            return .commit
        }
        return linked
    }

    /// A track row just inserted by a download, a remote-playlist import or a recommendation
    /// (inside the write that inserted it): joins its album when the row carries a real album
    /// text, like `ImportService.saveBatch` does (W4-3). Nothing for a track without an album
    /// (DEC-021, the usual case: sources deliver no album). Best effort in a savepoint — the
    /// track is in either way; a failure only leaves it without an album link.
    static func linkNewTrack(_ db: Database, _ track: Track) {
        guard let id = track.id, !AlbumKey.isNoAlbum(track.album) else { return }
        do {
            try db.inSavepoint {
                try linkImportedTrack(db, trackID: id, artist: track.artist, albumArtist: track.albumArtist,
                                      album: track.album, year: track.year, disc: nil, number: nil)
                return .commit
            }
        } catch {
            AppLogger.shared.warn("Album link failed for “\(track.title)”: \(error.localizedDescription)", source: "Albums")
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
            guard try Self.albumExists(db, albumID) else { throw AlbumTrackRepositoryError.albumNotFound }
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

    static func albumExists(_ db: Database, _ id: Int64) throws -> Bool {
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
