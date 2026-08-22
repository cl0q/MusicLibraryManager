import Foundation
import GRDB

/// An album in the library.
///
/// Maps to the `albums` table (v16+). Albums are auto-detected from
/// track metadata and support variant grouping (e.g., base vs. deluxe).
struct Album: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    var id: Int64?
    var artist: String
    var albumArtist: String
    var title: String
    var titleNormalized: String
    var year: Int?
    var coverPath: String?
    var variantOf: Int64?
    var variantKind: String?

    static let databaseTableName = "albums"

    enum CodingKeys: String, CodingKey {
        case id, artist, title, year
        case albumArtist = "album_artist"
        case titleNormalized = "title_normalized"
        case coverPath = "cover_path"
        case variantOf = "variant_of"
        case variantKind = "variant_kind"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let artist = Column(CodingKeys.artist)
        static let albumArtist = Column(CodingKeys.albumArtist)
        static let title = Column(CodingKeys.title)
        static let titleNormalized = Column(CodingKeys.titleNormalized)
        static let variantOf = Column(CodingKeys.variantOf)
        static let variantKind = Column(CodingKeys.variantKind)
    }

    /// Whether this is a base album (not a variant of another).
    var isBase: Bool {
        variantOf == nil
    }
}

/// User's variant preference for an album group.
///
/// Tracks which variant the user last viewed so the UI can restore state.
struct UserAlbumVariantPref: Codable, FetchableRecord, PersistableRecord {
    var userId: String
    var baseAlbumId: Int64
    var selectedAlbumId: Int64
    var updatedAt: String

    static let databaseTableName = "user_album_variant_pref"

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case baseAlbumId = "base_album_id"
        case selectedAlbumId = "selected_album_id"
        case updatedAt = "updated_at"
    }
}
