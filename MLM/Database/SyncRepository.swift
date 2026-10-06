import Foundation
import GRDB

/// Repository for sync profile CRUD and content resolution.
final class SyncRepository: Sendable {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    // MARK: - Profiles

    /// Fetch all sync profiles.
    func fetchAll() async throws -> [SyncProfile] {
        try await database.read { db in
            try SyncProfile.order(SyncProfile.Columns.name).fetchAll(db)
        }
    }

    /// Fetch a single profile by ID.
    func fetch(id: Int64) async throws -> SyncProfile? {
        try await database.read { db in
            try SyncProfile.fetchOne(db, id: id)
        }
    }

    /// Create a new sync profile.
    @discardableResult
    func create(name: String, outputFolder: String) async throws -> SyncProfile {
        try await database.write { db in
            var profile = SyncProfile(
                id: nil,
                name: name,
                outputFolder: outputFolder,
                playlistPathPrefix: "",
                dateCreated: nil,
                dateModified: nil
            )
            try profile.insert(db)
            return profile
        }
    }

    /// Delete a sync profile and all its child rows.
    /// Foreign-key enforcement is disabled on every connection, so the
    /// declared ON DELETE CASCADE is inert — children must be removed first.
    func delete(id: Int64) async throws {
        _ = try await database.write { db in
            try db.execute(sql: "DELETE FROM sync_state WHERE profile_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM sync_profile_tracks WHERE profile_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM sync_profile_playlists WHERE profile_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM sync_profile_rules WHERE profile_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM playlist_sync_snapshots WHERE profile_id = ?", arguments: [id])
            // v47 (W3-SYNC): the profile's last sync result goes with it.
            try db.execute(sql: "DELETE FROM sync_profile_results WHERE profile_id = ?", arguments: [id])
            try SyncProfile.deleteOne(db, id: id)
        }
    }

    /// Duplicate a profile and its selected content atomically. A unique
    /// display name is generated so this remains useful without a modal name
    /// prompt.
    @discardableResult
    func duplicate(id: Int64) async throws -> SyncProfile {
        try await database.write { db in
            guard let original = try SyncProfile.fetchOne(db, id: id) else {
                throw SyncError.profileNotFound(id)
            }

            var copyName = "\(original.name) copy"
            var suffix = 2
            while try String.fetchOne(
                db,
                sql: "SELECT name FROM sync_profiles WHERE name = ?",
                arguments: [copyName]
            ) != nil {
                copyName = "\(original.name) copy \(suffix)"
                suffix += 1
            }

            var copy = SyncProfile(
                name: copyName,
                outputFolder: original.outputFolder,
                playlistPathPrefix: original.playlistPathPrefix,
                generateM3U8: original.generateM3U8,
                transcodeMode: original.transcodeMode,
                fat32SafePaths: original.fat32SafePaths,
                cleanupRemovedFiles: original.cleanupRemovedFiles,
                playlistFormat: original.playlistFormat,
                normalizeLoudness: original.normalizeLoudness,
                // Duplicate copies every option, Artwork included (CM-SYNC-PROFILE).
                artworkMode: original.artworkMode
            )
            try copy.insert(db)
            guard let copyID = copy.id else { return copy }

            try db.execute(
                sql: """
                    INSERT INTO sync_profile_tracks (profile_id, track_id)
                    SELECT ?, track_id FROM sync_profile_tracks WHERE profile_id = ?
                    """,
                arguments: [copyID, id]
            )
            try db.execute(
                sql: """
                    INSERT INTO sync_profile_playlists (profile_id, playlist_id)
                    SELECT ?, playlist_id FROM sync_profile_playlists WHERE profile_id = ?
                    """,
                arguments: [copyID, id]
            )
            try db.execute(
                sql: """
                    INSERT INTO sync_profile_rules (profile_id, field, operator, value)
                    SELECT ?, field, operator, value FROM sync_profile_rules WHERE profile_id = ?
                    """,
                arguments: [copyID, id]
            )
            return copy
        }
    }

