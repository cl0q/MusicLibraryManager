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
    var dateAddedLibrary: String?
    var variantOf: Int64?
    var downloadStatus: String?
    var downloadFailure: String? = nil
    var lufsI: Double?
    var lufsRange: Double?
    var truePeak: Double?
    var energyBucket: Int?
    var danceability: Double?
    var bpm: Int?
    var albumId: Int64?
    var searchText: String?
    var playlistPosition: String? = nil
    /// Stable UUID identity for iOS sidecar sync (lazy UUIDv4 uppercase string).
    var mlmUuid: String? = nil
    /// `file_missing_since` (v42): ISO 8601 time a reconciliation found the file absent while
    /// the library folder was reachable; `nil` = present or never checked. Read-only here:
    /// it is deliberately **not** written by `encode(to:)`, so saving a track never clobbers
    /// the reconciler's fact — `TrackRepository` writes it.
    var fileMissingSince: String? = nil

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
        static let dateAddedLibrary = Column(CodingKeys.dateAddedLibrary)
        static let variantOf = Column(CodingKeys.variantOf)
        static let downloadStatus = Column(CodingKeys.downloadStatus)
        static let downloadFailure = Column(CodingKeys.downloadFailure)
        static let lufsI = Column(CodingKeys.lufsI)
        static let lufsRange = Column(CodingKeys.lufsRange)
        static let truePeak = Column(CodingKeys.truePeak)
        static let energyBucket = Column(CodingKeys.energyBucket)
        static let danceability = Column(CodingKeys.danceability)
        static let bpm = Column(CodingKeys.bpm)
        static let albumId = Column(CodingKeys.albumId)
        static let searchText = Column(CodingKeys.searchText)
        static let mlmUuid = Column(CodingKeys.mlmUuid)
        static let fileMissingSince = Column(CodingKeys.fileMissingSince)
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
        case dateAddedLibrary = "date_added_library"
        case variantOf = "variant_of"
        case downloadStatus = "download_status"
        case downloadFailure = "download_failure"
        case lufsI = "lufs_i"
        case lufsRange = "lufs_range"
        case truePeak = "true_peak"
        case energyBucket = "energy_bucket"
        case danceability
        case bpm
        case albumId = "album_id"
        case searchText = "search_text"
        case playlistPosition = "playlist_position"
        case mlmUuid = "mlm_uuid"
        case fileMissingSince = "file_missing_since"
    }

    // MARK: - Computed Properties

    /// Dynamic row identifier for Identifiable SwiftUI collection bindings.
    var rowID: Int64 { id ?? -1 }

    /// Whether this track has a stored local path (without verifying the file on disk).
    var isLocal: Bool {
        // An empty path is no file — the same rule as availability and the SQL (W2-A review).
        !(organizedPath ?? "").isEmpty
    }

    /// Whether this track has no stored local path.
    var isRemote: Bool {
        !isLocal
    }

    /// The decoded persisted failure details, if a download previously failed.
    var downloadFailureRecord: TrackDownloadFailure? {
        guard let downloadFailure, !downloadFailure.isEmpty else { return nil }
        return try? TrackDownloadFailure.decodeJSON(downloadFailure)
    }

    /// Stores failure details as stable JSON in the additive `download_failure` column.
    mutating func setDownloadFailureRecord(_ failure: TrackDownloadFailure?) throws {
        downloadFailure = try failure?.encodedJSON()
    }

    /// The track's availability from its persisted columns only — never the disk
    /// (UC-TABLE-20). `libraryRoot` is accepted for source compatibility and ignored: whether
    /// the file is present is the persisted `file_missing_since` fact.
    func availability(libraryRoot _: URL? = nil) -> TrackAvailability {
        TrackAvailability.derive(
            organizedPath: organizedPath,
            fileMissingSince: fileMissingSince,
            downloadStatus: downloadStatus,
            downloadFailure: downloadFailure
        )
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
        container[Columns.dateAddedLibrary] = dateAddedLibrary
        container[Columns.variantOf] = variantOf
        container[Columns.downloadStatus] = downloadStatus
        container[Columns.downloadFailure] = downloadFailure
        container[Columns.lufsI] = lufsI
        container[Columns.lufsRange] = lufsRange
        container[Columns.truePeak] = truePeak
        container[Columns.energyBucket] = energyBucket
        container[Columns.danceability] = danceability
        container[Columns.bpm] = bpm
        container[Columns.albumId] = albumId
        container[Columns.searchText] = searchText
        container[Columns.mlmUuid] = mlmUuid
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

    /// BPM sort key — nil sorts as 0.
    var bpmSortKey: Int { bpm ?? 0 }

    /// Date added sort key — nil sorts as empty string (sorts first).
    var dateAddedSortKey: String { dateAdded ?? "" }

    /// Library-added date sort key — falls back to the remote date when the
    /// library date is missing so mixed rows still sort sensibly.
    var dateAddedLibrarySortKey: String { dateAddedLibrary ?? dateAdded ?? "" }

    // MARK: - Enhanced Search Properties

    /// The raw combined string of all fields used for search indexing.
    var rawSearchText: String {
        let genreStr = genre ?? ""
        return "\(artist) \(albumArtist) \(album) \(title) \(genreStr) \(format)"
    }

    /// Determine if this track matches the given multi-term whitespace-separated search query.
    /// Uses Case/Diacritic folded normalization to match the database behavior.
    func matches(searchQuery: String) -> Bool {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let terms = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return true }

        let normalizedCombined = DatabaseManager.foldedSearchText(rawSearchText)

        for term in terms {
            let normalizedTerm = DatabaseManager.foldedSearchText(term)
            if !normalizedCombined.contains(normalizedTerm) {
                return false
            }
        }
        return true
    }
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
        self.dateAddedLibrary = nil
        self.variantOf = nil
        self.downloadStatus = nil
        self.downloadFailure = nil
        self.lufsI = nil
        self.lufsRange = nil
        self.truePeak = nil
        self.energyBucket = nil
        self.danceability = nil
        self.bpm = nil
        self.albumId = nil
        self.playlistPosition = nil
        self.mlmUuid = nil
    }
}

// MARK: - MLM UUID helpers

extension Track {
    /// Generate a fresh UUIDv4 uppercase string suitable for `mlm_uuid`.
    static func generateMlmUuid() -> String {
        UUID().uuidString.uppercased()
    }

    /// Ensure this track has an `mlm_uuid`; generate one lazily if missing.
    /// Returns `true` if a new UUID was assigned.
    @discardableResult
    mutating func ensureMlmUuid() -> Bool {
        if mlmUuid == nil {
            mlmUuid = Track.generateMlmUuid()
            return true
        }
        return false
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
