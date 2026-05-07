import Foundation
import GRDB

/// Repository for sync profile CRUD and content resolution.
final class SyncRepository: Sendable {
    private let database: DatabasePool

    init(database: DatabasePool) {
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
}
