import Foundation
import GRDB

// MARK: - Migration (v52)

/// The body of `v52_album_suggestions` (W4-3, IMP-082/084), registered in
/// `DatabaseManager.buildMigrator()`. Idempotent; no backfill.
enum AlbumSuggestionMigration {
    static func v52(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS album_suggestions (
                track_id INTEGER PRIMARY KEY,
                album_title TEXT NOT NULL,
                album_artist TEXT NOT NULL DEFAULT '',
                year INTEGER,
                track_number INTEGER,
                disc INTEGER,
                source TEXT NOT NULL,
                match REAL NOT NULL,
                alternatives_json TEXT NOT NULL DEFAULT '[]',
                status TEXT NOT NULL DEFAULT 'pending',
                decided_at TEXT
            )
            """)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_album_suggestions_status ON album_suggestions(status)")
        if try !db.columns(in: "tracks").contains(where: { $0.name == "no_album" }) {
            try db.execute(sql: "ALTER TABLE tracks ADD COLUMN no_album INTEGER NOT NULL DEFAULT 0")
        }
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tracks_no_album ON tracks(id) WHERE no_album = 1")
    }
}

// MARK: - Values

/// One album a track may belong to, as a provider found it (`AlbumSuggesting`).
struct AlbumSuggestion: Codable, Equatable, Hashable, Sendable {
    var albumTitle: String
    /// Empty = not known (the track's own artist is used).
    var albumArtist: String = ""
    var year: Int?
    var trackNumber: Int?
    var disc: Int?
    /// The display word: `Library tags`, `Folder name`, `File name`.
    var source: String
    /// Percent, 0…100.
    var match: Double

    enum CodingKeys: String, CodingKey {
        case albumTitle = "album_title", albumArtist = "album_artist", year
        case trackNumber = "track_number", disc, source, match
    }

    /// Whole percent.
    var matchPercent: Int { Int(match.rounded()) }
}

enum AlbumSuggestionStatus: String, Codable, Sendable {
    case pending
    case accepted
    case rejected
    case noAlbum = "no_album"
    /// Looked up, nothing found.
    case noMatch = "no_match"
}

/// A track's row in `album_suggestions`: the best candidate, the others, the decision.
struct AlbumSuggestionRow: Equatable, Sendable {
    var trackID: Int64
    /// The best candidate. For `no_match` the title is empty and the match 0.
    var suggestion: AlbumSuggestion
    var alternatives: [AlbumSuggestion]
    var status: AlbumSuggestionStatus
    var decidedAt: String?

    init(trackID: Int64, suggestion: AlbumSuggestion, alternatives: [AlbumSuggestion], status: AlbumSuggestionStatus, decidedAt: String?) {
        self.trackID = trackID
        self.suggestion = suggestion
        self.alternatives = alternatives
        self.status = status
        self.decidedAt = decidedAt
    }

    init(row: Row) {
        trackID = row["track_id"]
        suggestion = AlbumSuggestion(
            albumTitle: row["album_title"], albumArtist: row["album_artist"], year: row["year"],
            trackNumber: row["track_number"], disc: row["disc"], source: row["source"], match: row["match"])
        let json: String = row["alternatives_json"]
        alternatives = (try? JSONDecoder().decode([AlbumSuggestion].self, from: Data(json.utf8))) ?? []
        status = AlbumSuggestionStatus(rawValue: row["status"]) ?? .pending
        decidedAt = row["decided_at"]
    }

    var hasSuggestion: Bool { !suggestion.albumTitle.isEmpty }

    /// A row from the lookup: the best candidate first, the rest as alternatives; `no_match` for none.
    static func looked(up trackID: Int64, candidates: [AlbumSuggestion]) -> AlbumSuggestionRow {
        let ranked = candidates.sorted { $0.match > $1.match }
        guard let best = ranked.first else {
            return AlbumSuggestionRow(trackID: trackID, suggestion: AlbumSuggestion(albumTitle: "", source: "", match: 0),
                                      alternatives: [], status: .noMatch, decidedAt: nil)
        }
        return AlbumSuggestionRow(trackID: trackID, suggestion: best, alternatives: Array(ranked.dropFirst()),
                                  status: .pending, decidedAt: nil)
    }

    /// The row with alternative `index` made the suggestion (the old one takes its place among the alternatives).
    func choosing(alternativeAt index: Int) -> AlbumSuggestionRow {
        guard alternatives.indices.contains(index) else { return self }
        var copy = self
        copy.suggestion = alternatives[index]
        copy.alternatives[index] = suggestion
        return copy
    }

    var arguments: StatementArguments {
        let json = (try? JSONEncoder().encode(alternatives)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let values: [(any DatabaseValueConvertible)?] = [
            trackID, suggestion.albumTitle, suggestion.albumArtist, suggestion.year, suggestion.trackNumber,
            suggestion.disc, suggestion.source, suggestion.match, json, status.rawValue, decidedAt,
        ]
        return StatementArguments(values)
    }
}

/// The Review ▸ Albums filter (`Suggestions · No Match · No Album`).
enum AlbumSuggestionFilter: String, CaseIterable, Identifiable, Sendable {
    case suggestions
    case noMatch
    case noAlbum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .suggestions: "Suggestions"
        case .noMatch: "No Match"
        case .noAlbum: "No Album"
        }
    }
}

/// A listed track with its suggestion row.
struct AlbumSuggestionItem: Identifiable, Equatable, Sendable {
    var track: Track
    var row: AlbumSuggestionRow

    var id: Int64 { row.trackID }
}

struct AlbumSuggestionCounts: Equatable, Sendable {
    /// Listed tracks with a pending suggestion (status `pending`, still no album).
    var pending = 0
    var noMatch = 0
    /// Listed tracks confirmed `No album`.
    var noAlbum = 0
    /// Every row, whatever its status (0 = no lookup has run).
    var rows = 0

    func count(for filter: AlbumSuggestionFilter) -> Int {
        switch filter {
        case .suggestions: pending
        case .noMatch: noMatch
        case .noAlbum: noAlbum
        }
    }
}

// MARK: - Repository

/// `album_suggestions` (v52): one row per looked-up track. Reads only listed tracks that still
/// have no album text (a track whose album was set another way drops out of the lists without
/// a decision); decisions and the lookup write here.
final class AlbumSuggestionRepository: Sendable {
    let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    /// Where a track's row is still a question: listed, no album text, not confirmed `No album`.
    private static let openTrack = "\(TrackVisibility.listedSQL) AND \(TrackSearchSQL.noAlbumText) AND tracks.no_album = 0"

    // MARK: Read

    func row(trackID: Int64) async throws -> AlbumSuggestionRow? {
        try await database.read { db in try Self.row(db, trackID: trackID) }
    }

    static func row(_ db: Database, trackID: Int64) throws -> AlbumSuggestionRow? {
        try Row.fetchOne(db, sql: "SELECT * FROM album_suggestions WHERE track_id = ?", arguments: [trackID]).map(AlbumSuggestionRow.init(row:))
    }

    func rows(trackIDs: [Int64]) async throws -> [AlbumSuggestionRow] {
        try await database.read { db in
            try trackIDs.compactMap { try Self.row(db, trackID: $0) }
        }
    }

    /// The rows of `filter`, best match first (then artist, title).
    func pending(filter: AlbumSuggestionFilter) async throws -> [AlbumSuggestionItem] {
        try await database.read { db in
            let predicate: String
            switch filter {
            case .suggestions: predicate = "s.status = 'pending' AND \(Self.openTrack)"
            case .noMatch: predicate = "s.status = 'no_match' AND \(Self.openTrack)"
            case .noAlbum: predicate = "tracks.no_album = 1 AND \(TrackVisibility.listedSQL)"
            }
            let join = filter == .noAlbum ? "LEFT JOIN" : "JOIN"
            let tracks = try Track.fetchAll(db, sql: """
                SELECT tracks.* FROM tracks
                \(join) album_suggestions s ON s.track_id = tracks.id
                WHERE \(predicate)
                ORDER BY COALESCE(s.match, 0) DESC, tracks.artist COLLATE NOCASE, tracks.title COLLATE NOCASE, tracks.id
                """)
            var items: [AlbumSuggestionItem] = []
            for track in tracks {
                guard let id = track.id else { continue }
                let row = try Self.row(db, trackID: id)
                    ?? AlbumSuggestionRow(trackID: id, suggestion: AlbumSuggestion(albumTitle: "", source: "", match: 0),
                                          alternatives: [], status: .noAlbum, decidedAt: nil)
                items.append(AlbumSuggestionItem(track: track, row: row))
            }
            return items
        }
    }

    /// The album each item's suggestion names, where that album already exists (track id →
    /// album id) — `Show Suggested Album` is enabled only for these. The same key
    /// `AlbumKey.findOrCreate` uses; nothing is created.
    func existingAlbumIDs(for items: [AlbumSuggestionItem]) async throws -> [Int64: Int64] {
        try await database.read { db in
            var result: [Int64: Int64] = [:]
            for item in items where item.row.hasSuggestion {
                let suggestion = item.row.suggestion
                if let id = try AlbumKey.find(db, artist: item.track.artist,
                                              albumArtist: suggestion.albumArtist.isEmpty ? item.track.albumArtist : suggestion.albumArtist,
                                              title: suggestion.albumTitle) { result[item.id] = id }
            }
            return result
        }
    }

    func counts() async throws -> AlbumSuggestionCounts {
        try await database.read { db in
            func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? 0 }
            return AlbumSuggestionCounts(
                pending: try count("""
                    SELECT COUNT(*) FROM album_suggestions s JOIN tracks ON tracks.id = s.track_id
                    WHERE s.status = 'pending' AND \(Self.openTrack)
                    """),
                noMatch: try count("""
                    SELECT COUNT(*) FROM album_suggestions s JOIN tracks ON tracks.id = s.track_id
                    WHERE s.status = 'no_match' AND \(Self.openTrack)
                    """),
                noAlbum: try count("SELECT COUNT(*) FROM tracks WHERE tracks.no_album = 1 AND \(TrackVisibility.listedSQL)"),
                rows: try count("SELECT COUNT(*) FROM album_suggestions"))
        }
    }

    /// Pending suggestions with a match above `percent` (the bulk Accept).
    func pending(above percent: Double) async throws -> [AlbumSuggestionItem] {
        try await pending(filter: .suggestions).filter { $0.row.suggestion.match > percent }
    }

    /// Tracks the lookup would look at: listed, no album, not `No album`, no row yet.
    func candidatesForLookup(limit: Int? = nil) async throws -> [Track] {
        try await database.read { db in
            try Track.fetchAll(db, sql: """
                SELECT tracks.* FROM tracks
                WHERE \(Self.openTrack)
                  AND NOT EXISTS (SELECT 1 FROM album_suggestions s WHERE s.track_id = tracks.id)
                ORDER BY tracks.id
                \(limit.map { "LIMIT \($0)" } ?? "")
                """)
        }
    }

    func candidateCount() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM tracks
                WHERE \(Self.openTrack)
                  AND NOT EXISTS (SELECT 1 FROM album_suggestions s WHERE s.track_id = tracks.id)
                """) ?? 0
        }
    }

    // MARK: Write

    func upsert(_ rows: [AlbumSuggestionRow]) async throws {
        guard !rows.isEmpty else { return }
        try await database.write { db in try Self.upsert(db, rows) }
    }

    static func upsert(_ db: Database, _ rows: [AlbumSuggestionRow]) throws {
        for row in rows {
            try db.execute(sql: """
                INSERT OR REPLACE INTO album_suggestions
                (track_id, album_title, album_artist, year, track_number, disc, source, match, alternatives_json, status, decided_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: row.arguments)
        }
    }

    /// Sets the status of existing rows. Returns the rows as they were (for undo).
    @discardableResult
    func setStatus(_ status: AlbumSuggestionStatus, trackIDs: [Int64], decidedAt: String? = nil) async throws -> [AlbumSuggestionRow] {
        try await database.write { db in try Self.setStatus(db, status, trackIDs: trackIDs, decidedAt: decidedAt) }
    }

    @discardableResult
    static func setStatus(_ db: Database, _ status: AlbumSuggestionStatus, trackIDs: [Int64], decidedAt: String?) throws -> [AlbumSuggestionRow] {
        var before: [AlbumSuggestionRow] = []
        for id in Set(trackIDs) {
            guard let row = try row(db, trackID: id) else { continue }
            before.append(row)
            try db.execute(sql: "UPDATE album_suggestions SET status = ?, decided_at = ? WHERE track_id = ?",
                           arguments: [status.rawValue, decidedAt, id])
        }
        return before.sorted { $0.trackID < $1.trackID }
    }

    /// Puts rows back exactly as they were; tracks in `removing` lose their row (undo of a
    /// decision on a track that had none).
    func restore(_ rows: [AlbumSuggestionRow], removing: [Int64] = []) async throws {
        try await database.write { db in
            for id in removing { try db.execute(sql: "DELETE FROM album_suggestions WHERE track_id = ?", arguments: [id]) }
            try Self.upsert(db, rows)
        }
    }

    /// `tracks.no_album` for the tracks; returns the ids whose value changed.
    @discardableResult
    func setNoAlbum(_ flag: Bool, trackIDs: [Int64]) async throws -> [Int64] {
        try await database.write { db in try Self.setNoAlbum(db, flag, trackIDs: trackIDs) }
    }

    static func setNoAlbum(_ db: Database, _ flag: Bool, trackIDs: [Int64]) throws -> [Int64] {
        var changed: [Int64] = []
        for id in Set(trackIDs).sorted() {
            try db.execute(sql: "UPDATE tracks SET no_album = ? WHERE id = ? AND no_album <> ?", arguments: [flag ? 1 : 0, id, flag ? 1 : 0])
            if db.changesCount > 0 { changed.append(id) }
        }
        return changed
    }

    /// Makes alternative `index` the suggestion of a pending row (nothing else is written).
    func choose(alternativeAt index: Int, trackID: Int64) async throws -> AlbumSuggestionRow? {
        try await database.write { db in
            guard let row = try Self.row(db, trackID: trackID), row.status == .pending,
                  row.alternatives.indices.contains(index) else { return nil }
            let chosen = row.choosing(alternativeAt: index)
            try Self.upsert(db, [chosen])
            return chosen
        }
    }

    func delete(trackIDs: [Int64]) async throws {
        try await database.write { db in
            for id in trackIDs { try db.execute(sql: "DELETE FROM album_suggestions WHERE track_id = ?", arguments: [id]) }
        }
    }
}
