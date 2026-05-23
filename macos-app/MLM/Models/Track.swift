import Foundation
import GRDB
import UniformTypeIdentifiers
import SwiftUI


/// A music track in the library.
///
/// Maps directly to the `tracks` table in SQLite.
/// Shares the same schema as the Tauri app's Rust `Track` struct.
struct Track: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    var id: Int64?
    var artist: String
    var albumArtist: String
    var album: String
    var title: String
    var genre: String?
    var year: Int?
    var bitrate: Int?
    var duration: Int?
    var format: String
    var originalPath: String
    var organizedPath: String?
    var isDuplicate: Int
    var dateAdded: String?
    var variantOf: Int64?
    var downloadStatus: String?
    var lufsI: Double?
    var lufsRange: Double?
    var truePeak: Double?
    var energyBucket: Int?
    var danceability: Double?
    var albumId: Int64?
    var searchText: String?
    var playlistPosition: String? = nil

    static let databaseTableName = "tracks"


    // MARK: - Column mapping

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let artist = Column(CodingKeys.artist)
        static let albumArtist = Column(CodingKeys.albumArtist)
        static let album = Column(CodingKeys.album)
        static let title = Column(CodingKeys.title)
        static let genre = Column(CodingKeys.genre)
        static let year = Column(CodingKeys.year)
        static let bitrate = Column(CodingKeys.bitrate)
        static let duration = Column(CodingKeys.duration)
        static let format = Column(CodingKeys.format)
        static let originalPath = Column(CodingKeys.originalPath)
        static let organizedPath = Column(CodingKeys.organizedPath)
        static let isDuplicate = Column(CodingKeys.isDuplicate)
        static let dateAdded = Column(CodingKeys.dateAdded)
        static let variantOf = Column(CodingKeys.variantOf)
        static let downloadStatus = Column(CodingKeys.downloadStatus)
        static let lufsI = Column(CodingKeys.lufsI)
        static let lufsRange = Column(CodingKeys.lufsRange)
        static let truePeak = Column(CodingKeys.truePeak)
        static let energyBucket = Column(CodingKeys.energyBucket)
        static let danceability = Column(CodingKeys.danceability)
        static let albumId = Column(CodingKeys.albumId)
        static let searchText = Column(CodingKeys.searchText)
    }

    // MARK: - Snake case mapping

    enum CodingKeys: String, CodingKey {
        case id
        case artist
        case albumArtist = "album_artist"
        case album
        case title
        case genre
        case year
        case bitrate
        case duration
        case format
        case originalPath = "original_path"
        case organizedPath = "organized_path"
        case isDuplicate = "is_duplicate"
        case dateAdded = "date_added"
        case variantOf = "variant_of"
        case downloadStatus = "download_status"
        case lufsI = "lufs_i"
        case lufsRange = "lufs_range"
        case truePeak = "true_peak"
        case energyBucket = "energy_bucket"
        case danceability
        case albumId = "album_id"
        case searchText = "search_text"
        case playlistPosition = "playlist_position"
    }

    // MARK: - Computed Properties

    /// Whether this track exists as a local file (not just a remote reference).
    var isLocal: Bool {
        organizedPath != nil
    }

    /// Whether this track is a remote-only reference (from streaming source).
    var isRemote: Bool {
        organizedPath == nil
    }

    /// Formatted duration string (e.g., "3:24")
    var formattedDuration: String {
        guard let dur = duration else { return "—" }
        let minutes = dur / 60
        let seconds = dur % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - MutablePersistableRecord

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.artist] = artist
        container[Columns.albumArtist] = albumArtist
        container[Columns.album] = album
        container[Columns.title] = title
        container[Columns.genre] = genre
        container[Columns.year] = year
        container[Columns.bitrate] = bitrate
        container[Columns.duration] = duration
        container[Columns.format] = format
        container[Columns.originalPath] = originalPath
        container[Columns.organizedPath] = organizedPath
        container[Columns.isDuplicate] = isDuplicate
        container[Columns.dateAdded] = dateAdded
        container[Columns.variantOf] = variantOf
        container[Columns.downloadStatus] = downloadStatus
        container[Columns.lufsI] = lufsI
        container[Columns.lufsRange] = lufsRange
        container[Columns.truePeak] = truePeak
        container[Columns.energyBucket] = energyBucket
        container[Columns.danceability] = danceability
        container[Columns.albumId] = albumId
        container[Columns.searchText] = searchText
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Sort Keys for Table columns

/// `KeyPathComparator` requires `Comparable` values. Optional fields map
/// to a non-optional sort key so that `nil` sorts last (or as empty).
extension Track {
    /// Duration sort key — nil sorts as 0.
    var durationSortKey: Int { duration ?? 0 }

    /// Bitrate sort key — nil sorts as 0.
    var bitrateSortKey: Int { bitrate ?? 0 }

    /// Genre sort key — nil sorts as empty string.
    var genreSortKey: String { genre ?? "" }

    /// Year sort key — nil sorts as 0.
    var yearSortKey: Int { year ?? 0 }

    /// Energy bucket sort key — nil sorts as 0.
    var energySortKey: Int { energyBucket ?? 0 }

    /// Danceability sort key — nil sorts as 0.0.
    var danceabilitySortKey: Double { danceability ?? 0.0 }

    /// Date added sort key — nil sorts as empty string (sorts first).
    var dateAddedSortKey: String { dateAdded ?? "" }
}

// MARK: - Defaults

extension Track {
    /// Create a new track with required fields, defaulting optional ones.
    init(
        artist: String,
        albumArtist: String? = nil,
        album: String,
        title: String,
        format: String,
        originalPath: String
    ) {
        self.id = nil
        self.artist = artist
        self.albumArtist = albumArtist ?? artist
        self.album = album
        self.title = title
        self.genre = nil
        self.year = nil
        self.bitrate = nil
        self.duration = nil
        self.format = format
        self.originalPath = originalPath
        self.organizedPath = nil
        self.isDuplicate = 0
        self.dateAdded = nil
        self.variantOf = nil
        self.downloadStatus = nil
        self.lufsI = nil
        self.lufsRange = nil
        self.truePeak = nil
        self.energyBucket = nil
        self.danceability = nil
        self.albumId = nil
        self.playlistPosition = nil
    }
}

// MARK: - Drag and Drop Transferable

/// Transferable representation for dragging tracks.
struct TrackDragData: Codable, Transferable {
    let trackId: Int64
    let sourcePlaylistId: Int64? // nil if dragged from Library or Folders

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .trackDrag)
    }
}

extension UTType {
    static var trackDrag: UTType {
        UTType("com.musiclibrary.trackdrag") ?? .data
    }
}

