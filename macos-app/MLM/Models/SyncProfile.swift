import Foundation
import GRDB

/// Transcode mode for a sync profile.
enum TranscodeMode: String, Equatable {
    case keepOriginals = "keep_originals"
    case aac248 = "aac_248"
    case aac320 = "aac_320"
}

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

    // MARK: - Toggle Settings (added in v21_sync_profile_toggles)
    var generateM3U8: Bool = false
    var transcodeMode: String = "keep_originals"
    var fat32SafePaths: Bool = true
    var cleanupRemovedFiles: Bool = true

    /// Typed accessor for transcode mode.
    var transcodeModeEnum: TranscodeMode {
        TranscodeMode(rawValue: transcodeMode) ?? .keepOriginals
    }

    static let databaseTableName = "sync_profiles"

    enum CodingKeys: String, CodingKey {
        case id, name
        case outputFolder = "output_folder"
        case playlistPathPrefix = "playlist_path_prefix"
        case dateCreated = "date_created"
        case dateModified = "date_modified"
        case generateM3U8 = "generate_m3u8"
        case transcodeMode = "transcode_mode"
        case fat32SafePaths = "fat32_safe_paths"
        case cleanupRemovedFiles = "cleanup_removed_files"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let outputFolder = Column(CodingKeys.outputFolder)
    }

    /// Convenience init for tests and profile creation.
    init(
        id: Int64? = nil,
        name: String,
        outputFolder: String,
        playlistPathPrefix: String = "",
        dateCreated: String? = nil,
        dateModified: String? = nil,
        generateM3U8: Bool = false,
        transcodeMode: String = "keep_originals",
        fat32SafePaths: Bool = true,
        cleanupRemovedFiles: Bool = true
    ) {
        self.id = id
        self.name = name
        self.outputFolder = outputFolder
        self.playlistPathPrefix = playlistPathPrefix
        self.dateCreated = dateCreated
        self.dateModified = dateModified
        self.generateM3U8 = generateM3U8
        self.transcodeMode = transcodeMode
        self.fat32SafePaths = fat32SafePaths
        self.cleanupRemovedFiles = cleanupRemovedFiles
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
