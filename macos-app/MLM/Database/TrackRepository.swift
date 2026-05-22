import Foundation
import GRDB

// MARK: - SortColumn

/// Whitelist of sortable columns for library queries.
enum SortColumn: String, CaseIterable {
    case title, artist, album, dateAdded, duration, bitrate, year, energy, genre, format

    /// Maps to the actual SQLite column name.
    var sqlColumn: String {
        switch self {
        case .title:     return "title"
        case .artist:    return "artist"
        case .album:     return "album"
        case .dateAdded: return "date_added"
        case .duration:  return "duration"
        case .bitrate:   return "bitrate"
        case .year:      return "year"
        case .energy:    return "energy_bucket"
        case .genre:     return "genre"
        case .format:    return "format"
        }
    }
}

// MARK: - Repository

/// Repository for track CRUD, search, and filtering operations.
///
/// Encapsulates all SQL for the `tracks` domain, matching the
/// Tauri app's `src/database/tracks.rs` functionality.
final class TrackRepository: Sendable {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    // MARK: - Read

    /// Fetch all local tracks (organized_path IS NOT NULL).
    func fetchLocalTracks() async throws -> [Track] {
        try await database.read { db in
            try Track
                .filter(Track.Columns.organizedPath != nil)
                .order(Track.Columns.artist, Track.Columns.album, Track.Columns.title)
                .fetchAll(db)
        }
    }

    /// Fetch all remote tracks (organized_path IS NULL, has streaming source).
    func fetchRemoteTracks() async throws -> [Track] {
        try await database.read { db in
            try Track
                .filter(Track.Columns.organizedPath == nil)
                .order(Track.Columns.dateAdded.desc)
                .fetchAll(db)
        }
    }

    /// Fetch a single track by ID.
    func fetchTrack(id: Int64) async throws -> Track? {
        try await database.read { db in
            try Track.fetchOne(db, id: id)
        }
    }

    /// Fetch tracks by album ID.
    func fetchTracks(albumId: Int64) async throws -> [Track] {
        try await database.read { db in
            try Track
                .filter(Track.Columns.albumId == albumId)
                .order(Track.Columns.title)
                .fetchAll(db)
        }
    }

    /// Count local tracks.
    func countLocalTracks() async throws -> Int {
        try await database.read { db in
            try Track
                .filter(Track.Columns.organizedPath != nil)
                .fetchCount(db)
        }
    }

    /// Filter a set of candidate track IDs down to those that look like
    /// real playable local files: organized_path is set AND format is
    /// an audio container, not a streaming-service marker (`soundcloud`,
    /// `spotify`, `youtube`, …).
    ///
    /// Some legacy rows carry both an organized_path and a streaming-
    /// service format string. They show up as "local" in the UI but
    /// fail to play; we must not pull them into source playlists.
    func filterLocalIds(_ trackIds: [Int64]) async throws -> Set<Int64> {
        guard !trackIds.isEmpty else { return [] }
        let audioFormats: [String] = [
            "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "alac",
            "aiff", "aif", "wma", "ape", "wv", "mp4"
        ]
        return try await database.read { db in
            let rows = try Int64.fetchAll(
                db,
                Track
                    .filter(trackIds.contains(Track.Columns.id))
                    .filter(Track.Columns.organizedPath != nil)
                    .filter(audioFormats.contains(Track.Columns.format))
                    .select(Track.Columns.id, as: Int64.self)
            )
            return Set(rows)
        }
    }

    /// Count remote tracks.
    func countRemoteTracks() async throws -> Int {
        try await database.read { db in
            try Track
                .filter(Track.Columns.organizedPath == nil)
                .fetchCount(db)
        }
    }

    /// Search tracks by title, artist, or album.
    func search(query: String) async throws -> [Track] {
        let pattern = "%\(query)%"
        return try await database.read { db in
            try Track
                .filter(
                    Track.Columns.title.like(pattern) ||
                    Track.Columns.artist.like(pattern) ||
                    Track.Columns.album.like(pattern)
                )
                .order(Track.Columns.artist, Track.Columns.title)
                .fetchAll(db)
        }
    }

