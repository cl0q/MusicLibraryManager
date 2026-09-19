import Foundation
import GRDB

// MARK: - GRDB Records

/// A locally-tracked playlist (mirrors manifest playlists + virtual ones like Liked).
struct LocalPlaylist: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
    var id: Int64?
    let uuid: String
    var name: String
    var file: String?

    static let databaseTableName = "local_playlists"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let uuid = Column(CodingKeys.uuid)
        static let name = Column(CodingKeys.name)
        static let file = Column(CodingKeys.file)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case uuid
        case name
        case file
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// An ordered entry in a local playlist.
struct PlaylistEntry: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: Int64?
    let playlistID: Int64
    let trackUUID: String
    var relativePath: String
    var orderIndex: Int
    var addedAt: Date

    static let databaseTableName = "playlist_entries"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let playlistID = Column(CodingKeys.playlistID)
        static let trackUUID = Column(CodingKeys.trackUUID)
        static let relativePath = Column(CodingKeys.relativePath)
        static let orderIndex = Column(CodingKeys.orderIndex)
        static let addedAt = Column(CodingKeys.addedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case playlistID = "playlist_id"
        case trackUUID = "track_uuid"
        case relativePath = "relative_path"
        case orderIndex = "order_index"
        case addedAt = "added_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A hearted/liked track.
struct LikedTrack: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: Int64?
    let trackUUID: String
    var likedAt: Date

    static let databaseTableName = "liked_tracks"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let trackUUID = Column(CodingKeys.trackUUID)
        static let likedAt = Column(CodingKeys.likedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case trackUUID = "track_uuid"
        case likedAt = "liked_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Persists the stable UUID used for the Liked.m3u8 playlist header.
struct LikesPlaylistState: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64 = 1
    var playlistUUID: String

    static let databaseTableName = "likes_playlist_state"

    enum CodingKeys: String, CodingKey {
        case id
        case playlistUUID = "playlist_uuid"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Parsed Playlist (m3u8 dialect)

/// A parsed `.ios` m3u8 playlist, preserving unknown comments for roundtrip fidelity.
struct ParsedPlaylist: Equatable {
    var playlistUUID: String?
    var headerComments: [String]
    var entries: [ParsedEntry]
}

/// A single entry in a parsed m3u8 playlist.
struct ParsedEntry: Equatable {
    var extinfLine: String?
    var trackUUID: String?
    var path: String
    var precedingComments: [String]
}

// MARK: - Sync Result

/// Summary of a syncFromFolder() call.
struct PlaylistSyncResult: Equatable {
    var unchanged = 0
    var updated = 0
    var created = 0
}
