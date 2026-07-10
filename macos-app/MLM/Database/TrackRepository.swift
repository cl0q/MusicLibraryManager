import Foundation
import GRDB

// MARK: - SortColumn

/// Whitelist of sortable columns for library queries.
enum SortColumn: String, CaseIterable {
    case title, artist, album, dateAdded, duration, bitrate, year, energy, danceability, genre, format

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
        case .danceability: return "danceability"
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

    /// Fetch all track IDs that have an associated artwork path.
    func fetchTrackIdsWithArtwork() async throws -> Set<Int64> {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT track_id FROM artwork WHERE artwork_path IS NOT NULL
            """)
            return Set(rows.compactMap { $0["track_id"] as? Int64 })
        }
    }

    /// Fetch all tracks (both local and remote).
    func fetchAllTracks() async throws -> [Track] {
        try await database.read { db in
            try Track
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

        let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            let terms = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            for term in terms {
                let normalized = DatabaseManager.foldedSearchText(term)
                conditions.append("search_text LIKE ?")
                args.append("%\(normalized)%")
            }
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
            track.searchText = DatabaseManager.foldedSearchText(track.rawSearchText)
            try track.insert(db)
            return track
        }
    }

    /// Update an existing track.
    func update(_ track: Track) async throws {
        try await database.write { db in
            var track = track
            track.searchText = DatabaseManager.foldedSearchText(track.rawSearchText)
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

    /// Rewrite both organized_path and original_path columns.
    /// Used by the directory-rename repair maintenance action.
    func setPathsOnly(trackId: Int64, organizedPath: String, originalPath: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE tracks SET organized_path = ?, original_path = ? WHERE id = ?",
                arguments: [organizedPath, originalPath, trackId]
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

    /// Fetch tracks that lack Danceability analysis.
    func fetchTracksWithoutDanceability() async throws -> [Track] {
        try await database.read { db in
            try Track.fetchAll(db, sql: """
                SELECT * FROM tracks
                WHERE danceability IS NULL AND organized_path IS NOT NULL
                ORDER BY id
            """)
        }
    }

    /// Fetch tracks that lack Groove (CoreML audio embedding) analysis.
    func fetchTracksWithoutGrooveEmbedding() async throws -> [Track] {
        try await database.read { db in
            try Track.fetchAll(db, sql: """
                SELECT t.* FROM tracks t
                LEFT JOIN track_embeddings e ON e.track_id = t.id
                WHERE e.track_id IS NULL AND t.organized_path IS NOT NULL
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

    /// Update energy bucket and loudness info for a track.
    func updateEnergyBucket(
        trackId: Int64,
        energyBucket: Int,
        lufsI: Double,
        lufsRange: Double? = nil,
        truePeak: Double? = nil
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE tracks SET energy_bucket = ?, lufs_i = ?, lufs_range = ?, true_peak = ? WHERE id = ?",
                arguments: [energyBucket, lufsI, lufsRange, truePeak, trackId]
            )
        }
    }

    /// Update danceability for a track.
    func updateDanceability(
        trackId: Int64,
        danceability: Double
    ) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE tracks SET danceability = ? WHERE id = ?",
                arguments: [danceability, trackId]
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

    /// Fetch track by external ID linked to a specific source name.
    func fetchTrackByExternalId(_ externalId: String, sourceName: String) async throws -> Track? {
        try await database.read { db in
            try Track.fetchOne(db, sql: """
                SELECT t.* FROM tracks t
                INNER JOIN track_sources ts ON ts.track_id = t.id
                INNER JOIN sources s ON s.id = ts.source_id
                WHERE ts.external_id = ? AND s.name = ?
                LIMIT 1
            """, arguments: [externalId, sourceName])
        }
    }

    /// Fetch track by SoundCloud permalink/schemes.
    func fetchTrackBySoundCloudPath(externalId: String, permalink: String?) async throws -> Track? {
        var paths = ["soundcloud://\(externalId)", "https://api.soundcloud.com/tracks/\(externalId)"]
        if let permalink = permalink, !permalink.isEmpty {
            paths.append(permalink)
        }
        return try await database.read { db in
            try Track.fetchOne(db, sql: """
                SELECT * FROM tracks
                WHERE original_path IN (\(paths.map { _ in "?" }.joined(separator: ", ")))
                LIMIT 1
            """, arguments: StatementArguments(paths))
        }
    }

    // MARK: - Smart Audio Embeddings & Similarity Feedback

    /// Save a track's master audio embedding.
    func saveTrackEmbedding(trackId: Int64, embedding: [Float], dropOffset: Double, mixCategory: String?) async throws {
        try await database.write { db in
            let masterData = embedding.toData
            var row = TrackEmbedding(
                trackId: trackId,
                masterEmbeddingData: masterData,
                dropOffset: dropOffset,
                mixCategory: mixCategory
            )
            try row.insert(db, onConflict: .replace)
        }
    }

    /// Save a track's detailed 10-second segment embeddings.
    func saveTrackSegmentEmbeddings(trackId: Int64, segments: [(offset: Double, embedding: [Float])]) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM track_segment_embeddings WHERE track_id = ?", arguments: [trackId])
            for segment in segments {
                var row = TrackSegmentEmbedding(
                    trackId: trackId,
                    offsetSeconds: segment.offset,
                    segmentEmbeddingData: segment.embedding.toData
                )
                try row.insert(db)
            }
        }
    }

    /// Save similarity thumbs up/down feedback for a seed track and target track.
    func saveSimilarityFeedback(seedTrackId: Int64, targetTrackId: Int64, feedbackValue: Int) async throws {
        try await database.write { db in
            var row = TrackSimilarityFeedback(
                seedTrackId: seedTrackId,
                targetTrackId: targetTrackId,
                feedbackValue: feedbackValue
            )
            try row.insert(db, onConflict: .replace)
        }
    }

    /// Fetch similar tracks based on a composite score of CoreML embeddings, Danceability, LUFS, and genres.
    ///
    /// - Parameters:
    ///   - seedTrackId: The track ID to find matches for.
    ///   - limit: Maximum matches to return.
    /// - Returns: A ranked list of matching tracks with their similarity score and best matching segment timestamp.
    func fetchSimilarTracks(seedTrackId: Int64, limit: Int = 10, temperature: Double = 0.0) async throws -> [(track: Track, score: Float, bestMatchOffset: Double)] {
        // 1. Fetch seed track with its embeddings and acoustics
        guard let seedTrack = try await fetchTrack(id: seedTrackId),
              let seedRow = try await database.read({ db in
                  try TrackEmbedding.fetchOne(db, key: seedTrackId)
              }) else {
            return []
        }
        
        let seedEmbedding = seedRow.masterEmbedding
        let seedCategory = seedRow.mixCategory
        let seedDance = seedTrack.danceability
        let seedLufs = seedTrack.lufsI

        // Helper struct for joined SQLite results
        struct CandidateWithAcoustics {
            let trackId: Int64
            let masterEmbeddingData: Data
            let dropOffset: Double
            let mixCategory: String?
            let danceability: Double?
            let lufsI: Double?
            let lufsRange: Double?
            let genre: String?
            let artist: String
            let title: String
            
            var masterEmbedding: [Float] {
                [Float].fromData(masterEmbeddingData)
            }
        }

        let seedArtist = seedTrack.artist
        let seedTitle = seedTrack.title

        // 2. Fetch candidates with joined acoustic attributes hocheffizient
        let candidates = try await database.read { db -> [CandidateWithAcoustics] in
            let sql: String
            let args: StatementArguments
            if let cat = seedCategory {
                sql = """
                    SELECT e.track_id, e.master_embedding, e.drop_offset, e.mix_category,
                           t.danceability, t.lufs_i, t.lufs_range, t.genre, t.artist, t.title
                    FROM track_embeddings e
                    JOIN tracks t ON t.id = e.track_id
                    WHERE e.mix_category = ? 
                      AND e.track_id != ?
                      AND NOT (LOWER(t.artist) = LOWER(?) AND LOWER(t.title) = LOWER(?))
                """
                args = [cat, seedTrackId, seedArtist, seedTitle]
            } else {
                sql = """
                    SELECT e.track_id, e.master_embedding, e.drop_offset, e.mix_category,
                           t.danceability, t.lufs_i, t.lufs_range, t.genre, t.artist, t.title
                    FROM track_embeddings e
                    JOIN tracks t ON t.id = e.track_id
                    WHERE e.mix_category IS NULL 
                      AND e.track_id != ?
                      AND NOT (LOWER(t.artist) = LOWER(?) AND LOWER(t.title) = LOWER(?))
                """
                args = [seedTrackId, seedArtist, seedTitle]
            }
            
            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            return rows.map { row in
                CandidateWithAcoustics(
                    trackId: row["track_id"],
                    masterEmbeddingData: row["master_embedding"],
                    dropOffset: row["drop_offset"],
                    mixCategory: row["mix_category"],
                    danceability: row["danceability"],
                    lufsI: row["lufs_i"],
                    lufsRange: row["lufs_range"],
                    genre: row["genre"],
                    artist: row["artist"],
                    title: row["title"]
                )
            }
        }

        // 3. Fetch user feedback for this seed
        let feedbackRows = try await database.read { db -> [TrackSimilarityFeedback] in
            try TrackSimilarityFeedback.filter(TrackSimilarityFeedback.Columns.seedTrackId == seedTrackId).fetchAll(db)
        }
        let feedbackMap = Dictionary(uniqueKeysWithValues: feedbackRows.map { ($0.targetTrackId, $0.feedbackValue) })

        // Fetch discovery sources for all recommendations linked to this seed track in a single thread-safe batch query
        let discoverySourceMap = try await database.read { db -> [Int64: String] in
            let sql = "SELECT discovered_track_id, discovery_source FROM track_discovery_log WHERE seed_track_id = ?"
            let rows = try Row.fetchAll(db, sql: sql, arguments: [seedTrackId])
            var dict: [Int64: String] = [:]
            for row in rows {
                if let trackId = row["discovered_track_id"] as? Int64, let source = row["discovery_source"] as? String {
                    dict[trackId] = source
                }
            }
            return dict
        }

        // 4. Calculate composite similarity scores and sort
        var scoredCandidates: [(trackId: Int64, score: Float)] = []
        for candidate in candidates {
            // Exclude negative feedback targets
            if let feedbackVal = feedbackMap[candidate.trackId], feedbackVal < 0 {
                continue
            }

            let candEmbedding = candidate.masterEmbedding
            
            let baseCosine = VectorMath.cosineSimilarity(seedEmbedding, candEmbedding)

            // E. Combine into a musically intelligent composite score using dynamic weight normalization.
            // Weights: Groove (40%), Danceability (30%), LUFS Energy (20%), Genre Affinity (10%)
            var totalWeight: Float = 0.0
            var weightedScore: Float = 0.0

            // A. Base Cosine Similarity of CoreML class probabilities (0.0 ... 1.0)
            weightedScore += baseCosine * 0.40
            totalWeight += 0.40
            
            // B. Danceability similarity score (0.0 ... 1.0)
            if let sDance = seedDance, let cDance = candidate.danceability {
                var danceScore: Float = 0.5
                if sDance == 0.0 && cDance == 0.0 {
                    danceScore = 0.5 // Neutral fallback for non-danceable or failed analysis
                } else {
                    let diff = abs(sDance - cDance)
                    danceScore = Float(1.0 - diff)
                }
                weightedScore += danceScore * 0.30
                totalWeight += 0.30
            }
            
            // C. Energy (integrated loudness LUFS) similarity score (0.0 ... 1.0)
            if let sLufs = seedLufs, let cLufs = candidate.lufsI {
                let diff = abs(sLufs - cLufs)
                // Exponential decay: 0 LUFS diff = 1.0, 3 LUFS diff = 0.47, 8 LUFS diff = 0.13
                let energyScore = Float(exp(-diff / 4.0))
                weightedScore += energyScore * 0.20
                totalWeight += 0.20
            }
            
            // D. Genre match boost (0.0 ... 1.0)
            var genreScore: Float = 0.4 // Neutral fallback for missing metadata
            let sGenre = seedTrack.genre ?? ""
            let cGenre = candidate.genre ?? ""
            if !sGenre.isEmpty && !cGenre.isEmpty {
                let sGen = sGenre.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let cGen = cGenre.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if sGen == cGen {
                    genreScore = 1.0
                } else if (sGen.contains("house") && cGen.contains("house")) || 
                           (sGen.contains("rap") && cGen.contains("rap")) || 
                           (sGen.contains("club") && cGen.contains("club")) ||
                           (sGen.contains("vixa") && cGen.contains("vixa")) {
                    genreScore = 0.8
                } else {
                    genreScore = 0.1 // Mismatched genres are penalized
                }
            }
            weightedScore += genreScore * 0.10
            totalWeight += 0.10

            var score = totalWeight > 0.0 ? (weightedScore / totalWeight) : 0.0

            // Boost positive feedback targets
            if let feedbackVal = feedbackMap[candidate.trackId], feedbackVal > 0 {
                // Downgrade Last.fm positive feedback weight (+0.03 boost) compared to SoundCloud (+0.15 boost)
                let source = discoverySourceMap[candidate.trackId]
                let boost: Float = (source?.lowercased() == "lastfm") ? 0.03 : 0.15
                score += boost
            }

            // Clamp score between 0.0 and 1.0
            score = max(0.0, min(1.0, score))

            // Add temperature-based variance
            var finalScore = score
            if temperature > 0.0 {
                let noiseRange = Float(temperature * 0.15)
                let noise = Float.random(in: -noiseRange...noiseRange)
                finalScore = max(0.0, min(1.0, score + noise))
            }

            scoredCandidates.append((candidate.trackId, finalScore))
        }

        // Sort descending by score
        scoredCandidates.sort(by: { $0.score > $1.score })
        let topCandidates = Array(scoredCandidates.prefix(limit))

        if topCandidates.isEmpty { return [] }

        // 5. Load full Track models and find dynamic best matching segment offset
        var results: [(track: Track, score: Float, bestMatchOffset: Double)] = []
        for candidate in topCandidates {
            guard let track = try await fetchTrack(id: candidate.trackId) else { continue }
            
            let bestOffset = try await database.read { db -> Double in
                let segments = try TrackSegmentEmbedding.filter(TrackSegmentEmbedding.Columns.trackId == candidate.trackId).fetchAll(db)
                // Default to standard drop offset if no sub-segments exist
                var bestSegOffset = candidate.trackId == track.id ? (try? TrackEmbedding.fetchOne(db, key: candidate.trackId))??.dropOffset ?? 0.0 : 0.0
                var maxSegScore: Float = -1.0
                
                for segment in segments {
                    let segScore = VectorMath.cosineSimilarity(seedEmbedding, segment.segmentEmbedding)
                    if segScore > maxSegScore {
                        maxSegScore = segScore
                        bestSegOffset = segment.offsetSeconds
                    }
                }
                return bestSegOffset
            }
            
            results.append((track, candidate.score, bestOffset))
        }

        return results
    }

    // MARK: - Swarm Recommendations & Discovery Inbox
    
    /// Save a row in the track_discovery_log table.
    func saveDiscoveryLog(discoveredTrackId: Int64, seedTrackId: Int64?, source: String, status: String = "new") async throws {
        try await database.write { db in
            var row = TrackDiscoveryLog(
                discoveredTrackId: discoveredTrackId,
                seedTrackId: seedTrackId,
                discoverySource: source,
                status: status
            )
            try row.insert(db, onConflict: .replace)
        }
    }
    
    /// Fetch all tracks in the "Discovery Inbox" (status is 'new').
    func fetchDiscoveryInboxTracks() async throws -> [(track: Track, log: TrackDiscoveryLog, seedTrack: Track?)] {
        try await database.read { db -> [(track: Track, log: TrackDiscoveryLog, seedTrack: Track?)] in
            let sql = """
                SELECT l.*, t.*
                FROM track_discovery_log l
                JOIN tracks t ON t.id = l.discovered_track_id
                WHERE l.status = 'new'
                ORDER BY l.date_added DESC
            """
            let rows = try Row.fetchAll(db, sql: sql)
            var results: [(track: Track, log: TrackDiscoveryLog, seedTrack: Track?)] = []
            
            for row in rows {
                let log = try TrackDiscoveryLog(row: row)
                let track = try Track(row: row)
                
                var seedTrack: Track? = nil
                if let seedId = log.seedTrackId {
                    seedTrack = try Track.fetchOne(db, key: seedId)
                }
                
                results.append((track, log, seedTrack))
            }
            return results
        }
    }
    
    /// Update the status of a discovered track (e.g. 'approved' or 'rejected').
    func updateDiscoveryStatus(discoveredTrackId: Int64, status: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE track_discovery_log SET status = ? WHERE discovered_track_id = ?",
                arguments: [status, discoveredTrackId]
            )
        }
    }

    /// Fetch the embedding and drop offset for a track, if it exists.
    func fetchTrackEmbedding(id: Int64) async throws -> TrackEmbedding? {
        try await database.read { db in
            try TrackEmbedding.fetchOne(db, key: id)
        }
    }

    /// Apply a small gravitational pull (e.g. 5%) to pull two track embeddings closer together.
    /// Warps the local vector space over time based on approved remote recommendations.
    func applyVectorGravity(seedTrackId: Int64, targetTrackId: Int64, pullRate: Float = 0.05) async throws {
        try await database.write { db in
            guard var seedRow = try TrackEmbedding.fetchOne(db, key: seedTrackId),
                  var targetRow = try TrackEmbedding.fetchOne(db, key: targetTrackId) else {
                return
            }
            
            var seedEmbedding = seedRow.masterEmbedding
            var targetEmbedding = targetRow.masterEmbedding
            
            guard seedEmbedding.count == targetEmbedding.count, seedEmbedding.count > 0 else {
                return
            }
            
            // Apply Vector Gravity:
            // E_seed = E_seed + pullRate * (E_target - E_seed)
            // E_target = E_target + pullRate * (E_seed - E_target)
            for i in 0..<seedEmbedding.count {
                let sVal = seedEmbedding[i]
                let tVal = targetEmbedding[i]
                
                seedEmbedding[i] = sVal + pullRate * (tVal - sVal)
                targetEmbedding[i] = tVal + pullRate * (sVal - tVal)
            }
            
            // Re-normalize vectors (essential for maintaining cosine similarity integrity)
            func normalize(_ v: [Float]) -> [Float] {
                let sumSquare = v.reduce(0.0) { $0 + $1 * $1 }
                let norm = sqrt(sumSquare)
                return norm > 0 ? v.map { $0 / norm } : v
            }
            
            seedRow.masterEmbeddingData = normalize(seedEmbedding).toData
            targetRow.masterEmbeddingData = normalize(targetEmbedding).toData
            
            try seedRow.update(db)
            try targetRow.update(db)
        }
    }

    /// Fetch a track by exact artist and title match.
    func fetchTrackByArtistAndTitle(artist: String, title: String) async throws -> Track? {
        try await database.read { db in
            try Track.fetchOne(db, sql: "SELECT * FROM tracks WHERE artist = ? AND title = ? LIMIT 1", arguments: [artist, title])
        }
    }

    /// Fetch all similarity feedback records for a given seed track.
    func fetchSimilarityFeedback(seedTrackId: Int64) async throws -> [TrackSimilarityFeedback] {
        try await database.read { db in
            try TrackSimilarityFeedback.filter(TrackSimilarityFeedback.Columns.seedTrackId == seedTrackId).fetchAll(db)
        }
    }

    /// Fetch all tracks discovered and downloaded for a given seed track.
    func fetchDiscoveryTracksForSeed(seedTrackId: Int64) async throws -> [Track] {
        try await database.read { db in
            let sql = """
                SELECT t.* FROM tracks t
                JOIN track_discovery_log l ON l.discovered_track_id = t.id
                WHERE l.seed_track_id = ?
            """
            return try Track.fetchAll(db, sql: sql, arguments: [seedTrackId])
        }
    }

    /// Fetch all unique genres with their track counts.
    func fetchUniqueGenres() async throws -> [(genre: String, count: Int)] {
        try await database.read { db in
            let sql = """
                SELECT genre, COUNT(*) as count 
                FROM tracks 
                WHERE genre IS NOT NULL AND genre != '' 
                GROUP BY genre 
                ORDER BY count DESC
            """
            let rows = try Row.fetchAll(db, sql: sql)
            return rows.map { row in
                let genre: String = row["genre"] ?? ""
                let count: Int = row["count"] ?? 0
                return (genre: genre, count: count)
            }
        }
    }

    /// Fetch all tracks belonging to a specific genre.
    func fetchTracks(genre: String) async throws -> [Track] {
        try await database.read { db in
            try Track.filter(Track.Columns.genre == genre).fetchAll(db)
        }
    }

    /// Update only the mix category of a track embedding in track_embeddings.
    func updateMixCategory(trackId: Int64, mixCategory: String?) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE track_embeddings SET mix_category = ? WHERE track_id = ?",
                arguments: [mixCategory, trackId]
            )
        }
    }

    /// Merge multiple genres into a single canonical target genre.
    func mergeGenres(sources: [String], target: String) async throws {
        try await database.write { db in
            let placeholders = Array(repeating: "?", count: sources.count).joined(separator: ", ")
            let sql = "UPDATE tracks SET genre = ? WHERE genre IN (\(placeholders))"
            try db.execute(sql: sql, arguments: StatementArguments([target] + sources))
        }
    }

    /// Fetch all tracks in the library that have a non-empty genre.
    func fetchTracksWithGenre() async throws -> [Track] {
        try await database.read { db in
            try Track.filter(Track.Columns.genre != nil && Track.Columns.genre != "").fetchAll(db)
        }
    }
}
