import Foundation
import GRDB

/// Repository for playlist CRUD and track ordering.
///
/// Encapsulates all SQL for playlists, playlist_tracks, and playlist_tags.
final class PlaylistRepository: Sendable {
    private let database: any DatabaseWriter

    // Must match SQLite CURRENT_TIMESTAMP format (space-separated, no T/Z)
    // because playlist_tracks.added_at is TEXT and sorted as a string.
    private static let addedAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

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

    /// Update the source ID of a playlist.
    func updateSourceId(id: Int64, sourceId: Int64?) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE playlists SET source_id = ? WHERE id = ?",
                arguments: [sourceId, id]
            )
        }
    }

    /// Atomically update both `source_id` and `external_id` on a playlist row.
    ///
    /// Used by the "Link Source" flow in PlaylistDetailView: the user pastes a
    /// remote playlist URL, we validate it, and on commit write both columns in
    /// a single UPDATE so observers never see a half-applied state (source_id
    /// pointing at a source with a stale or nil external_id, or vice versa).
    func updateSourceLink(id: Int64, sourceId: Int64?, externalId: String?) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE playlists SET source_id = ?, external_id = ? WHERE id = ?",
                arguments: [sourceId, externalId, id]
            )
        }
    }

    /// Delete a playlist.
    func delete(id: Int64) async throws {
        try await database.write { db in
            if let playlist = try Playlist.fetchOne(db, id: id), playlist.isLiked == 1 {
                throw PlaylistRepositoryError.cannotDeleteLikedPlaylist
            }
            // Foreign-key enforcement is disabled for compatibility with the
            // shared database, so declared cascades do not execute.
            try db.execute(sql: "DELETE FROM playlist_tracks WHERE playlist_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM playlist_tags WHERE playlist_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM sync_profile_playlists WHERE playlist_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM playlist_sync_snapshots WHERE playlist_id = ?", arguments: [id])
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
                SELECT t.*, pt.position AS playlist_position FROM tracks t
                INNER JOIN playlist_tracks pt ON pt.track_id = t.id
                WHERE pt.playlist_id = ?
                ORDER BY pt.position, pt.added_at ASC
            """, arguments: [playlistId])
        }
    }

    /// Fetch the playlists that contain a given track, pinned first then
    /// alphabetical — the same ordering `fetchAll()` uses.
    func fetchPlaylists(forTrackId trackId: Int64) async throws -> [Playlist] {
        try await database.read { db in
            try Playlist.fetchAll(db, sql: """
                SELECT p.* FROM playlists p
                INNER JOIN playlist_tracks pt ON pt.playlist_id = p.id
                WHERE pt.track_id = ?
                ORDER BY p.is_pinned DESC, p.name
            """, arguments: [trackId])
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

    /// Returns download health for every playlist in one query so card grids
    /// never perform a track query per visible playlist.
    func fetchDownloadStatuses() async throws -> [PlaylistDownloadStatus] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                WITH playlist_track_states AS (
                    SELECT
                        pt.playlist_id,
                        CASE
                            -- SQL deliberately identifies only a persisted local path.
                            -- File existence is verified by the detail availability snapshot.
                            WHEN TRIM(COALESCE(t.organized_path, '')) != '' THEN 'local_path'
                            WHEN LOWER(COALESCE(t.download_status, ''))
                                IN ('downloading', 'queued', 'in_progress', 'in-progress')
                                THEN 'downloading'
                            WHEN (t.download_failure IS NOT NULL
                                  AND TRIM(t.download_failure) != '')
                                OR LOWER(COALESCE(t.download_status, '')) IN ('failed', 'error')
                                THEN 'failed'
                            ELSE 'not_downloaded'
                        END AS availability_bucket
                    FROM playlist_tracks pt
                    INNER JOIN tracks t ON t.id = pt.track_id
                )
                SELECT
                    playlist_id,
                    COUNT(*) AS total_tracks,
                    SUM(CASE WHEN availability_bucket = 'local_path' THEN 1 ELSE 0 END) AS local_tracks,
                    SUM(CASE WHEN availability_bucket = 'downloading' THEN 1 ELSE 0 END) AS downloading_tracks,
                    SUM(CASE WHEN availability_bucket = 'failed' THEN 1 ELSE 0 END) AS failed_tracks,
                    SUM(CASE WHEN availability_bucket = 'not_downloaded' THEN 1 ELSE 0 END) AS not_downloaded_tracks
                FROM playlist_track_states
                GROUP BY playlist_id
            """)

            return rows.compactMap { row in
                guard let playlistID: Int64 = row["playlist_id"] else { return nil }
                return PlaylistDownloadStatus(
                    playlistID: playlistID,
                    totalTracks: (row["total_tracks"] as Int?) ?? 0,
                    localTracks: (row["local_tracks"] as Int?) ?? 0,
                    downloadingTracks: (row["downloading_tracks"] as Int?) ?? 0,
                    failedTracks: (row["failed_tracks"] as Int?) ?? 0,
                    notDownloadedTracks: (row["not_downloaded_tracks"] as Int?) ?? 0
                )
            }
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
                addedAt: Self.addedAtFormatter.string(from: Date())
            )
            try entry.insert(db, onConflict: .ignore)
        }
    }

    /// Add multiple tracks to a playlist in a single transaction.
    func addTracks(playlistId: Int64, trackIds: [Int64], startPosition: String) async throws {
        try await database.write { db in
            var currentPos = startPosition
            for (index, trackId) in trackIds.enumerated() {
                if index > 0 {
                    currentPos = FractionalIndexer.positionBetween(left: currentPos, right: nil)
                }
                var entry = PlaylistTrack(
                    id: nil,
                    playlistId: playlistId,
                    trackId: trackId,
                    position: currentPos,
                    addedAt: Self.addedAtFormatter.string(from: Date())
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

    /// Persist fractional positions for several tracks in a single transaction.
    ///
    /// Members get their `position` updated; non-members get a new
    /// `playlist_tracks` row inserted (with `added_at` left to its default).
    /// The read-then-branch avoids depending on the unique constraint so it
    /// also works on legacy databases where the constraint may be absent.
    func placeTracks(playlistId: Int64, placements: [(trackId: Int64, position: String)]) async throws {
        guard !placements.isEmpty else { return }
        try await database.write { db in
            let existingRows = try Row.fetchAll(db, sql: """
                SELECT track_id FROM playlist_tracks WHERE playlist_id = ?
            """, arguments: [playlistId])
            let existingIDs = Set(existingRows.compactMap { $0["track_id"] as? Int64 })

            for placement in placements {
                if existingIDs.contains(placement.trackId) {
                    try db.execute(
                        sql: "UPDATE playlist_tracks SET position = ? WHERE playlist_id = ? AND track_id = ?",
                        arguments: [placement.position, playlistId, placement.trackId]
                    )
                } else {
                    var entry = PlaylistTrack(
                        id: nil,
                        playlistId: playlistId,
                        trackId: placement.trackId,
                        position: placement.position,
                        addedAt: Self.addedAtFormatter.string(from: Date())
                    )
                    try entry.insert(db)
                }
            }
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
                dateCreated: ISO8601DateFormatter().string(from: Date()),
                mlmUuid: nil
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

    /// Find or create a regular (non-liked) source-linked playlist,
    /// keyed by `(sourceId, externalId)`. Used to mirror remote playlists
    /// (SoundCloud/Spotify/YouTube) into the local library while keeping
    /// them distinct from the special "Liked" playlist.
    @discardableResult
    func findOrCreateSourcePlaylist(
        name: String,
        sourceId: Int64,
        externalId: String
    ) async throws -> Playlist {
        try await database.write { db in
            if let existing = try Playlist
                .filter(Playlist.Columns.sourceId == sourceId)
                .filter(sql: "external_id = ?", arguments: [externalId])
                .filter(Playlist.Columns.isLiked == 0)
                .fetchOne(db)
            {
                // Keep the name in sync with upstream.
                if existing.name != name, let id = existing.id {
                    try db.execute(
                        sql: "UPDATE playlists SET name = ? WHERE id = ?",
                        arguments: [name, id]
                    )
                    if let updated = try Playlist.fetchOne(db, id: id) {
                        return updated
                    }
                }
                return existing
            }

            // Fallback: a row with the same (name, category='synced') already
            // exists — the UNIQUE(name, category) index would reject a fresh
            // INSERT. Adopt it in place (rewrite source_id/external_id) so a
            // re-import or a same-named playlist from another source doesn't
            // crash with "UNIQUE constraint failed: playlists.name,
            // playlists.category".
            if let clash = try Playlist
                .filter(Playlist.Columns.name == name)
                .filter(Playlist.Columns.category == "synced")
                .filter(Playlist.Columns.isLiked == 0)
                .fetchOne(db)
            {
                if let id = clash.id {
                    try db.execute(
                        sql: "UPDATE playlists SET source_id = ?, external_id = ? WHERE id = ?",
                        arguments: [sourceId, externalId, id]
                    )
                    if let updated = try Playlist.fetchOne(db, id: id) {
                        return updated
                    }
                }
                return clash
            }

            var playlist = Playlist(
                id: nil,
                name: name,
                description: nil,
                category: "synced",
                isLiked: 0,
                isSmart: 0,
                isPinned: 0,
                coverIsCustom: 0,
                coverImagePath: nil,
                coverImageUrl: nil,
                sourceId: sourceId,
                externalId: externalId,
                dateCreated: ISO8601DateFormatter().string(from: Date()),
                mlmUuid: nil
            )
            try playlist.insert(db)
            return playlist
        }
    }

    /// Create (or reuse) the local playlist that mirrors a remote source playlist,
    /// without ever clobbering an unrelated playlist that happens to share its name.
    ///
    /// - If a row already matches (sourceId, externalId) with isLiked == 0, that row IS
    ///   this same remote playlist: reuse it (idempotent re-import), syncing its name to
    ///   the upstream title only when the rename would not collide with another playlist.
    /// - Otherwise insert a new row with category "synced", choosing the first free name
    ///   by appending " 2", " 3", … so an existing same-named playlist is left untouched.
    ///
    /// Name uniqueness is checked case-insensitively across ALL playlists (any category,
    /// including the liked playlist) because the UI shows one flat name space, and the
    /// suffix loop is what keeps the UNIQUE(name, category) index satisfied instead of
    /// adopting a clashing row.
    @discardableResult
    func createSourcePlaylistPreservingExisting(
        name: String,
        sourceId: Int64,
        externalId: String
    ) async throws -> Playlist {
        try await database.write { db in
            // Reuse branch: match on (sourceId, externalId, isLiked == 0).
            if let existing = try Playlist
                .filter(Playlist.Columns.sourceId == sourceId)
                .filter(sql: "external_id = ?", arguments: [externalId])
                .filter(Playlist.Columns.isLiked == 0)
                .fetchOne(db)
            {
                // Sync the name to upstream only when the new name is free.
                if existing.name != name, let id = existing.id {
                    let collision = try Playlist
                        .filter(sql: "LOWER(name) = LOWER(?)", arguments: [name])
                        .fetchOne(db)
                    if collision == nil {
                        try db.execute(
                            sql: "UPDATE playlists SET name = ? WHERE id = ?",
                            arguments: [name, id]
                        )
                        if let updated = try Playlist.fetchOne(db, id: id) {
                            return updated
                        }
                    }
                }
                return existing
            }

            // Insert branch: find the first free name.
            let takenNames = try String.fetchAll(db, sql: "SELECT name FROM playlists")
            let takenLower = Set(takenNames.map { $0.lowercased() })

            let chosen: String
            if !takenLower.contains(name.lowercased()) {
                chosen = name
            } else {
                var found: String?
                for suffix in 2...500 {
                    let candidate = "\(name) \(suffix)"
                    if !takenLower.contains(candidate.lowercased()) {
                        found = candidate
                        break
                    }
                }
                guard let free = found else {
                    throw PlaylistRepositoryError.noUniquePlaylistNameAvailable(name)
                }
                chosen = free
            }

            var playlist = Playlist(
                id: nil,
                name: chosen,
                description: nil,
                category: "synced",
                isLiked: 0,
                isSmart: 0,
                isPinned: 0,
                coverIsCustom: 0,
                coverImagePath: nil,
                coverImageUrl: nil,
                sourceId: sourceId,
                externalId: externalId,
                dateCreated: ISO8601DateFormatter().string(from: Date()),
                mlmUuid: nil
            )
            try playlist.insert(db)
            return playlist
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
                    addedAt: Self.addedAtFormatter.string(from: Date())
                )
                try entry.insert(db, onConflict: .ignore)
            }
        }
    }

    // MARK: - iOS Sidecar Ingest Helpers (WP3)

    /// Find a playlist by its stable `mlm_uuid`.
    func findByMlmUuid(_ uuid: String) async throws -> Playlist? {
        try await database.read { db in
            try Playlist
                .filter(Playlist.Columns.mlmUuid == uuid)
                .fetchOne(db)
        }
    }

    /// Find a playlist by exact name (case-insensitive).
    func findByName(_ name: String) async throws -> Playlist? {
        try await database.read { db in
            try Playlist
                .filter(sql: "LOWER(name) = LOWER(?)", arguments: [name])
                .fetchOne(db)
        }
    }
}

enum PlaylistRepositoryError: LocalizedError {
    case cannotDeleteLikedPlaylist
    case noUniquePlaylistNameAvailable(String)

    var errorDescription: String? {
        switch self {
        case .cannotDeleteLikedPlaylist:
            return "Cannot delete a synchronized 'Liked' playlist."
        case .noUniquePlaylistNameAvailable(let baseName):
            return "Could not find a free playlist name derived from '\(baseName)' after 499 suffixed attempts."
        }
    }
}
