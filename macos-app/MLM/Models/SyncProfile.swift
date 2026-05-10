import Foundation
import GRDB

/// A device sync profile.
///
/// Maps to the `sync_profiles` table. Defines which tracks/playlists
/// sync to a device folder, with optional filter rules.
struct SyncProfile: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    var id: Int64?
    var name: String
    var outputFolder: String
    var playlistPathPrefix: String
    var dateCreated: String?
    var dateModified: String?

    static let databaseTableName = "sync_profiles"

    enum CodingKeys: String, CodingKey {
        case id, name
        case outputFolder = "output_folder"
        case playlistPathPrefix = "playlist_path_prefix"
        case dateCreated = "date_created"
        case dateModified = "date_modified"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let outputFolder = Column(CodingKeys.outputFolder)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A track directly added to a sync profile.
struct SyncProfileTrack: Codable, FetchableRecord, PersistableRecord {
    var profileId: Int64
    var trackId: Int64

    static let databaseTableName = "sync_profile_tracks"

    enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case trackId = "track_id"
    }
}

/// A playlist included in a sync profile.
struct SyncProfilePlaylist: Codable, FetchableRecord, PersistableRecord {
    var profileId: Int64
    var playlistId: Int64

    static let databaseTableName = "sync_profile_playlists"

    enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case playlistId = "playlist_id"
    }
}

/// A filter rule for a sync profile.
struct SyncProfileRule: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var profileId: Int64
    var field: String
    var `operator`: String
    var value: String

    static let databaseTableName = "sync_profile_rules"

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case field
        case `operator`
        case value
    }

    enum Columns {
        static let profileId = Column(CodingKeys.profileId)
    }
}

/// The sync state for a track on a device profile.
struct SyncState: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var profileId: Int64
    var trackId: Int64
    var syncedChecksum: String?
    var syncedSize: Int?
    var syncedTimestamp: String?

    static let databaseTableName = "sync_state"

    enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case trackId = "track_id"
        case syncedChecksum = "synced_checksum"
        case syncedSize = "synced_size"
        case syncedTimestamp = "synced_timestamp"
    }
}