    /// Fetch tracks in a folder (by organized_path prefix).
    func fetchTracks(folderPrefix: String) async throws -> [Track] {
        let pattern = "\(folderPrefix)%"
        return try await database.read { db in
            try Track
                .filter(Track.Columns.organizedPath.like(pattern))
                .order(Track.Columns.title)
                .fetchAll(db)
        }
    }

    /// Fetch tracks for the library browser with SQL-side sort and filter.
    ///
    /// - Parameters:
    ///   - tab: Local (organized_path IS NOT NULL) or Remote (IS NULL).
    ///   - search: Optional search string matched against artist, album, title.
    ///   - sortBy: Column to sort by (whitelist-safe, no SQL injection possible).
    ///   - ascending: Sort direction.
    ///   - limit: Optional row cap.
    func fetchForLibrary(
        tab: LibraryTab,
        search: String?,
        sortBy: SortColumn,
        ascending: Bool,
        limit: Int? = nil
    ) async throws -> [Track] {
        var conditions: [String] = []
        var args: [DatabaseValueConvertible] = []

        switch tab {
        case .local:  conditions.append("organized_path IS NOT NULL")
        case .remote: conditions.append("organized_path IS NULL")
        }

        let trimmed = search?.trimmingCharacters(in: .whitespaces) ?? ""
        if !trimmed.isEmpty {
            let normalized = DatabaseManager.foldedSearchText(trimmed)
            conditions.append("search_text LIKE ?")
            args.append("%\(normalized)%")
        }

        let where_ = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let order   = ascending ? "ASC" : "DESC"
        // sortBy.sqlColumn is from a closed enum — safe to interpolate.
        let limitSQL = limit.map { "LIMIT \($0)" } ?? ""

        let sql = """
            SELECT * FROM tracks
            \(where_)
            ORDER BY \(sortBy.sqlColumn) \(order) NULLS LAST
            \(limitSQL)
            """

        let stmtArgs = StatementArguments(args) ?? StatementArguments()
        return try await database.read { db in
            try Track.fetchAll(db, sql: sql, arguments: stmtArgs)
        }
    }

