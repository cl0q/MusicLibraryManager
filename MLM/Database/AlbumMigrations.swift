import Foundation
import GRDB

/// The bodies of the album migrations (W4-1). Registered in `DatabaseManager.buildMigrator()`
/// as `v50_album_tracks` and `v51_album_dedup`; kept here so the shared file only gets the
/// registration lines. Both are idempotent (safe to run again over partly applied data).
enum AlbumMigrations {
    // MARK: - v50 album_tracks

    /// `album_tracks(album_id, track_id, disc, position, track_number)` (IMP-067).
    ///
    /// (a) Every track with album text and no `album_id` is linked to an `albums` row found or
    /// created by (album artist — else artist — NFC-case-folded, normalised title). Database
    /// only; no file is read. Tracks whose album text is no album (empty, `unknown album`, a source name or
    /// a URL — `TrackMetadataPresentation.isRealAlbum`) are not an album (DEC-021) and stay unlinked.
    /// (b) Every track with an `album_id` that has no row yet gets one: disc 1, positions evenly
    /// spaced in title order, `track_number` NULL (the numbers come later from the files).
    static func v50AlbumTracks(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS album_tracks (
                album_id INTEGER NOT NULL,
                track_id INTEGER NOT NULL,
                disc INTEGER NOT NULL DEFAULT 1,
                position TEXT NOT NULL,
                track_number INTEGER,
                PRIMARY KEY (album_id, track_id)
            )
            """)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_album_tracks_track ON album_tracks(track_id)")

        // (a) link by name.
        var known: [String: Int64] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, artist, album_artist, title FROM albums WHERE IFNULL(variant_kind, '') = '' ORDER BY id") {
            let key = AlbumKey.rowKey(albumArtist: row["album_artist"], artist: row["artist"], title: row["title"])
            if known[key] == nil { known[key] = row["id"] }
        }
        let unlinked = try Row.fetchAll(db, sql: """
            SELECT id, artist, album_artist, album, year FROM tracks
            WHERE album_id IS NULL AND album <> '' ORDER BY id
            """)
        for row in unlinked {
            let album: String = row["album"]
            if AlbumKey.isNoAlbum(album) { continue }
            let artist: String = row["artist"]
            let filedUnder = AlbumKey.effectiveArtist(albumArtist: row["album_artist"], artist: artist)
            let key = AlbumKey.key(artist: filedUnder, title: album)
            let albumID: Int64
            if let id = known[key] {
                albumID = id
            } else {
                albumID = try AlbumKey.findOrCreate(db, artist: artist, albumArtist: filedUnder, title: album, year: row["year"])
                known[key] = albumID
            }
            try db.execute(sql: "UPDATE tracks SET album_id = ? WHERE id = ?", arguments: [albumID, row["id"] as Int64])
        }

        // (b) seed the join.
        let members = try Row.fetchAll(db, sql: """
            SELECT t.album_id AS album_id, t.id AS track_id, a.title AS album_title
            FROM tracks t JOIN albums a ON a.id = t.album_id
            WHERE NOT EXISTS (SELECT 1 FROM album_tracks x WHERE x.album_id = t.album_id AND x.track_id = t.id)
            ORDER BY t.album_id, t.title COLLATE NOCASE, t.id
            """).filter { !AlbumKey.isNoAlbum($0["album_title"]) }
        var start = 0
        while start < members.count {
            let albumID: Int64 = members[start]["album_id"]
            var end = start
            while end < members.count, (members[end]["album_id"] as Int64) == albumID { end += 1 }
            let tail = try String.fetchOne(db, sql: "SELECT MAX(position) FROM album_tracks WHERE album_id = ?", arguments: [albumID])
            let keys = v50SeedKeys(count: end - start, after: tail)
            for (row, key) in zip(members[start..<end], keys) {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO album_tracks (album_id, track_id, disc, position, track_number)
                    VALUES (?, ?, 1, ?, NULL)
                    """, arguments: [albumID, row["track_id"] as Int64, key])
            }
            start = end
        }
    }

    // MARK: - v51 album dedup

    /// The `app_config` key that holds the merge log (JSON `{"old id": new id}`), for support.
    static let dedupLogKey = "albums.dedup.v51"

    /// Merges albums that are one album written two ways (IMP-068): the same album artist
    /// (NFC, case-folded) and normalised title. The row with the most `album_tracks` rows keeps
    /// (ties: the lowest id); `tracks.album_id`, `album_tracks`, `user_album_variant_pref`
    /// (base and selected) and `albums.variant_of` of the others are re-pointed to it, and the
    /// others are deleted. Variants (`variant_kind` set, or a `variant_of`) are never merged
    /// into their base nor into each other. A merged row gives its year and cover to the survivor
    /// when it has none. The log of merges is kept in `app_config` (`albums.dedup.v51`).
    static func v51AlbumDedup(_ db: Database) throws {
        let albums = try Row.fetchAll(db, sql: """
            SELECT id, artist, album_artist, title FROM albums
            WHERE IFNULL(variant_kind, '') = '' AND variant_of IS NULL ORDER BY id
            """)
        var counts: [Int64: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT album_id, COUNT(*) AS n FROM album_tracks GROUP BY album_id") {
            counts[row["album_id"]] = row["n"]
        }
        var groups: [String: [Int64]] = [:]
        var order: [String] = []
        for row in albums {
            let key = AlbumKey.rowKey(albumArtist: row["album_artist"], artist: row["artist"], title: row["title"])
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(row["id"])
        }

        var log: [String: Int64] = [:]
        for key in order {
            guard let ids = groups[key], ids.count > 1 else { continue }
            // Most album_tracks rows; ties → lowest id (`ids` is ascending, a tie keeps the earlier).
            let winner = ids.reduce(ids[0]) { best, id in (counts[id] ?? 0) > (counts[best] ?? 0) ? id : best }
            for loser in ids where loser != winner {
                try merge(db, loser: loser, into: winner)
                log[String(loser)] = winner
            }
        }
        // Every base row now carries the Swift `title_normalized` (the Tauri app wrote `good_lies`,
        // v16 `goodlies`), so the unique index, `AlbumKey` and every lookup agree from here on.
        // Done after the merges: distinct Swift keys never collide on the index.
        for row in albums {
            let id: Int64 = row["id"]
            guard log[String(id)] == nil else { continue }
            let normalized = AlbumKey.normalize(row["title"])
            try db.execute(sql: "UPDATE OR IGNORE albums SET title_normalized = ? WHERE id = ? AND title_normalized <> ?",
                           arguments: [normalized, id, normalized])
        }
        guard !log.isEmpty else { return }
        // A log from an earlier run is kept; this run's merges are added.
        var merged = log
        if let old = try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = ?", arguments: [dedupLogKey]),
           let data = old.data(using: .utf8),
           let previous = try? JSONDecoder().decode([String: Int64].self, from: data) {
            merged = previous.merging(log) { _, new in new }
        }
        let data = try JSONEncoder().encode(merged)
        try db.execute(sql: """
            INSERT OR REPLACE INTO app_config (key, value, updated_at) VALUES (?, ?, datetime('now'))
            """, arguments: [dedupLogKey, String(decoding: data, as: UTF8.self)])
    }

    private static func merge(_ db: Database, loser: Int64, into winner: Int64) throws {
        try db.execute(sql: "UPDATE tracks SET album_id = ? WHERE album_id = ?", arguments: [winner, loser])

        // The loser's members join the winner after its last row, in their own order
        // (INSERT OR IGNORE: a track already in the winner keeps its row).
        let rows = try AlbumTrack.fetchAll(db, sql: """
            SELECT * FROM album_tracks WHERE album_id = ? ORDER BY disc, position, track_id
            """, arguments: [loser])
        let tail = try String.fetchOne(db, sql: "SELECT MAX(position) FROM album_tracks WHERE album_id = ?", arguments: [winner])
        let keys = v50SeedKeys(count: rows.count, after: tail)
        for (row, key) in zip(rows, keys) {
            try db.execute(sql: """
                INSERT OR IGNORE INTO album_tracks (album_id, track_id, disc, position, track_number)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [winner, row.trackId, row.disc, key, row.trackNumber])
        }
        try db.execute(sql: "DELETE FROM album_tracks WHERE album_id = ?", arguments: [loser])

        // Variant preferences: the base moves (a winner that already has a preference keeps its
        // own and the loser's row goes); the selected variant moves.
        try db.execute(sql: "UPDATE OR IGNORE user_album_variant_pref SET base_album_id = ? WHERE base_album_id = ?",
                       arguments: [winner, loser])
        try db.execute(sql: "DELETE FROM user_album_variant_pref WHERE base_album_id = ?", arguments: [loser])
        try db.execute(sql: "UPDATE user_album_variant_pref SET selected_album_id = ? WHERE selected_album_id = ?",
                       arguments: [winner, loser])
        try db.execute(sql: "UPDATE albums SET variant_of = ? WHERE variant_of = ?", arguments: [winner, loser])

        try db.execute(sql: """
            UPDATE albums SET
                year = COALESCE(year, (SELECT year FROM albums WHERE id = ?)),
                cover_path = COALESCE(cover_path, (SELECT cover_path FROM albums WHERE id = ?))
            WHERE id = ?
            """, arguments: [loser, loser, winner])
        try db.execute(sql: "DELETE FROM albums WHERE id = ?", arguments: [loser])
    }

    /// `count` ascending position keys for the v50 seed: `a` + base-62 digits, evenly spread
    /// (the keys `FractionalIndexer.evenlySpaced` makes today — copied so a later change of the
    /// indexer never changes what this migration writes). After `tail` when rows were placed.
    static func v50SeedKeys(count: Int, after tail: String?) -> [String] {
        guard count > 0 else { return [] }
        let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var width = 2
        var capacity = digits.count * digits.count
        while capacity <= count {
            width += 1
            capacity *= digits.count
        }
        let step = capacity / (count + 1)
        return (1...count).map { index in
            var value = index * step
            var key = [Character](repeating: digits[0], count: width)
            for slot in stride(from: width - 1, through: 0, by: -1) {
                key[slot] = digits[value % digits.count]
                value /= digits.count
            }
            let spaced = "a" + String(key)
            return tail.map { "\($0)|\(spaced)" } ?? spaced
        }
    }
}
