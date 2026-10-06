import Foundation
import GRDB

/// Where a reel stands (V-REELS.E04, UC §15.9): `New` (nothing decided) · `Identified` (artist
/// and title set) · `Done` (downloaded, added to a playlist or marked by hand).
enum ReelState: String, Codable, CaseIterable, Sendable {
    case new, identified, done

    /// The state word of the reel list.
    var word: String {
        switch self {
        case .new: "New"
        case .identified: "Identified"
        case .done: "Done"
        }
    }

    /// The state a reel with these fields has when nothing finished it: both fields → `Identified`.
    static func derived(artist: String, title: String) -> ReelState {
        let hasBoth = !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasBoth ? .identified : .new
    }
}

/// A video queued in Discover → Reels. The media remains at its original URL;
/// MLM only persists the workflow state needed to resume identification later.
struct ImportedReelRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    var id: String
    var filePath: String
    var title: String
    var artist: String
    var createdAt: Date
    var updatedAt: Date
    /// `v55_reel_state`.
    var state: ReelState = .new
    /// The competing guesses with provenance, as JSON (`ReelGuesses.encode`); nil = none yet.
    var guessesJSON: String?
    /// ISO 8601 time the reel became `Done`; nil otherwise.
    var doneAt: String?

    static let databaseTableName = "imported_reels"

    enum Columns {
        static let createdAt = Column(CodingKeys.createdAt)
        static let state = Column(CodingKeys.state)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case filePath = "file_path"
        case title
        case artist
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case state
        case guessesJSON = "guesses_json"
        case doneAt = "done_at"
    }

    init(id: String, filePath: String, title: String, artist: String, createdAt: Date, updatedAt: Date,
         state: ReelState = .new, guessesJSON: String? = nil, doneAt: String? = nil) {
        self.id = id
        self.filePath = filePath
        self.title = title
        self.artist = artist
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.guessesJSON = guessesJSON
        self.doneAt = doneAt
    }
}