    /// Fetch all distinct organized_path values for building the folder tree.
    func fetchAllOrganizedPaths() async throws -> [String] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT organized_path
                FROM tracks
                WHERE organized_path IS NOT NULL
            """)
            return rows.compactMap { $0["organized_path"] as? String }
        }
    }

    /// Fetch tracks whose original_path matches any of the given paths.
    ///
    /// Both the stored paths and the input are normalized via
    /// `standardizedFileURL.path` before comparison to handle
    /// URL-encoding differences and trailing-slash variants.
    func fetchTracksByOriginalPaths(_ paths: [String]) async throws -> [Track] {
        guard !paths.isEmpty else { return [] }
        let normalized = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let placeholders = normalized.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT * FROM tracks
            WHERE original_path IN (\(placeholders))
            ORDER BY title COLLATE NOCASE
            """
        let args = StatementArguments(normalized.map { $0 as DatabaseValueConvertible }) ?? StatementArguments()
        return try await database.read { db in
            try Track.fetchAll(db, sql: sql, arguments: args)
        }
    }

    /// Fetch tracks directly in a folder (one level deep, no sub-folders).
    func fetchTracksInFolder(path: String) async throws -> [Track] {
        let prefixPattern = path + "/%"
        let deeperPattern = path + "/%/%"
        return try await database.read { db in
            try Track.fetchAll(db, sql: """
                SELECT * FROM tracks
                WHERE organized_path LIKE ?
                  AND organized_path NOT LIKE ?
                ORDER BY title COLLATE NOCASE
            """, arguments: [prefixPattern, deeperPattern])
        }
    }

    /// Fetch distinct folder prefixes from organized_path.
    func fetchFolderPrefixes() async throws -> [String] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT
                    CASE
                        WHEN INSTR(organized_path, '/') > 0
                        THEN SUBSTR(organized_path, 1, INSTR(organized_path, '/') - 1)
                        ELSE organized_path
                    END as folder_prefix
                FROM tracks
                WHERE organized_path IS NOT NULL
                ORDER BY folder_prefix
            """)
            return rows.compactMap { $0["folder_prefix"] as? String }
        }
    }

    /// Fetch all distinct organized_path directory paths for building a folder tree.
    ///
    /// Returns every unique directory path found in `organized_path` values,
    /// e.g. `["Artist A", "Artist A/Album 1", "Artist A/Album 2", "Artist B"]`.
    func fetchAllFolderPaths() async throws -> [String] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT
                    CASE
                        WHEN INSTR(organized_path, '/') > 0
                        THEN SUBSTR(organized_path, 1, LENGTH(organized_path) - LENGTH(
                            SUBSTR(organized_path, LENGTH(organized_path) - INSTR(REVERSE(organized_path), '/') + 2)
                        ))
                        ELSE NULL
                    END as dir_path
                FROM tracks
                WHERE organized_path IS NOT NULL
            """)

            // Collect all unique directory components at every level
            var dirs = Set<String>()
            for row in rows {
                guard let dirPath = row["dir_path"] as? String, !dirPath.isEmpty else { continue }
                // Add the full path and all parent paths
                let components = dirPath.split(separator: "/")
                for i in 1...components.count {
                    let path = components.prefix(i).joined(separator: "/")
                    dirs.insert(path)
                }
            }
            return dirs.sorted()
        }
    }

    /// Fetch immediate child folder names under a given parent path.
    ///
    /// - Parameter parentPath: The parent folder path (empty string for root level).
    /// - Returns: Array of child folder names (not full paths).
    func fetchChildFolders(under parentPath: String) async throws -> [String] {
        try await database.read { db in
            let sql: String
            let args: StatementArguments

            if parentPath.isEmpty {
                // Root level: get the first path component
                sql = """
                    SELECT DISTINCT
                        CASE
                            WHEN INSTR(organized_path, '/') > 0
                            THEN SUBSTR(organized_path, 1, INSTR(organized_path, '/') - 1)
                            ELSE NULL
                        END as child_name
                    FROM tracks
                    WHERE organized_path IS NOT NULL
                    ORDER BY child_name COLLATE NOCASE
                """
                args = []
            } else {
                // Sub-level: get immediate children under parentPath
                let prefix = parentPath + "/"
                sql = """
                    SELECT DISTINCT
                        CASE
                            WHEN INSTR(SUBSTR(organized_path, ?), '/') > 0
                            THEN SUBSTR(
                                SUBSTR(organized_path, ?),
                                1,
                                INSTR(SUBSTR(organized_path, ?), '/') - 1
                            )
                            ELSE NULL
                        END as child_name
                    FROM tracks
                    WHERE organized_path LIKE ? AND organized_path != ?
                    ORDER BY child_name COLLATE NOCASE
                """
                let prefixLen = prefix.count + 1  // +1 for 1-based SQL SUBSTR
                args = [prefixLen, prefixLen, prefixLen, prefix + "%", parentPath]
            }

            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            return rows.compactMap { $0["child_name"] as? String }
        }
    }

    /// Count tracks directly in a folder (not counting subfolders).
    func countTracks(in folderPath: String) async throws -> Int {
        try await database.read { db in
            // Tracks whose organized_path starts with folderPath/ but has no further /
            let pattern = folderPath + "/%"
            let deeperPattern = folderPath + "/%/%"
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tracks
                WHERE organized_path LIKE ?
                AND organized_path NOT LIKE ?
            """, arguments: [pattern, deeperPattern]) ?? 0
        }
    }

    // MARK: - Write

    /// Insert a new track, returning the inserted track with its ID.
    @discardableResult
    func insert(_ track: Track) async throws -> Track {
        try await database.write { db in
            var track = track
            track.searchText = DatabaseManager.foldedSearchText(
                track.artist + " " + track.album + " " + track.title
            )
            try track.insert(db)
            return track
        }
    }

    /// Update an existing track.
    func update(_ track: Track) async throws {
        try await database.write { db in
            var track = track
            track.searchText = DatabaseManager.foldedSearchText(
                track.artist + " " + track.album + " " + track.title
            )
            try track.update(db)
        }
    }

    /// Delete a track by ID.
    func delete(id: Int64) async throws {
        _ = try await database.write { db in
            try Track.deleteOne(db, id: id)
        }
    }

    /// Delete multiple tracks by IDs.
    func delete(ids: [Int64]) async throws {
        try await database.write { db in
            try Track.deleteAll(db, ids: ids)
        }
    }

    /// Update download status for a track.
    func updateDownloadStatus(trackId: Int64, status: String?, organizedPath: String?) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE tracks SET download_status = ?, organized_path = ?
                    WHERE id = ?
                """,
                arguments: [status, organizedPath, trackId]
            )
        }
    }

    /// Update just the organized_path for a track (after download).
    func updateOrganizedPath(trackId: Int64, organizedPath: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE tracks SET organized_path = ?, download_status = 'completed' WHERE id = ?",
                arguments: [organizedPath, trackId]
            )
        }
    }

    /// Rewrite only the organized_path column — leaves download_status,
    /// format, and bitrate untouched. Used by the stale-path repair
    /// maintenance action (Task 4): the track has already been downloaded,
    /// so we must not clobber its existing download_status timestamp.
    func setOrganizedPathOnly(trackId: Int64, organizedPath: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE tracks SET organized_path = ? WHERE id = ?",
                arguments: [organizedPath, trackId]
            )
        }
    }

    /// Demote a track back to remote-only by clearing organized_path
    /// AND download_status together. Used by the repair pass when a row
    /// carries a stale staging path but the original_path is a streaming
    /// URL (so there was never a real local file to begin with).
    func demoteToRemote(trackId: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE tracks SET organized_path = NULL, download_status = NULL WHERE id = ?",
                arguments: [trackId]
            )
        }
    }

    /// Mark a remote track as downloaded by updating `organized_path`,
    /// `format`, `bitrate`, and `download_status` together in a single SQL
    /// UPDATE.
    ///
    /// Updating only `organized_path` (as the previous helper did) leaves
    /// the Library showing stale "0 kbps soundcloud" rows for tracks that
    /// have actually been downloaded — this helper fixes all four columns
    /// atomically.
    ///
    /// - Parameters:
    ///   - trackId: The track ID.
    ///   - organizedPath: Library-relative path (e.g. `00_Artists/<file>.m4a`).
    ///   - format: New container format (e.g. `"m4a"`, `"flac"`).
    ///   - bitrate: New bitrate in kbps, or `nil` if unknown.
    ///   - downloadStatus: ISO 8601 timestamp string, or `nil` to leave
    ///     untouched (defaults to current time).
    func markAsDownloaded(
        trackId: Int64,
        organizedPath: String,
        format: String,
        bitrate: Int?,
        downloadStatus: String? = nil
    ) async throws {
        let timestamp = downloadStatus ?? ISO8601DateFormatter().string(from: Date())
        try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE tracks
                    SET organized_path = ?,
                        format = ?,
                        bitrate = ?,
                        download_status = ?
                    WHERE id = ?
                """,
                arguments: [organizedPath, format, bitrate, timestamp, trackId]
            )
        }
    }

    /// Fetch tracks that lack fingerprints (for analysis batch).
    func fetchUnfingerprintedTracks() async throws -> [Track] {
        try await database.read { db in
            try Track.fetchAll(db, sql: """
                SELECT t.* FROM tracks t
                LEFT JOIN fingerprints f ON f.track_id = t.id
                WHERE f.track_id IS NULL AND t.organized_path IS NOT NULL
                ORDER BY t.id
            """)
        }
    }

    /// Fetch tracks that lack ReplayGain analysis.
    func fetchUnanalyzedTracks() async throws -> [Track] {
        try await database.read { db in
            try Track.fetchAll(db, sql: """
                SELECT t.* FROM tracks t
                LEFT JOIN replaygain r ON r.track_id = t.id
                WHERE r.track_id IS NULL AND t.organized_path IS NOT NULL
                ORDER BY t.id
            """)
        }
    }

    /// Fetch tracks that lack artwork.
    func fetchTracksWithoutArtwork() async throws -> [Track] {
        try await database.read { db in
            try Track.fetchAll(db, sql: """
                SELECT t.* FROM tracks t
                LEFT JOIN artwork a ON a.track_id = t.id
                WHERE a.track_id IS NULL AND t.organized_path IS NOT NULL
                ORDER BY t.id
            """)
        }
    }

    /// Update energy bucket for a track.
    func updateEnergyBucket(trackId: Int64, energyBucket: Int, lufsI: Double) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE tracks SET energy_bucket = ?, lufs_i = ? WHERE id = ?",
                arguments: [energyBucket, lufsI, trackId]
            )
        }
    }

    /// Mark a track as a duplicate of another.
    func markDuplicate(trackId: Int64, variantOf: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE tracks SET is_duplicate = 1, variant_of = ? WHERE id = ?",
                arguments: [variantOf, trackId]
            )
        }
    }

    /// Fetch all non-duplicate tracks that have fingerprints.
    func fetchFingerprintedTracks() async throws -> [Track] {
        try await database.read { db in
            try Track.fetchAll(db, sql: """
                SELECT t.* FROM tracks t
                INNER JOIN fingerprints f ON f.track_id = t.id
                WHERE t.is_duplicate = 0
                ORDER BY t.id
            """)
        }
    }

    /// Resolve all track IDs for a sync profile (union of manual + playlists + rules).
    func fetchTrackIdsForSyncProfile(
        profileId: Int64,
        rules: [SyncProfileRule]
    ) async throws -> Set<Int64> {
        try await database.read { db in
            var trackIds = Set<Int64>()

            // 1. Manual tracks
            let manualRows = try Row.fetchAll(db, sql: """
                SELECT track_id FROM sync_profile_tracks WHERE profile_id = ?
            """, arguments: [profileId])
            trackIds.formUnion(manualRows.compactMap { $0["track_id"] as? Int64 })

            // 2. Playlist tracks
            let playlistRows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT pt.track_id FROM sync_profile_playlists spp
                INNER JOIN playlist_tracks pt ON pt.playlist_id = spp.playlist_id
                WHERE spp.profile_id = ?
            """, arguments: [profileId])
            trackIds.formUnion(playlistRows.compactMap { $0["track_id"] as? Int64 })

            // 3. Rule-based (build SQL dynamically)
            for rule in rules {
                let ruleTrackIds = try self.resolveRule(db: db, rule: rule)
                trackIds.formUnion(ruleTrackIds)
            }

            return trackIds
        }
    }

    /// Resolve a single filter rule to a set of track IDs.
    private func resolveRule(db: Database, rule: SyncProfileRule) throws -> [Int64] {
        let field = rule.field
        let op = rule.operator
        let value = rule.value

        let sql: String
        let args: StatementArguments

        switch field {
        case "genre":
            sql = "SELECT id FROM tracks WHERE genre \(sqlOperator(op)) ?"
            args = [value]
        case "artist":
            sql = "SELECT id FROM tracks WHERE artist \(sqlOperator(op)) ?"
            args = [value]
        case "bitrate":
            sql = "SELECT id FROM tracks WHERE bitrate \(sqlOperator(op)) CAST(? AS INTEGER)"
            args = [value]
        case "date_added":
            sql = "SELECT id FROM tracks WHERE date_added \(sqlOperator(op)) ?"
            args = [value]
        case "source":
            sql = """
                SELECT DISTINCT ts.track_id as id FROM track_sources ts
                INNER JOIN sources s ON s.id = ts.source_id
                WHERE s.source_type \(sqlOperator(op)) ?
            """
            args = [value]
        case "tag":
            sql = """
                SELECT DISTINCT track_id as id FROM track_tags
                WHERE tag_value \(sqlOperator(op)) ?
            """
            args = [value]
        default:
            return []
        }

        let rows = try Row.fetchAll(db, sql: sql, arguments: args)
        return rows.compactMap { $0["id"] as? Int64 }
    }

    private func sqlOperator(_ op: String) -> String {
        switch op {
        case "eq": "="
        case "ne": "!="
        case "gt": ">"
        case "lt": "<"
        case "contains": "LIKE"
        case "in": "IN"
        default: "="
        }
    }
}
