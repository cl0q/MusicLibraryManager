import Foundation
import GRDB

/// Local GRDB record mirroring the manifest track fields needed for browsing.
/// Stored in the `indexed_tracks` table.
struct IndexedTrack: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
    var id: Int64?
    let uuid: String
    let title: String
    let artist: String
    let albumArtist: String
    let album: String
    let duration: Int
    let path: String
    let energyBucket: Int
    let lufsI: Double

    static let databaseTableName = "indexed_tracks"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let uuid = Column(CodingKeys.uuid)
        static let title = Column(CodingKeys.title)
        static let artist = Column(CodingKeys.artist)
        static let albumArtist = Column(CodingKeys.albumArtist)
        static let album = Column(CodingKeys.album)
        static let duration = Column(CodingKeys.duration)
        static let path = Column(CodingKeys.path)
        static let energyBucket = Column(CodingKeys.energyBucket)
        static let lufsI = Column(CodingKeys.lufsI)
    }

    enum CodingKeys: String, CodingKey {
        case id
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

    /// Formatted duration string (e.g., "4:14").
    var formattedDuration: String {
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Local GRDB record for manifest playlists.
struct IndexedPlaylist: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {
    var id: Int64?
    let uuid: String
    let name: String
    let file: String

    static let databaseTableName = "indexed_playlists"

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

/// Tracks the last indexed manifest generation timestamp for incremental refresh.
struct IndexState: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64 = 1
    var lastGeneratedAt: String?

    static let databaseTableName = "index_state"

    enum CodingKeys: String, CodingKey {
        case id
        case lastGeneratedAt = "last_generated_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
