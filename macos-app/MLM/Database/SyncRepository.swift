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

    /// Delete a sync profile.
    func delete(id: Int64) async throws {
        _ = try await database.write { db in
            try SyncProfile.deleteOne(db, id: id)
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
        cleanupRemovedFiles: Bool? = nil
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
