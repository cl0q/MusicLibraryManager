import Foundation
import GRDB

/// How albums are told apart (W4-1, IMP-067/068).
///
/// The `albums` table has been keyed since v16 by (album artist, `title_normalized`); the title
/// normalisation lived only in SQL (`LOWER(REPLACE(REPLACE(REPLACE(album,' ',''),'-',''),'_',''))`).
/// This is the same normalisation in Swift, applied after Unicode NFC (so `é` typed as two
/// scalars and as one are one album) and to every whitespace character, not only the space.
enum AlbumKey {
    /// The `title_normalized` of an album title: NFC, lowercased, with whitespace, `-` and `_` removed.
    static func normalize(_ title: String) -> String {
        let folded = title.precomposedStringWithCanonicalMapping.lowercased()
        return String(folded.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && scalar != "-" && scalar != "_"
        })
    }

    /// The album artist key: trimmed, NFC, lowercased.
    static func artistKey(_ artist: String) -> String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The artist an album is filed under: the album artist, else the track artist.
    static func effectiveArtist(albumArtist: String, artist: String) -> String {
        let trimmed = albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? artist : albumArtist
    }

    /// `album` names no album (DEC-021): empty, the importer's `unknown album`, a source name or a
    /// URL stored as album — the one decision every view uses (`TrackMetadataPresentation`).
    static func isNoAlbum(_ album: String) -> Bool {
        !TrackMetadataPresentation.isRealAlbum(album)
    }

    /// Finds the base album (no variant kind) with this key or creates it. Returns its id.
    static func findOrCreate(_ db: Database, artist: String, albumArtist: String, title: String, year: Int?) throws -> Int64 {
        let filedUnder = effectiveArtist(albumArtist: albumArtist, artist: artist)
        let normalized = normalize(title)
        let wantedArtist = artistKey(filedUnder)
        let candidates = try Row.fetchAll(db, sql: """
            SELECT id, album_artist FROM albums
            WHERE variant_kind IS NULL AND LOWER(album_artist) = LOWER(?) AND title_normalized = ?
            ORDER BY id
            """, arguments: [filedUnder, normalized])
        if let hit = candidates.first(where: { artistKey($0["album_artist"]) == wantedArtist }) { return hit["id"] }
        try db.execute(sql: """
            INSERT OR IGNORE INTO albums (artist, album_artist, title, title_normalized, year)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [artist, filedUnder, title, normalized, year])
        if db.changesCount > 0 { return db.lastInsertedRowID }
        // The unique index (case-insensitive artist, normalised title, kind) refused it: that row is the album.
        if let id = try Int64.fetchOne(db, sql: """
            SELECT id FROM albums WHERE variant_kind IS NULL AND LOWER(album_artist) = LOWER(?) AND title_normalized = ?
            ORDER BY id LIMIT 1
            """, arguments: [filedUnder, normalized]) { return id }
        throw DatabaseError(message: "The album “\(title)” could not be created.")
    }
}

/// One track's place in an album (`album_tracks`, v50, IMP-067): `disc` then the fractional
/// `position` (the same keys as `playlist_tracks`) give the order; `trackNumber` is what the
/// file's tag said (nil = not read yet).
struct AlbumTrack: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    var albumId: Int64
    var trackId: Int64
    var disc: Int
    var position: String
    var trackNumber: Int?

    static let databaseTableName = "album_tracks"

    enum CodingKeys: String, CodingKey {
        case albumId = "album_id"
        case trackId = "track_id"
        case disc, position
        case trackNumber = "track_number"
    }
}
