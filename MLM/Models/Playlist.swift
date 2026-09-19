import Foundation
import GRDB

/// A playlist in the library.
///
/// Maps to the `playlists` table. Supports native (local-only),
/// synced (from Spotify/SoundCloud), liked, and smart playlists.
struct Playlist: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    var id: Int64?
    var name: String
    var description: String?
    var category: String
    var isLiked: Int
    var isSmart: Int
    var isPinned: Int
    /// Auto/custom cover lock (Phase 36 / migration v20).
    /// 0 = auto-generated (eligible for regeneration); 1 = user-set custom (skip auto-regen).
    /// Stored as Int per SQLite-bool convention used by `isLiked`/`isSmart`/`isPinned`.
    var coverIsCustom: Int = 0
    var coverImagePath: String?
    var coverImageUrl: String?
    var sourceId: Int64?
    var externalId: String?
    var dateCreated: String?
    /// Stable UUID identity for iOS sidecar sync (lazy UUIDv4 uppercase string).
    var mlmUuid: String? = nil

    static let databaseTableName = "playlists"

    enum CodingKeys: String, CodingKey {
        case id, name, description, category
        case isLiked = "is_liked"
        case isSmart = "is_smart"
        case isPinned = "is_pinned"
        case coverIsCustom = "cover_is_custom"
        case coverImagePath = "cover_image_path"
        case coverImageUrl = "cover_image_url"
        case sourceId = "source_id"
        case externalId = "external_id"
        case dateCreated = "date_created"
        case mlmUuid = "mlm_uuid"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let category = Column(CodingKeys.category)
        static let isLiked = Column(CodingKeys.isLiked)
        static let isSmart = Column(CodingKeys.isSmart)
        static let isPinned = Column(CodingKeys.isPinned)
        static let coverIsCustom = Column(CodingKeys.coverIsCustom)
        static let sourceId = Column(CodingKeys.sourceId)
        static let dateCreated = Column(CodingKeys.dateCreated)
        static let mlmUuid = Column(CodingKeys.mlmUuid)
    }

    /// Whether this is a native (local-only) playlist.
    var isNative: Bool {
        sourceId == nil && externalId == nil && isSmart == 0 && isLiked == 0
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - MLM UUID helpers

extension Playlist {
    /// Generate a fresh UUIDv4 uppercase string suitable for `mlm_uuid`.
    static func generateMlmUuid() -> String {
        UUID().uuidString.uppercased()
    }

    /// Ensure this playlist has an `mlm_uuid`; generate one lazily if missing.
    /// Returns `true` if a new UUID was assigned.
    @discardableResult
    mutating func ensureMlmUuid() -> Bool {
        if mlmUuid == nil {
            mlmUuid = Playlist.generateMlmUuid()
            return true
        }
        return false
    }
}

/// Read-only download health aggregate for a playlist.
struct PlaylistDownloadStatus: Equatable, Sendable {
    let playlistID: Int64
    let totalTracks: Int
    let localTracks: Int
    let downloadingTracks: Int
    let failedTracks: Int
    let notDownloadedTracks: Int

    init(
        playlistID: Int64,
        totalTracks: Int,
        localTracks: Int,
        downloadingTracks: Int,
        failedTracks: Int,
        notDownloadedTracks: Int
    ) {
        self.playlistID = playlistID
        self.totalTracks = totalTracks
        self.localTracks = localTracks
        self.downloadingTracks = downloadingTracks
        self.failedTracks = failedTracks
        self.notDownloadedTracks = notDownloadedTracks
    }

    /// Builds exclusive health buckets from a presentation availability snapshot.
    /// A file that has lost its local path remains in the local-path bucket so
    /// it cannot become a download-missing candidate.
    init(
        playlistID: Int64,
        tracks: [Track],
        availabilityByTrackID: [Int64: TrackAvailability] = [:]
    ) {
        var localTracks = 0
        var downloadingTracks = 0
        var failedTracks = 0
        var notDownloadedTracks = 0

        for track in tracks {
            let availability = track.id.flatMap { availabilityByTrackID[$0] }
                ?? track.availability()

            switch availability {
            case .local, .fileMissing:
                localTracks += 1
            case .downloading:
                downloadingTracks += 1
            case .failed:
                failedTracks += 1
            case .notDownloaded:
                notDownloadedTracks += 1
            }
        }

        self.init(
            playlistID: playlistID,
            totalTracks: tracks.count,
            localTracks: localTracks,
            downloadingTracks: downloadingTracks,
            failedTracks: failedTracks,
            notDownloadedTracks: notDownloadedTracks
        )
    }

    var missingTracks: Int {
        notDownloadedTracks
    }

    var isImporting: Bool {
        downloadingTracks > 0
    }

    var isIncomplete: Bool {
        failedTracks > 0
    }
}

/// A track's membership in a playlist with fractional position.
struct PlaylistTrack: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
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

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
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
            coverIsCustom: 0,
            coverImagePath: nil,
            coverImageUrl: nil,
            sourceId: nil,
            externalId: nil,
            dateCreated: nil,
            mlmUuid: nil
        )
    }
}
