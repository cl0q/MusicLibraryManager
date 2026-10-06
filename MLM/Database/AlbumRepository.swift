import Foundation
import GRDB

/// Repository for album detection, variants, and sibling discovery.
final class AlbumRepository: Sendable {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    // MARK: - Read

    /// Fetch all albums, ordered by artist then title.
    func fetchAll() async throws -> [Album] {
        try await database.read { db in
            try Album
                .order(Album.Columns.albumArtist, Album.Columns.title)
                .fetchAll(db)
        }
    }

    /// Fetch a single album by ID.
    func fetch(id: Int64) async throws -> Album? {
        try await database.read { db in
            try Album.fetchOne(db, id: id)
        }
    }

    /// Fetch albums by artist (case-insensitive).
    func fetchAlbums(artist: String) async throws -> [Album] {
        try await database.read { db in
            try Album.fetchAll(db, sql: """
                SELECT * FROM albums
                WHERE LOWER(album_artist) = LOWER(?)
                ORDER BY title
            """, arguments: [artist])
        }
    }

    /// Fetch sibling albums (same base or variants of the same base).
    func fetchSiblings(albumId: Int64) async throws -> [Album] {
        try await database.read { db in
            // First find the base album
            guard let album = try Album.fetchOne(db, id: albumId) else {
                return []
            }
            let baseId = album.variantOf ?? album.id!

            // Fetch base + all variants
            return try Album.fetchAll(db, sql: """
                SELECT * FROM albums
                WHERE id = ? OR variant_of = ?
                ORDER BY variant_kind NULLS FIRST
            """, arguments: [baseId, baseId])
        }
    }

    /// Fetch distinct artists from the albums table.
    func fetchDistinctArtists() async throws -> [String] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT album_artist FROM albums
                ORDER BY album_artist
            """)
            return rows.compactMap { $0["album_artist"] as? String }
        }
    }

    // MARK: - Delete

    /// Delete an album and everything that points at it (foreign keys are disabled, so the
    /// cascades are written out): its `album_tracks` rows, variant preferences that name it,
    /// the `tracks.album_id` of its tracks and the `variant_of` of its variants.
    func delete(id: Int64) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM album_tracks WHERE album_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM user_album_variant_pref WHERE base_album_id = ? OR selected_album_id = ?", arguments: [id, id])
            try db.execute(sql: "UPDATE tracks SET album_id = NULL WHERE album_id = ?", arguments: [id])
            try db.execute(sql: "UPDATE albums SET variant_of = NULL WHERE variant_of = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM albums WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Variant Preferences

    /// Get the user's preferred variant for an album group.
    func fetchVariantPref(baseAlbumId: Int64, userId: String = "default") async throws -> Int64? {
        try await database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT selected_album_id FROM user_album_variant_pref
                WHERE user_id = ? AND base_album_id = ?
            """, arguments: [userId, baseAlbumId])?["selected_album_id"]
        }
    }

    /// Set the user's preferred variant for an album group.
    func setVariantPref(baseAlbumId: Int64, selectedAlbumId: Int64, userId: String = "default") async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO user_album_variant_pref
                (user_id, base_album_id, selected_album_id, updated_at)
                VALUES (?, ?, ?, datetime('now'))
            """, arguments: [userId, baseAlbumId, selectedAlbumId])
        }
    }
}
