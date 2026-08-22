import Foundation
import GRDB

/// A download queue item.
struct DownloadItem: Codable, Identifiable, Hashable {
    var id: Int64
    var trackId: Int64
    var artist: String
    var title: String
    var status: DownloadStatus
    var progress: Double
    var error: String?

    enum DownloadStatus: String, Codable {
        case queued
        case downloading
        case transcoding
        case completed
        case failed
        case skipped
        case cancelled
    }
}

/// A duplicate review queue item.
///
/// Maps to the `review_queue` table.
struct ReviewItem: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    var id: Int64?
    var actionType: String
    var groupKey: String? = nil
    var trackId: Int64
    var relatedTrackId: Int64?
    var details: String
    var autoAction: String?
    var status: String
    var createdAt: String?
    var resolvedAt: String?

    static let databaseTableName = "review_queue"

    enum CodingKeys: String, CodingKey {
        case id
        case actionType = "action_type"
        case groupKey = "group_key"
        case trackId = "track_id"
        case relatedTrackId = "related_track_id"
        case details
        case autoAction = "auto_action"
        case status
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let status = Column(CodingKeys.status)
        static let actionType = Column(CodingKeys.actionType)
        static let groupKey = Column(CodingKeys.groupKey)
    }

    /// Decodes the typed review payload while tolerating older pair-only rows.
    var reviewDetails: ReviewDetails? {
        try? ReviewDetails.decodeJSON(details)
    }

    mutating func setReviewDetails(_ reviewDetails: ReviewDetails) throws {
        details = try reviewDetails.encodedJSON()
        groupKey = reviewDetails.groupKey
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One pending review group, including the number of queue rows it contains.
struct ReviewQueueGroup: Codable, FetchableRecord, Equatable {
    var groupKey: String
    var actionType: String
    var itemCount: Int
    var latestCreatedAt: String?

    enum CodingKeys: String, CodingKey {
        case groupKey = "group_key"
        case actionType = "action_type"
        case itemCount = "item_count"
        case latestCreatedAt = "latest_created_at"
    }
}

/// App configuration key-value pair.
///
/// Maps to the `app_config` table.
struct AppConfig: Codable, FetchableRecord, PersistableRecord {
    var key: String
    var value: String
    var updatedAt: String?

    static let databaseTableName = "app_config"

    enum CodingKeys: String, CodingKey {
        case key, value
        case updatedAt = "updated_at"
    }

    enum Columns {
        static let key = Column(CodingKeys.key)
        static let value = Column(CodingKeys.value)
    }
}

/// Audio fingerprint data.
///
/// Maps to the `fingerprints` table.
struct Fingerprint: Codable, FetchableRecord, PersistableRecord {
    var trackId: Int64
    var fingerprint: Data
    var durationSeconds: Int
    var acoustid: String?
    var musicbrainzRecordingId: String?
    var fingerprintedAt: String?

    static let databaseTableName = "fingerprints"

    enum CodingKeys: String, CodingKey {
        case trackId = "track_id"
        case fingerprint
        case durationSeconds = "duration_seconds"
        case acoustid
        case musicbrainzRecordingId = "musicbrainz_recording_id"
        case fingerprintedAt = "fingerprinted_at"
    }
}

/// Album/track artwork metadata.
///
/// Maps to the `artwork` table.
struct Artwork: Codable, FetchableRecord, PersistableRecord {
    var trackId: Int64
    var artworkPath: String?
    var source: String?
    var musicbrainzReleaseGroupId: String?
    var resolution: String?
    var fetchedAt: String?
    var remoteUrl: String? = nil

    static let databaseTableName = "artwork"

    enum CodingKeys: String, CodingKey {
        case trackId = "track_id"
        case artworkPath = "artwork_path"
        case source
        case musicbrainzReleaseGroupId = "musicbrainz_release_group_id"
        case resolution
        case fetchedAt = "fetched_at"
        case remoteUrl = "remote_url"
    }
}

/// ReplayGain loudness normalization data.
///
/// Maps to the `replaygain` table.
struct ReplayGain: Codable, FetchableRecord, PersistableRecord {
    var trackId: Int64
    var trackGain: Double
    var trackPeak: Double
    var albumGain: Double?
    var albumPeak: Double?
    var analyzedAt: String?

    static let databaseTableName = "replaygain"

    enum CodingKeys: String, CodingKey {
        case trackId = "track_id"
        case trackGain = "track_gain"
        case trackPeak = "track_peak"
        case albumGain = "album_gain"
        case albumPeak = "album_peak"
        case analyzedAt = "analyzed_at"
    }
}

/// Track analysis cache (ffprobe, fingerprint, spectrogram).
///
/// Maps to the `track_analysis` table.
struct TrackAnalysis: Codable, FetchableRecord, PersistableRecord {
    var trackId: Int64
    var ffprobeOutput: String?
    var fingerprint: String?
    var spectrogramPath: String?
    var analysisTimestamp: String

    static let databaseTableName = "track_analysis"

    enum CodingKeys: String, CodingKey {
        case trackId = "track_id"
        case ffprobeOutput = "ffprobe_output"
        case fingerprint
        case spectrogramPath = "spectrogram_path"
        case analysisTimestamp = "analysis_timestamp"
    }
}

/// A tag on a track (key-value pair).
///
/// Maps to the `track_tags` table.
struct TrackTag: Codable, FetchableRecord, PersistableRecord {
    var trackId: Int64
    var tagKey: String
    var tagValue: String

    static let databaseTableName = "track_tags"

    enum CodingKeys: String, CodingKey {
        case trackId = "track_id"
        case tagKey = "tag_key"
        case tagValue = "tag_value"
    }

    enum Columns {
        static let trackId = Column(CodingKeys.trackId)
        static let tagKey = Column(CodingKeys.tagKey)
        static let tagValue = Column(CodingKeys.tagValue)
    }
}
