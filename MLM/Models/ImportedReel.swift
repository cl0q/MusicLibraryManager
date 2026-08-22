import Foundation
import GRDB

/// A video queued in Discover → Reels. The media remains at its original URL;
/// MLM only persists the workflow state needed to resume identification later.
struct ImportedReelRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    var id: String
    var filePath: String
    var title: String
    var artist: String
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "imported_reels"

    enum Columns {
        static let createdAt = Column(CodingKeys.createdAt)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case filePath = "file_path"
        case title
        case artist
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
