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
        switch playlistSourceIdentity {
        case .spotify:
            .spotify
        case .soundcloud:
            .soundcloud
        case .appleMusic:
            .appleMusic
        case .youtube, .other:
            .unknown
        }
    }

    /// Human-readable identity for a playlist linked to this source.
    ///
    /// Unlike `SourceType`, this includes YouTube, which is a playlist import
    /// source rather than an OAuth-connected source service.
    var playlistSourceIdentity: PlaylistSourceIdentity {
        PlaylistSourceIdentity(sourceName: name)
    }
}

/// A source identity that can be presented on a linked playlist.
enum PlaylistSourceIdentity: Equatable, Hashable, Sendable {
    case spotify
    case soundcloud
    case youtube
    case appleMusic
    case other(String)

    init(sourceName: String) {
        let normalized = sourceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "spotify":
            self = .spotify
        case "soundcloud", "sound_cloud":
            self = .soundcloud
        case "youtube", "you_tube":
            self = .youtube
        case "apple_music", "applemusic":
            self = .appleMusic
        default:
            self = .other(sourceName)
        }
    }

    var displayName: String {
        switch self {
        case .spotify:
            "Spotify"
        case .soundcloud:
            "SoundCloud"
        case .youtube:
            "YouTube"
        case .appleMusic:
            "Apple Music"
        case let .other(name):
            name
        }
    }

    /// Pins playlist-initiated downloads to the service that supplied them.
    /// Sources without a direct downloader retain the normal fallback chain.
    var downloadPin: DownloadOrchestrator.PreferredSource {
        switch self {
        case .soundcloud:
            .soundcloud
        case .youtube:
            .youtube
        case .spotify, .appleMusic, .other:
            .auto
        }
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
