import Foundation
import GRDB

/// A connected music source (Spotify, SoundCloud, etc.).
///
/// Maps to the `sources` table.
struct Source: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    var id: Int64?
    var name: String
    var userId: String
    var enabled: Int

    static let databaseTableName = "sources"

    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case userId = "user_id"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let userId = Column(CodingKeys.userId)
        static let enabled = Column(CodingKeys.enabled)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Source type derived from name.
    var sourceType: SourceType {
        SourceType(rawValue: name) ?? .unknown
    }
}

/// Known source types.
enum SourceType: String, CaseIterable {
    case spotify
    case soundcloud
    case appleMusic = "apple_music"
    case unknown

    var displayName: String {
        switch self {
        case .spotify: "Spotify"
        case .soundcloud: "SoundCloud"
        case .appleMusic: "Apple Music"
        case .unknown: "Unknown"
        }
    }
}

/// Relationship between a track and a source.
struct TrackSource: Codable, FetchableRecord, PersistableRecord {
    var trackId: Int64
    var sourceId: Int64
    var externalId: String
    var addedAt: String

    static let databaseTableName = "track_sources"

    enum CodingKeys: String, CodingKey {
        case trackId = "track_id"
        case sourceId = "source_id"
        case externalId = "external_id"
        case addedAt = "added_at"
    }

    enum Columns {
        static let trackId = Column(CodingKeys.trackId)
        static let sourceId = Column(CodingKeys.sourceId)
        static let externalId = Column(CodingKeys.externalId)
    }
}

/// Last sync timestamp for a source per user.
struct LastSyncTimestamp: Codable, FetchableRecord, PersistableRecord {
    var userId: String
    var source: String
    var timestamp: String

    static let databaseTableName = "last_sync_timestamps"

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case source
        case timestamp
    }
}
