import Foundation
import GRDB

/// The genre queries of the Genres place (V-GENRES, V-GENRED): counts by genre in SQL
/// (`GROUP BY genre`, UC-TABLE-21), the tracks of genres by key, and the facts the suggestions
/// need (is a track analysed, a typical track). Read-only — every genre change is a tag edit
/// (`GenreEdits` → `TrackTagEdit`), never an `UPDATE` here.
///
/// No table of its own (no migration): genre is `tracks.genre`, similarity comes from
/// `track_embeddings`.
final class GenreRepository: Sendable {
    private let database: any DatabaseReader

    init(database: any DatabaseReader) {
        self.database = database
    }

    @MainActor
    static func live(_ container: DependencyContainer = .shared) -> GenreRepository? {
        container.databaseManager.map { GenreRepository(database: $0.pool) }
    }

    // MARK: - The list

    /// Every genre with its count and time, plus the tracks without a genre.
    func overview() async throws -> GenreOverview {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT genre, COUNT(*) AS n, COALESCE(SUM(COALESCE(duration, 0)), 0) AS d
                FROM tracks
                WHERE genre IS NOT NULL AND TRIM(genre) != ''
                GROUP BY genre
                """).map { row in (genre: row["genre"] as String, count: row["n"] as Int, duration: row["d"] as Int) }
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? 0
            return GenreOverview.fold(rows: rows, totalTracks: total)
        }
    }

    // MARK: - Tracks of genres

    /// The tracks whose genre has one of `keys`, by id.
    func tracks(genreKeys keys: Set<String>) async throws -> [Track] {
        guard !keys.isEmpty else { return [] }
        return try await database.read { db in
            let spellings = try Self.spellings(db, keys: keys)
            var tracks: [Track] = []
            for batch in spellings.chunked(into: 400) {
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
                tracks += try Track.fetchAll(db, sql: "SELECT * FROM tracks WHERE genre IN (\(placeholders))",
                                             arguments: StatementArguments(batch))
            }
            return tracks.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        }
    }

    /// The ids of the tracks whose genre has one of `keys`.
    func trackIDs(genreKeys keys: Set<String>) async throws -> [Int64] {
        guard !keys.isEmpty else { return [] }
        return try await database.read { db in
            let spellings = try Self.spellings(db, keys: keys)
            var ids: [Int64] = []
            for batch in spellings.chunked(into: 400) {
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
                ids += try Int64.fetchAll(db, sql: "SELECT id FROM tracks WHERE genre IN (\(placeholders))",
                                          arguments: StatementArguments(batch))
            }
            return ids.sorted()
        }
    }

    /// Every track that has a genre (the Create ML export plan).
    func tracksWithGenre() async throws -> [Track] {
        try await database.read { db in
            try Track.fetchAll(db, sql: "SELECT * FROM tracks WHERE genre IS NOT NULL AND TRIM(genre) != '' ORDER BY id")
        }
    }

    /// The exact stored spellings whose key is in `keys` (keys fold case in Swift, which SQLite's
    /// `LOWER` does only for ASCII).
    private static func spellings(_ db: Database, keys: Set<String>) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT DISTINCT genre FROM tracks WHERE genre IS NOT NULL")
            .filter { GenreName.key($0).map(keys.contains) ?? false }
    }

    // MARK: - Similarity facts (Suggested tracks)

    /// Whether the track has the similarity analysis suggestions compare with.
    func hasSimilarityAnalysis(trackID: Int64) async throws -> Bool {
        try await database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM track_embeddings WHERE track_id = ?)",
                              arguments: [trackID]) ?? false
        }
    }

    /// `9,412 of 12,935 tracks are analysed`.
    func similarityCoverage() async throws -> (analysed: Int, total: Int) {
        try await database.read { db in
            let analysed = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM track_embeddings e JOIN tracks t ON t.id = e.track_id
                """) ?? 0
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? 0
            return (analysed, total)
        }
    }

    /// `Pick a Typical Track`: of `trackIDs`, the analysed track closest to the average sound of
    /// all analysed ones (cosine to the centroid of their embeddings). nil: none is analysed.
    func typicalTrackID(among trackIDs: [Int64]) async throws -> Int64? {
        guard !trackIDs.isEmpty else { return nil }
        let embeddings: [(Int64, [Float])] = try await database.read { db in
            var result: [(Int64, [Float])] = []
            for batch in trackIDs.chunked(into: 400) {
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
                for row in try Row.fetchAll(db, sql: """
                    SELECT track_id, master_embedding FROM track_embeddings WHERE track_id IN (\(placeholders))
                    """, arguments: StatementArguments(batch)) {
                    let vector = [Float].fromData(row["master_embedding"])
                    if !vector.isEmpty { result.append((row["track_id"], vector)) }
                }
            }
            return result
        }
        return Self.typical(embeddings)
    }

    /// The id whose vector is closest to the centroid (ties: the lower id). Vectors of another
    /// length than the first are ignored.
    static func typical(_ embeddings: [(Int64, [Float])]) -> Int64? {
        guard let dimension = embeddings.first?.1.count, dimension > 0 else { return nil }
        let usable = embeddings.filter { $0.1.count == dimension }
        var centroid = [Float](repeating: 0, count: dimension)
        for (_, vector) in usable {
            for index in 0..<dimension { centroid[index] += vector[index] }
        }
        let scale = 1 / Float(usable.count)
        for index in 0..<dimension { centroid[index] *= scale }
        var best: (id: Int64, score: Float)?
        for (id, vector) in usable.sorted(by: { $0.0 < $1.0 }) {
            let score = VectorMath.cosineSimilarity(vector, centroid)
            if best == nil || score > best!.score { best = (id, score) }
        }
        return best?.id
    }
}
