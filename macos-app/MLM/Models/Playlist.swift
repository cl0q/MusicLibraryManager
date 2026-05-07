import Foundation
import GRDB

/// A playlist in the library.
///
/// Maps to the `playlists` table. Supports native (local-only),
/// synced (from Spotify/SoundCloud), liked, and smart playlists.
struct Playlist: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    var id: Int64?
    var name: String
    var description: String?
    var category: String
    var isLiked: Int
    var isSmart: Int
    var isPinned: Int
    var coverImagePath: String?
    var coverImageUrl: String?
    var sourceId: Int64?
    var externalId: String?
    var dateCreated: String?

    static let databaseTableName = "playlists"

    enum CodingKeys: String, CodingKey {
        case id, name, description, category
        case isLiked = "is_liked"
        case isSmart = "is_smart"
        case isPinned = "is_pinned"
        case coverImagePath = "cover_image_path"
        case coverImageUrl = "cover_image_url"
        case sourceId = "source_id"
        case externalId = "external_id"
        case dateCreated = "date_created"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let category = Column(CodingKeys.category)
        static let isLiked = Column(CodingKeys.isLiked)
        static let isSmart = Column(CodingKeys.isSmart)
        static let isPinned = Column(CodingKeys.isPinned)
        static let sourceId = Column(CodingKeys.sourceId)
        static let dateCreated = Column(CodingKeys.dateCreated)
    }

    /// Whether this is a native (local-only) playlist.
    var isNative: Bool {
        sourceId == nil && externalId == nil && isSmart == 0 && isLiked == 0
    }
}

/// A track's membership in a playlist with fractional position.
struct PlaylistTrack: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var playlistId: Int64
    var trackId: Int64
    var position: String
    var addedAt: String?

    static let databaseTableName = "playlist_tracks"

    enum CodingKeys: String, CodingKey {
        case id
        case playlistId = "playlist_id"
        case trackId = "track_id"
        case position
        case addedAt = "added_at"
    }

    enum Columns {
        static let playlistId = Column(CodingKeys.playlistId)
        static let trackId = Column(CodingKeys.trackId)
        static let position = Column(CodingKeys.position)
    }
}

/// A tag on a playlist.
struct PlaylistTag: Codable, FetchableRecord, PersistableRecord {
    var playlistId: Int64
    var tag: String

    static let databaseTableName = "playlist_tags"

    enum CodingKeys: String, CodingKey {
        case playlistId = "playlist_id"
        case tag
    }
}

// MARK: - Playlist Defaults

extension Playlist {
    /// Create a new native (local-only) playlist.
    static func createNative(name: String) -> Playlist {
        Playlist(
            id: nil,
            name: name,
            description: nil,
            category: "regular",
            isLiked: 0,
            isSmart: 0,
            isPinned: 0,
            coverImagePath: nil,
            coverImageUrl: nil,
            sourceId: nil,
            externalId: nil,
            dateCreated: nil
        )
    }
}
