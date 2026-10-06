import Foundation
import GRDB

/// Repository for playlist CRUD and track ordering.
///
/// Encapsulates all SQL for playlists, playlist_tracks, and playlist_tags.
final class PlaylistRepository: Sendable {
    /// Internal so the aggregate queries (`PlaylistAggregates.swift`) read the same database.
    let database: any DatabaseWriter

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

    /// Fetch all playlists in the sidebar's order (DEC-003, W3-PL): the user's manual order,
    /// each playlist folder's playlists where the folder is. Pinning is retired.
    func fetchAll() async throws -> [Playlist] {
        try await database.read { db in try Self.sidebarOrdered(db) }
    }

    /// Every playlist in sidebar order: the top-level rows in order, a folder's playlists in
    /// its place (`PlaylistSidebarOrder`).
    static func sidebarOrdered(_ db: Database) throws -> [Playlist] {
        let all = try Playlist.fetchAll(db)
        let byID = Dictionary(all.compactMap { playlist in playlist.id.map { ($0, playlist) } }, uniquingKeysWith: { first, _ in first })
        var ordered: [Playlist] = []
        for entry in try PlaylistFolderRepository.level(db, folderID: nil) {
            switch entry.item {
            case .playlist(let id):
                if let playlist = byID[id] { ordered.append(playlist) }
            case .folder(let id):
                ordered.append(contentsOf: try PlaylistFolderRepository.playlists(db, inFolder: id))
            }
        }
        return ordered
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

    /// Delete a playlist. A Liked playlist can be deleted too (UC §23 C10); a later Refresh
    /// from its source in Settings ▸ Sources creates it again (the alert says so).
    func delete(id: Int64) async throws {
        try await database.write { db in
            try Self.deleteWithDependents(db, id: id)
        }
    }

    /// Every table that refers to `playlists.id`. Foreign-key enforcement is disabled for
    /// compatibility with the shared database, so declared cascades do not execute: a
    /// delete removes these rows itself, and `snapshot` / `restore` carry them.
    static let dependentTables = ["playlist_tracks", "playlist_tags", "sync_profile_playlists", "playlist_sync_snapshots"]

    private static func deleteWithDependents(_ db: Database, id: Int64) throws {
        for table in dependentTables {
            try db.execute(sql: "DELETE FROM \(table) WHERE playlist_id = ?", arguments: [id])
        }
        try Playlist.deleteOne(db, id: id)
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

    /// Fetch the playlists that contain a given track, in sidebar order — the same ordering
    /// `fetchAll()` uses.
    func fetchPlaylists(forTrackId trackId: Int64) async throws -> [Playlist] {
        try await database.read { db in
            let containing = Set(try Int64.fetchAll(db, sql: """
                SELECT playlist_id FROM playlist_tracks WHERE track_id = ?
            """, arguments: [trackId]))
            return try Self.sidebarOrdered(db).filter { $0.id.map(containing.contains) ?? false }
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

    /// Append tracks after the playlist's actual tail in one writer
    /// transaction. Callers supply display order; duplicate IDs retain their
    /// existing membership and do not consume a new position.
    func appendTracks(playlistId: Int64, trackIds: [Int64]) async throws {
        _ = try await appendTracksReturningEntries(playlistId: playlistId, trackIds: trackIds)
    }

    /// `appendTracks`, reporting exactly which rows it inserted (so Undo removes those and
    /// never a row that was already there) and how many tracks were already in the playlist.
    func appendTracksReturningEntries(playlistId: Int64, trackIds: [Int64]) async throws -> PlaylistAppendResult {
        let orderedIDs = trackIds.reduce(into: [Int64]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard !orderedIDs.isEmpty else { return PlaylistAppendResult(entries: [], alreadyPresent: 0) }

        return try await database.write { db in
            let tail = try String.fetchOne(db, sql: """
                SELECT position FROM playlist_tracks
                WHERE playlist_id = ?
                ORDER BY position DESC, added_at DESC
                LIMIT 1
            """, arguments: [playlistId])

            let existingRows = try Int64.fetchAll(db, sql: """
                SELECT track_id FROM playlist_tracks WHERE playlist_id = ?
            """, arguments: [playlistId])
            let existingIDs = Set(existingRows)

            let newIDs = orderedIDs.filter { !existingIDs.contains($0) }
            let entries = try Self.insertEntries(db, playlistId: playlistId, trackIds: newIDs, after: tail)
            return PlaylistAppendResult(entries: entries, alreadyPresent: orderedIDs.count - newIDs.count)
        }
    }

    /// Insert `trackIds` in order after `tail` (fractional positions), returning the rows.
    private static func insertEntries(_ db: Database, playlistId: Int64, trackIds: [Int64], after tail: String?) throws -> [PlaylistTrack] {
        var tail = tail
        var inserted: [PlaylistTrack] = []
        for trackId in trackIds {
            let position = FractionalIndexer.positionBetween(left: tail, right: nil)
            var entry = PlaylistTrack(
                id: nil,
                playlistId: playlistId,
                trackId: trackId,
                position: position,
                addedAt: addedAtFormatter.string(from: Date())
            )
            try entry.insert(db)
            inserted.append(entry)
            tail = position
        }
        return inserted
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
            // Same manual cascade as `delete`: tags, sync profile links and device-ingest
            // snapshots of the merged-away playlist used to be left behind.
            try Self.deleteWithDependents(db, id: victimId)
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

    // MARK: - Undo support (W2-F): numbered create, snapshot / restore, exact rows

    /// `base`, or `base 2`, `base 3`, … — the first name not in `taken` (lower-cased names).
    /// The sidebar shows one flat name space, so callers pass the names of every playlist.
    static func numberedName(base: String, taken: Set<String>) -> String {
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// Create a native playlist named `baseName` (numbered when the name is taken) holding
    /// `trackIds` in that order, in one transaction — New Playlist and New Playlist from
    /// Selection are one step each (UC-UNDO-08).
    ///
    /// - Parameter folderID: a playlist folder (New Playlist in Folder, tracks dropped on a folder):
    ///   the new playlist goes last in it. Without one it goes first among the top-level rows
    ///   (`playlists.html`: a new row appears at the top, in rename mode).
    func createNumbered(baseName: String, trackIds: [Int64] = [], inFolder folderID: Int64? = nil) async throws -> Playlist {
        let orderedIDs = trackIds.reduce(into: [Int64]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        return try await database.write { db in
            let taken = Set(try String.fetchAll(db, sql: "SELECT name FROM playlists").map { $0.lowercased() })
            var playlist = Playlist.createNative(name: Self.numberedName(base: baseName, taken: taken))
            playlist.dateCreated = Self.addedAtFormatter.string(from: Date())
            if let folderID, try PlaylistFolder.fetchOne(db, id: folderID) != nil {
                playlist.folderId = folderID
                playlist.position = try PlaylistFolderRepository.lastPosition(db, folderID: folderID)
            } else {
                playlist.position = try PlaylistFolderRepository.firstPosition(db, folderID: nil)
            }
            try playlist.insert(db)
            if let id = playlist.id {
                _ = try Self.insertEntries(db, playlistId: id, trackIds: orderedIDs, after: nil)
            }
            return playlist
        }
    }

    /// Everything that belongs to one playlist, read in one transaction: the row (incl. source
    /// link, cover reference, `mlm_uuid`) and the rows of every table in `dependentTables`.
    func snapshot(id: Int64) async throws -> PlaylistSnapshot? {
        try await database.read { db in try Self.snapshot(db, id: id) }
    }

    /// Delete a playlist and return its snapshot (DEC-049: restorable with Undo until quit).
    func deleteReturningSnapshot(id: Int64) async throws -> PlaylistSnapshot {
        try await database.write { db in
            guard let snapshot = try Self.snapshot(db, id: id) else {
                throw PlaylistRepositoryError.playlistNotFound
            }
            try Self.deleteWithDependents(db, id: id)
            return snapshot
        }
    }

    /// Put a deleted playlist back from its snapshot, in one transaction.
    ///
    /// - Same playlist id (so sync profile links, routes and the cover file `‹id›.png` still
    ///   match) unless that id is in use; then a new id, and an auto cover named after the
    ///   old id is dropped (it is regenerated).
    /// - Same name unless another playlist took it meanwhile (any category, any letter case —
    ///   the sidebar is one name space); then the first free numbered name.
    /// - Still linked to its source unless another playlist was imported from the same source
    ///   playlist meanwhile; then this copy comes back unlinked, so the next refresh has one
    ///   target (`unlinked`).
    /// - Track rows keep their position, `added_at` and row id (when free); rows whose track
    ///   left the library meanwhile are skipped and counted. Tags come back; sync profile
    ///   links and sync snapshots come back for profiles that still exist.
    func restore(_ snapshot: PlaylistSnapshot) async throws -> PlaylistRestoreResult {
        try await database.write { db in
            var playlist = snapshot.playlist
            let originalID = playlist.id
            if let originalID, try Self.exists(db, table: "playlists", id: originalID) {
                playlist.id = nil
                let autoCover = "\(DatabaseManager.playlistCoversFolderName)/\(originalID).png"
                if playlist.coverImagePath == autoCover {
                    playlist.coverImagePath = nil
                    playlist.coverIsCustom = 0
                }
            }
            var unlinked: PlaylistRestoreResult.Unlink?
            if let sourceID = playlist.sourceId, let externalID = playlist.externalId,
               let other = try Playlist
                   .filter(Playlist.Columns.sourceId == sourceID)
                   .filter(sql: "external_id = ?", arguments: [externalID])
                   .filter(Playlist.Columns.isLiked == 0)
                   .fetchOne(db) {
                let sourceName = try String.fetchOne(db, sql: "SELECT name FROM sources WHERE id = ?", arguments: [sourceID])
                unlinked = .init(otherPlaylistName: other.name, sourceName: sourceName ?? "its source")
                playlist.sourceId = nil
                playlist.externalId = nil
            }
            // Back into its folder and its place (v45); a folder deleted meanwhile → the top
            // level, at the same position.
            if let folderID = playlist.folderId, try PlaylistFolder.fetchOne(db, id: folderID) == nil {
                playlist.folderId = nil
            }
            let nameTaken = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM playlists WHERE LOWER(name) = LOWER(?))
            """, arguments: [playlist.name]) ?? false
            if nameTaken {
                let taken = Set(try String.fetchAll(db, sql: "SELECT name FROM playlists").map { $0.lowercased() })
                playlist.name = Self.numberedName(base: playlist.name, taken: taken)
            }
            try playlist.insert(db)
            guard let id = playlist.id else { throw PlaylistRepositoryError.playlistNotFound }

            var droppedTracks = 0
            for var entry in snapshot.entries {
                guard try Self.exists(db, table: "tracks", id: entry.trackId) else {
                    droppedTracks += 1
                    continue
                }
                entry.playlistId = id
                if let rowID = entry.id, try Self.exists(db, table: "playlist_tracks", id: rowID) {
                    entry.id = nil
                }
                try entry.insert(db, onConflict: .ignore)
            }
            for tag in snapshot.tags {
                try db.execute(sql: "INSERT OR IGNORE INTO playlist_tags (playlist_id, tag) VALUES (?, ?)", arguments: [id, tag])
            }
            var droppedProfiles = 0
            for profileID in snapshot.syncProfileIDs {
                guard try Self.exists(db, table: "sync_profiles", id: profileID) else {
                    droppedProfiles += 1
                    continue
                }
                try db.execute(
                    sql: "INSERT OR IGNORE INTO sync_profile_playlists (profile_id, playlist_id) VALUES (?, ?)",
                    arguments: [profileID, id]
                )
            }
            for row in snapshot.syncSnapshots {
                guard try Self.exists(db, table: "sync_profiles", id: row.profileID) else { continue }
                let rowID: Int64? = try Self.exists(db, table: "playlist_sync_snapshots", id: row.id) ? nil : row.id
                try db.execute(sql: """
                    INSERT INTO playlist_sync_snapshots (id, profile_id, playlist_id, playlist_uuid, snapshot_json, written_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [rowID, row.profileID, id, row.playlistUUID, row.snapshotJSON, row.writtenAt])
            }
            return PlaylistRestoreResult(
                playlist: playlist,
                droppedTrackCount: droppedTracks,
                wasRenamed: nameTaken,
                droppedSyncProfileCount: droppedProfiles,
                unlinked: unlinked
            )
        }
    }

    /// What deleting a playlist touches, for the confirmation (A-PL-DELETE).
    func deletionImpact(id: Int64) async throws -> PlaylistDeletionImpact {
        try await database.read { db in
            let trackCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM playlist_tracks pt
                INNER JOIN tracks t ON pt.track_id = t.id
                WHERE pt.playlist_id = ?
            """, arguments: [id]) ?? 0
            let profiles = try String.fetchAll(db, sql: """
                SELECT sp.name FROM sync_profiles sp
                INNER JOIN sync_profile_playlists spp ON spp.profile_id = sp.id
                WHERE spp.playlist_id = ?
                ORDER BY sp.name
            """, arguments: [id])
            return PlaylistDeletionImpact(trackCount: trackCount, syncProfileNames: profiles)
        }
    }

    /// Remove exactly these rows (matched by row id, playlist and track — never another row
    /// of the same track) and return them as they were just before, for `restoreEntries`.
    /// Rows that are already gone are skipped.
    func removeEntries(_ entries: [PlaylistTrack]) async throws -> [PlaylistTrack] {
        try await database.write { db in
            var removed: [PlaylistTrack] = []
            for entry in entries {
                guard let rowID = entry.id,
                      let current = try PlaylistTrack.fetchOne(db, sql: """
                          SELECT * FROM playlist_tracks WHERE id = ? AND playlist_id = ? AND track_id = ?
                      """, arguments: [rowID, entry.playlistId, entry.trackId])
                else { continue }
                try db.execute(sql: "DELETE FROM playlist_tracks WHERE id = ?", arguments: [rowID])
                removed.append(current)
            }
            return removed
        }
    }

    /// Put removed rows back exactly: same position and `added_at`, same row id when it is
    /// free. A row is skipped when its playlist or track is gone or the track is in the
    /// playlist again. Returns the rows as inserted (for the next `removeEntries`).
    func restoreEntries(_ entries: [PlaylistTrack]) async throws -> [PlaylistTrack] {
        try await database.write { db in
            var restored: [PlaylistTrack] = []
            for var entry in entries {
                guard try Self.exists(db, table: "playlists", id: entry.playlistId),
                      try Self.exists(db, table: "tracks", id: entry.trackId),
                      try !(Bool.fetchOne(db, sql: """
                          SELECT EXISTS(SELECT 1 FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?)
                      """, arguments: [entry.playlistId, entry.trackId]) ?? false)
                else { continue }
                if let rowID = entry.id, try Self.exists(db, table: "playlist_tracks", id: rowID) {
                    entry.id = nil
                }
                try entry.insert(db)
                restored.append(entry)
            }
            return restored
        }
    }

    private static func snapshot(_ db: Database, id: Int64) throws -> PlaylistSnapshot? {
        guard let playlist = try Playlist.fetchOne(db, id: id) else { return nil }
        let entries = try PlaylistTrack.fetchAll(db, sql: """
            SELECT * FROM playlist_tracks WHERE playlist_id = ? ORDER BY position, added_at, id
        """, arguments: [id])
        let tags = try String.fetchAll(db, sql: "SELECT tag FROM playlist_tags WHERE playlist_id = ? ORDER BY tag", arguments: [id])
        let profileIDs = try Int64.fetchAll(db, sql: """
            SELECT profile_id FROM sync_profile_playlists WHERE playlist_id = ? ORDER BY profile_id
        """, arguments: [id])
        let syncSnapshots = try Row.fetchAll(db, sql: """
            SELECT id, profile_id, playlist_uuid, snapshot_json, written_at
            FROM playlist_sync_snapshots WHERE playlist_id = ? ORDER BY id
        """, arguments: [id]).map { row in
            PlaylistSyncSnapshotRow(
                id: row["id"],
                profileID: row["profile_id"],
                playlistUUID: row["playlist_uuid"],
                snapshotJSON: row["snapshot_json"],
                writtenAt: row["written_at"]
            )
        }
        return PlaylistSnapshot(
            playlist: playlist,
            entries: entries,
            tags: tags,
            syncProfileIDs: profileIDs,
            syncSnapshots: syncSnapshots
        )
    }

    private static func exists(_ db: Database, table: String, id: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE id = ?)", arguments: [id]) ?? false
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

enum PlaylistRepositoryError: LocalizedError, PlainCauseError {
    case noUniquePlaylistNameAvailable(String)
    case playlistNotFound

    var errorDescription: String? {
        switch self {
        case .noUniquePlaylistNameAvailable(let baseName):
            return "Could not find a free playlist name derived from '\(baseName)' after 499 suffixed attempts."
        case .playlistNotFound:
            return "The playlist does not exist."
        }
    }

    var plainCause: String {
        switch self {
        case .noUniquePlaylistNameAvailable: "every numbered name is taken"
        case .playlistNotFound: "the playlist no longer exists"
        }
    }
}

// MARK: - Undo values

/// Inserted rows of an append, and how many of the tracks were already in the playlist.
struct PlaylistAppendResult: Sendable {
    let entries: [PlaylistTrack]
    let alreadyPresent: Int
}

/// A playlist and every row that refers to it (see `PlaylistRepository.dependentTables`).
struct PlaylistSnapshot: Sendable {
    /// The `playlists` row as it was: id, name, category, source link, cover path and lock,
    /// pin, `mlm_uuid`, creation date.
    let playlist: Playlist
    /// `playlist_tracks` rows in playlist order, with row ids, positions and `added_at`.
    let entries: [PlaylistTrack]
    /// `playlist_tags`.
    let tags: [String]
    /// `sync_profile_playlists`: the profiles that sync this playlist.
    let syncProfileIDs: [Int64]
    /// `playlist_sync_snapshots`: the last exported track list per sync profile (device ingest).
    let syncSnapshots: [PlaylistSyncSnapshotRow]
}

/// One `playlist_sync_snapshots` row, kept verbatim.
struct PlaylistSyncSnapshotRow: Sendable, Equatable {
    let id: Int64
    let profileID: Int64
    let playlistUUID: String?
    let snapshotJSON: String
    let writtenAt: DatabaseValue
}

struct PlaylistRestoreResult: Sendable {
    /// The restored row (its id differs from the snapshot's only if that id was in use).
    let playlist: Playlist
    /// Track rows not restored because the track left the library meanwhile.
    let droppedTrackCount: Int
    /// The old name was taken meanwhile; `playlist.name` is a numbered one.
    let wasRenamed: Bool
    /// Sync profile links not restored because the profile was deleted meanwhile.
    var droppedSyncProfileCount = 0
    /// Set when another playlist was imported from the same source playlist meanwhile: this
    /// copy came back without its source link.
    var unlinked: Unlink?

    struct Unlink: Sendable, Equatable {
        /// Name of the playlist that now holds the link.
        let otherPlaylistName: String
        /// Stored source name (`soundcloud`).
        let sourceName: String
    }
}

struct PlaylistDeletionImpact: Sendable, Equatable {
    let trackCount: Int
    let syncProfileNames: [String]
}
