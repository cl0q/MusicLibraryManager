import Foundation
import GRDB

/// Repository for playlist CRUD and track ordering.
///
/// Encapsulates all SQL for playlists, playlist_tracks, and playlist_tags.
final class PlaylistRepository: Sendable {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    // MARK: - Playlist CRUD

    /// Fetch all playlists, pinned first, then alphabetical.
    func fetchAll() async throws -> [Playlist] {
        try await database.read { db in
            try Playlist
                .order(Playlist.Columns.isPinned.desc, Playlist.Columns.name)
                .fetchAll(db)
        }
    }

    /// Fetch a single playlist by ID.
    func fetch(id: Int64) async throws -> Playlist? {
        try await database.read { db in
            try Playlist.fetchOne(db, id: id)
        }
    }

    /// Create a new native playlist.
    @discardableResult
    func create(name: String) async throws -> Playlist {
        try await database.write { db in
            var playlist = Playlist.createNative(name: name)
            try playlist.insert(db)
            return playlist
        }
    }

    /// Rename a playlist.
    func rename(id: Int64, name: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE playlists SET name = ? WHERE id = ?",
                arguments: [name, id]
            )
        }
    }

    /// Delete a playlist.
    func delete(id: Int64) async throws {
        _ = try await database.write { db in
            try Playlist.deleteOne(db, id: id)
        }
    }

    /// Toggle pin status.
    func togglePin(id: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE playlists SET is_pinned = CASE WHEN is_pinned = 1 THEN 0 ELSE 1 END WHERE id = ?",
                arguments: [id]
            )
        }
    }

    // MARK: - Playlist Tracks

    /// Fetch tracks in a playlist, ordered by position.
    func fetchTracks(playlistId: Int64) async throws -> [Track] {
        try await database.read { db in
            try Track.fetchAll(db, sql: """
                SELECT t.* FROM tracks t
                INNER JOIN playlist_tracks pt ON pt.track_id = t.id
                WHERE pt.playlist_id = ?
                ORDER BY pt.position
            """, arguments: [playlistId])
        }
    }

    /// Count tracks in a playlist.
    ///
    /// Joins `playlist_tracks` with `tracks` so the count matches what
    /// `fetchTracks` actually returns. Orphaned `playlist_tracks` rows
    /// (track_id pointing at a row no longer in `tracks` — possible because
    /// FK enforcement is off in the shared Tauri DB) are excluded.
    func trackCount(playlistId: Int64) async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM playlist_tracks pt
                INNER JOIN tracks t ON pt.track_id = t.id
                WHERE pt.playlist_id = ?
            """, arguments: [playlistId]) ?? 0
        }
    }

    /// Add a track to a playlist with a position.
    func addTrack(playlistId: Int64, trackId: Int64, position: String) async throws {
        try await database.write { db in
            var entry = PlaylistTrack(
                id: nil,
                playlistId: playlistId,
                trackId: trackId,
                position: position,
                addedAt: nil
            )
            try entry.insert(db, onConflict: .ignore)
        }
    }

    /// Add multiple tracks to a playlist in a single transaction.
    func addTracks(playlistId: Int64, trackIds: [Int64], startPosition: String) async throws {
        try await database.write { db in
            // Generate fractional positions by appending index
            for (index, trackId) in trackIds.enumerated() {
                let position = "\(startPosition)\(String(format: "%06d", index))"
                var entry = PlaylistTrack(
                    id: nil,
                    playlistId: playlistId,
                    trackId: trackId,
                    position: position,
                    addedAt: nil
                )
                try entry.insert(db, onConflict: .ignore)
            }
        }
    }

    /// Remove a track from a playlist.
    func removeTrack(playlistId: Int64, trackId: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?",
                arguments: [playlistId, trackId]
            )
        }
    }

    /// Reorder a track within a playlist.
    func reorderTrack(playlistId: Int64, trackId: Int64, newPosition: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE playlist_tracks SET position = ? WHERE playlist_id = ? AND track_id = ?",
                arguments: [newPosition, playlistId, trackId]
            )
        }
    }
}
