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

    /// Set the playlist's cover image path and the auto/custom lock flag.
    ///
    /// Called by `PlaylistCoverService` (Phase 36 Plan 02):
    ///   - after generating a new auto cover → `isCustom: false`
    ///   - after the user drops a custom image → `isCustom: true`
    ///   - when resetting to auto → `path: nil, isCustom: false`
    ///
    /// Atomic: both columns update in a single SQL statement so observers
    /// never see a half-applied state.
    ///
    /// - Parameter path: Relative path under
    ///   `~/Library/Application Support/com.musiclibrary.app/playlist-covers/`,
    ///   or nil to clear.
    /// - Parameter isCustom: true if the user explicitly set this cover
    ///   (auto-regen will skip this row).
    func setCoverPath(id: Int64, path: String?, isCustom: Bool) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE playlists SET cover_image_path = ?, cover_is_custom = ? WHERE id = ?",
                arguments: [path, isCustom ? 1 : 0, id]
            )
        }
    }

    // MARK: - Playlist Tracks

    /// Fetch tracks in a playlist, ordered by position with a deterministic
    /// tie-breaker on `added_at`.
    ///
    /// The `(position, added_at)` ordering is required by Phase 36 Plan 02
    /// (PlaylistCoverService): when the cover generator picks the first 4
    /// tracks, the selection must be stable across runs even if two
    /// `playlist_tracks` rows share an identical fractional position
    /// (a rare-but-possible state if the fractional indexer collides).
    func fetchTracks(playlistId: Int64) async throws -> [Track] {
        try await database.read { db in
            try Track.fetchAll(db, sql: """
                SELECT t.* FROM tracks t
                INNER JOIN playlist_tracks pt ON pt.track_id = t.id
                WHERE pt.playlist_id = ?
                ORDER BY pt.position, pt.added_at ASC
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

    /// Find or create the "Liked from <source>" playlist for a given
    /// source (SoundCloud, Spotify, …).
    ///
    /// Matching order:
    /// 1. Modern row: `source_id = sourceId AND is_liked = 1`.
    /// 2. Legacy row (Tauri-era): a playlist whose name matches one of
    ///    `legacyNameMatches` and that has no `source_id` yet. When
    ///    found, it gets upgraded in place (source_id + is_liked + name)
    ///    so the user's familiar playlist stays — its tracks are about
    ///    to be replaced by the caller anyway.
    /// 3. Otherwise create a fresh row.
    @discardableResult
    func findOrCreateLikedPlaylist(
        name: String,
        sourceId: Int64,
        externalId: String?,
        legacyNameMatches: [String] = []
    ) async throws -> Playlist {
        try await database.write { db in
            // 1 — modern match: same source_id + is_liked.
            if let existing = try Playlist
                .filter(Playlist.Columns.sourceId == sourceId)
                .filter(Playlist.Columns.isLiked == 1)
                .fetchOne(db)
            {
                return existing
            }

            // 2 — name-based match. is_liked=1 plus a recognisable name
            //     wins regardless of whether source_id is null OR already
            //     set (Tauri-era rows had source_id pointing at the old
            //     Tauri source table whose IDs don't survive to macOS).
            //     We adopt the row and rewrite its source_id.
            if !legacyNameMatches.isEmpty {
                let candidates = try Playlist
                    .filter(Playlist.Columns.isLiked == 1)
                    .fetchAll(db)
                let lowered = legacyNameMatches.map { $0.lowercased() }
                if let legacy = candidates.first(where: { p in
                    let n = p.name.lowercased()
                    return lowered.contains(where: { n.contains($0) })
                }) {
                    try db.execute(
                        sql: "UPDATE playlists SET source_id = ?, external_id = ?, is_liked = 1, name = ?, category = 'synced' WHERE id = ?",
                        arguments: [sourceId, externalId, name, legacy.id ?? -1]
                    )
                    if let id = legacy.id, let updated = try Playlist.fetchOne(db, id: id) {
                        return updated
                    }
                }
            }

            // 3 — fresh row
            var playlist = Playlist(
                id: nil,
                name: name,
                description: nil,
                category: "synced",
                isLiked: 1,
                isSmart: 0,
                isPinned: 0,
                coverIsCustom: 0,
                coverImagePath: nil,
                coverImageUrl: nil,
                sourceId: sourceId,
                externalId: externalId,
                dateCreated: ISO8601DateFormatter().string(from: Date())
            )
            try playlist.insert(db)
            return playlist
        }
    }

    /// Return every is_liked=1 playlist OTHER than `survivorId` whose
    /// name matches one of `legacyNameMatches`. Used by the SoundCloud
    /// sync to clean up duplicate Likes-playlists from earlier code
    /// paths.
    func findDuplicateLikedPlaylists(
        survivorId: Int64,
        legacyNameMatches: [String]
    ) async throws -> [Playlist] {
        guard !legacyNameMatches.isEmpty else { return [] }
        let lowered = legacyNameMatches.map { $0.lowercased() }
        return try await database.read { db in
            try Playlist
                .filter(Playlist.Columns.isLiked == 1)
                .filter(Playlist.Columns.id != survivorId)
                .fetchAll(db)
                .filter { p in
                    let n = p.name.lowercased()
                    return lowered.contains(where: { n.contains($0) })
                }
        }
    }

    /// Drop a duplicate playlist row and all its playlist_tracks rows.
    /// Used to reconcile the duplicate "SoundCloud Likes" / "Liked from
    /// SoundCloud" entries created on databases that lived through both
    /// the Tauri-era and the macOS-era sync code paths. The caller is
    /// responsible for repopulating the survivor (the SoundCloud sync
    /// runs `replaceTrackList` right after this merge call).
    func mergePlaylists(survivorId: Int64, victimId: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM playlist_tracks WHERE playlist_id = ?",
                arguments: [victimId]
            )
            try db.execute(
                sql: "DELETE FROM playlists WHERE id = ?",
                arguments: [victimId]
            )
        }
    }

    /// Replace the entire ordered track list for a playlist atomically.
    ///
    /// Used by source-sync code (SoundCloud Likes, Spotify Liked) to
    /// keep a playlist in lockstep with the upstream order. Positions
    /// are dense lexicographic strings ("000000000000", "000000000001", …)
    /// so existing position-based ordering keeps working.
    func replaceTrackList(playlistId: Int64, trackIds: [Int64]) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM playlist_tracks WHERE playlist_id = ?",
                arguments: [playlistId]
            )
            for (index, trackId) in trackIds.enumerated() {
                let position = String(format: "%012d", index)
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
}
