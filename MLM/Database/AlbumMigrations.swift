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
    /// only; no file is read. Tracks whose album text is empty or the importer's placeholder
    /// `unknown album` are not an album (DEC-021) and stay unlinked.
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
        for row in try Row.fetchAll(db, sql: "SELECT id, album_artist, title FROM albums WHERE variant_kind IS NULL ORDER BY id") {
            let key = AlbumKey.artistKey(row["album_artist"]) + "\u{1F}" + AlbumKey.normalize(row["title"])
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
            let key = AlbumKey.artistKey(filedUnder) + "\u{1F}" + AlbumKey.normalize(album)
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
            SELECT t.album_id AS album_id, t.id AS track_id
            FROM tracks t JOIN albums a ON a.id = t.album_id
            WHERE LOWER(a.title) <> '\(AlbumKey.unknownAlbumText)'
              AND NOT EXISTS (SELECT 1 FROM album_tracks x WHERE x.album_id = t.album_id AND x.track_id = t.id)
            ORDER BY t.album_id, t.title COLLATE NOCASE, t.id
            """)
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
