import Foundation
import GRDB

/// Type-safe transcode mode for sync profiles (D-01).
/// Stored as TEXT in DB. Use `transcodeModeEnum` computed property for switch statements.
enum TranscodeMode: String, CaseIterable {
    case keepOriginals = "keep_originals"
    case aac248 = "aac_248"
    case aac320 = "aac_320"
}

/// Type-safe playlist format for sync profiles.
/// Stored as TEXT in DB. Use `playlistFormatEnum` computed property.
enum PlaylistFormat: String, CaseIterable, Codable {
    case rockbox = "rockbox"
    case doppi = "doppi"
    case ios = "ios"
}

/// Per-profile artwork handling for AAC transcode (WP-B).
/// `resize250` downscales embedded cover art to fit a 250×250 box.
enum ArtworkMode: String, CaseIterable {
    case keepOriginal = "keep_original"
    case resize250 = "resize_250"
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

    // Phase 38 D-01: explicit folder/device toggles (added in v_sync_toggles migration)
    var generateM3U8: Bool = false
    var transcodeMode: String = "keep_originals"
    var fat32SafePaths: Bool = true
    var cleanupRemovedFiles: Bool = true
    var playlistFormat: String = "rockbox"

    /// Bake EBU R128 loudness normalization into exported AAC (v24).
    /// Only applies when transcodeMode != keepOriginals.
    var normalizeLoudness: Bool = false

    /// Artwork handling for AAC transcode (WP-B).
    /// `resize_250` downscales embedded cover art to fit a 250×250 box.
    var artworkMode: String = "keep_original"

    /// Type-safe computed accessor. All consumers (SyncService, SyncSettingsForm, tests)
    /// use this for switch statements. DB writes always use `.rawValue` strings.
    var transcodeModeEnum: TranscodeMode {
        TranscodeMode(rawValue: transcodeMode) ?? .keepOriginals
    }

    /// Type-safe computed accessor for playlist format.
    var playlistFormatEnum: PlaylistFormat {
        PlaylistFormat(rawValue: playlistFormat) ?? .rockbox
    }

    /// Type-safe computed accessor for artwork mode.
    var artworkModeEnum: ArtworkMode {
        ArtworkMode(rawValue: artworkMode) ?? .keepOriginal
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
        case playlistFormat = "playlist_format"
        case normalizeLoudness = "normalize_loudness"
        case artworkMode = "artwork_mode"
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
        cleanupRemovedFiles: Bool = true,
        playlistFormat: String = "rockbox",
        normalizeLoudness: Bool = false,
        artworkMode: String = "keep_original"
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
        self.playlistFormat = playlistFormat
        self.normalizeLoudness = normalizeLoudness
        self.artworkMode = artworkMode
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

// MARK: - iOS Library Manifest (spec §3)

/// Top-level `mlm-library.json` structure written to the profile output root.
struct LibraryManifest: Codable {
    let schema: Int
    let profile: String
    let generatedAt: String
    let tracks: [ManifestTrack]
    let playlists: [ManifestPlaylist]

    enum CodingKeys: String, CodingKey {
        case schema
        case profile
        case generatedAt = "generated_at"
        case tracks
        case playlists
    }
}

/// A track entry in the library manifest.
struct ManifestTrack: Codable {
    let uuid: String
    let title: String
    let artist: String
    let albumArtist: String
    let album: String
    let duration: Int
    let path: String
    let energyBucket: Int?
    let lufsI: Double?

    enum CodingKeys: String, CodingKey {
        case uuid
        case title
        case artist
        case albumArtist = "album_artist"
        case album
        case duration
        case path
        case energyBucket = "energy_bucket"
        case lufsI = "lufs_i"
    }
}

/// A playlist entry in the library manifest.
struct ManifestPlaylist: Codable {
    let uuid: String
    let name: String
    let file: String
}