    /// Last successful sync timestamp for every profile, fetched in one query
    /// for the profile-list status lines.
    func fetchLastSyncTimestamps() async throws -> [Int64: String] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT ss.profile_id, MAX(ss.synced_timestamp) AS last_sync
                FROM sync_state ss
                INNER JOIN sync_profiles sp ON sp.id = ss.profile_id
                GROUP BY ss.profile_id
                """)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let profileID: Int64 = row["profile_id"],
                      let timestamp: String = row["last_sync"] else { return nil }
                return (profileID, timestamp)
            })
        }
    }

    /// Playlists + tracks + rules per profile in one query (W3-SYNC: `Nothing to sync yet` for
    /// every sidebar row without loading each profile's content).
    func fetchContentCounts() async throws -> [Int64: Int] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT profile_id, COUNT(*) AS n FROM (
                    SELECT profile_id FROM sync_profile_playlists
                    UNION ALL SELECT profile_id FROM sync_profile_tracks
                    UNION ALL SELECT profile_id FROM sync_profile_rules
                ) GROUP BY profile_id
                """)
            return Dictionary(rows.map { (($0["profile_id"] as Int64), ($0["n"] as Int)) }, uniquingKeysWith: +)
        }
    }

    // MARK: - Profile Content

    /// Fetch tracks directly added to a profile.
    func fetchProfileTracks(profileId: Int64) async throws -> [Track] {
        try await database.read { db in
            try Track.fetchAll(db, sql: """
                SELECT t.* FROM tracks t
                INNER JOIN sync_profile_tracks spt ON spt.track_id = t.id
                WHERE spt.profile_id = ?
            """, arguments: [profileId])
        }
    }

    /// Fetch playlists attached to a profile.
    func fetchProfilePlaylists(profileId: Int64) async throws -> [Playlist] {
        try await database.read { db in
            try Playlist.fetchAll(db, sql: """
                SELECT p.* FROM playlists p
                INNER JOIN sync_profile_playlists spp ON spp.playlist_id = p.id
                WHERE spp.profile_id = ?
            """, arguments: [profileId])
        }
    }

    /// Fetch filter rules for a profile.
    func fetchProfileRules(profileId: Int64) async throws -> [SyncProfileRule] {
        try await database.read { db in
            try SyncProfileRule
                .filter(SyncProfileRule.Columns.profileId == profileId)
                .fetchAll(db)
        }
    }

    /// Add a track to a sync profile.
    func addTrack(profileId: Int64, trackId: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO sync_profile_tracks (profile_id, track_id) VALUES (?, ?)",
                arguments: [profileId, trackId]
            )
        }
    }

    /// Add a playlist to a sync profile.
    func addPlaylist(profileId: Int64, playlistId: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO sync_profile_playlists (profile_id, playlist_id) VALUES (?, ?)",
                arguments: [profileId, playlistId]
            )
        }
    }

    // MARK: - Sync State

    /// Fetch sync state for a profile.
    func fetchSyncState(profileId: Int64) async throws -> [SyncState] {
        try await database.read { db in
            try SyncState.fetchAll(db, sql: """
                SELECT * FROM sync_state WHERE profile_id = ?
            """, arguments: [profileId])
        }
    }

    /// Update sync state for a track in a profile.
    func updateSyncState(profileId: Int64, trackId: Int64, checksum: String, size: Int) async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                VALUES (?, ?, ?, ?, datetime('now'))
            """, arguments: [profileId, trackId, checksum, size])
        }
    }

    /// Remove sync state for a track that's been removed from a profile.
    func removeSyncState(profileId: Int64, trackId: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM sync_state WHERE profile_id = ? AND track_id = ?",
                arguments: [profileId, trackId]
            )
        }
    }

    /// Add a filter rule to a profile.
    @discardableResult
    func addRule(profileId: Int64, field: String, operator op: String, value: String) async throws -> SyncProfileRule {
        try await database.write { db in
            var rule = SyncProfileRule(id: nil, profileId: profileId, field: field, operator: op, value: value)
            try rule.insert(db)
            return rule
        }
    }

    /// Remove a filter rule.
    func removeRule(id: Int64) async throws {
        _ = try await database.write { db in
            try SyncProfileRule.deleteOne(db, id: id)
        }
    }

    /// Update profile settings (name, output folder, toggle flags, etc.).
    func updateSettings(
        profileId: Int64,
        name: String? = nil,
        outputFolder: String? = nil,
        playlistPathPrefix: String? = nil,
        generateM3U8: Bool? = nil,
        transcodeMode: String? = nil,
        fat32SafePaths: Bool? = nil,
        cleanupRemovedFiles: Bool? = nil,
        playlistFormat: String? = nil,
        normalizeLoudness: Bool? = nil,
        artworkMode: String? = nil
    ) async throws {
        try await database.write { db in
            var sets: [String] = []
            var args: [DatabaseValueConvertible?] = []

            if let name {
                sets.append("name = ?")
                args.append(name)
            }
            if let outputFolder {
                sets.append("output_folder = ?")
                args.append(outputFolder)
            }
            if let playlistPathPrefix {
                sets.append("playlist_path_prefix = ?")
                args.append(playlistPathPrefix)
            }
            if let generateM3U8 {
                sets.append("generate_m3u8 = ?")
                args.append(generateM3U8 ? 1 : 0)
            }
            if let transcodeMode {
                sets.append("transcode_mode = ?")
                args.append(transcodeMode)
            }
            if let fat32SafePaths {
                sets.append("fat32_safe_paths = ?")
                args.append(fat32SafePaths ? 1 : 0)
            }
            if let cleanupRemovedFiles {
                sets.append("cleanup_removed_files = ?")
                args.append(cleanupRemovedFiles ? 1 : 0)
            }
            if let playlistFormat {
                sets.append("playlist_format = ?")
                args.append(playlistFormat)
            }
            if let normalizeLoudness {
                sets.append("normalize_loudness = ?")
                args.append(normalizeLoudness ? 1 : 0)
            }
            if let artworkMode {
                sets.append("artwork_mode = ?")
                args.append(artworkMode)
            }

            guard !sets.isEmpty else { return }
            sets.append("date_modified = datetime('now')")
            args.append(profileId)

            try db.execute(
                sql: "UPDATE sync_profiles SET \(sets.joined(separator: ", ")) WHERE id = ?",
                arguments: StatementArguments(args)
            )
        }
    }

    /// Remove a track from a sync profile.
    func removeTrack(profileId: Int64, trackId: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM sync_profile_tracks WHERE profile_id = ? AND track_id = ?",
                arguments: [profileId, trackId]
            )
        }
    }

    /// Remove a playlist from a sync profile.
    func removePlaylist(profileId: Int64, playlistId: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM sync_profile_playlists WHERE profile_id = ? AND playlist_id = ?",
                arguments: [profileId, playlistId]
            )
        }
    }

    /// Expose the database writer for cross-repo access (e.g. for PlaylistRepository in generatePlaylists).
    var databaseWriter: any DatabaseWriter { database }
}
