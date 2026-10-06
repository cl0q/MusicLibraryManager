import Foundation
import GRDB

// MARK: - The search field in SQL (W2-I, UC-SEARCH-04)

/// The search filter as a SQL predicate over `tracks` — the in-memory twin is
/// `SearchFilter.matches(_:)`. Free words match the folded `search_text` (AND), like the
/// table's old in-place filter; tokens of one kind are OR-ed, kinds AND-ed.
enum TrackSearchSQL {
    /// `1` for an empty filter.
    static func predicate(for filter: SearchFilter) -> (String, StatementArguments) {
        var clauses: [String] = []
        var arguments = StatementArguments()

        for term in filter.freeTerms {
            clauses.append("search_text LIKE ?")
            arguments += ["%\(DatabaseManager.foldedSearchText(term))%"]
        }
        let grouped = Dictionary(grouping: filter.allTokens, by: \.kind)
        for kind in SearchTokenKind.allCases {
            guard let tokens = grouped[kind], !tokens.isEmpty else { continue }
            var alternatives: [String] = []
            for token in tokens {
                let (sql, args) = predicate(for: token)
                alternatives.append(sql)
                arguments += args
            }
            clauses.append("(" + alternatives.joined(separator: " OR ") + ")")
        }
        guard !clauses.isEmpty else { return ("1", StatementArguments()) }
        return (clauses.joined(separator: " AND "), arguments)
    }

    /// Album values that aren't albums (UC-TABLE-11, `TrackMetadataPresentation`).
    static let noAlbum: String = {
        let literals = TrackMetadataPresentation.nonAlbumLiterals.sorted().map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
        return """
            (TRIM(COALESCE(album, '')) = '' OR LOWER(TRIM(album)) IN (\(literals.joined(separator: ", "))) \
            OR LOWER(TRIM(album)) LIKE 'http://%' OR LOWER(TRIM(album)) LIKE 'https://%' OR LOWER(TRIM(album)) LIKE 'www.%')
            """
    }()

    private static func predicate(for token: SearchToken) -> (String, StatementArguments) {
        switch (token.kind, token.value) {
        case (.artist, .text(let value, let exact)):
            let (a, aArgs) = text(column: "artist", value, exact)
            let (b, bArgs) = text(column: "album_artist", value, exact)
            var args = aArgs
            args += bArgs
            return ("(\(a) OR \(b))", args)
        case (.album, .text(let value, let exact)):
            return text(column: "album", value, exact)
        case (.genre, .text(let value, let exact)):
            return text(column: "genre", value, exact)
        case (.year, .range(let range)):
            return ("(year BETWEEN ? AND ?)", [range.lower, range.upper])
        case (.bpm, .range(let range)):
            return ("(bpm BETWEEN ? AND ?)", [range.lower, range.upper])
        case (.availability, .word(let word)):
            return availability(word)
        default:
            return ("0", StatementArguments())
        }
    }

    private static func text(column: String, _ value: String, _ exact: Bool) -> (String, StatementArguments) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if exact {
            return ("(TRIM(COALESCE(\(column), '')) = ? COLLATE NOCASE)", [trimmed])
        }
        return ("(COALESCE(\(column), '') LIKE ?)", ["%\(trimmed)%"])
    }

    private static func availability(_ word: SearchAvailabilityWord) -> (String, StatementArguments) {
        switch word {
        case .local: return (TrackAvailabilitySQL.local, [])
        case .notDownloaded: return (TrackAvailabilitySQL.notDownloadedScope, [])
        case .downloadFailed: return (TrackAvailabilitySQL.failed, [])
        case .fileMissing: return (TrackAvailabilitySQL.fileMissing, [])
        case .noAlbum: return (noAlbum, [])
        case .noGenre: return ("(TRIM(COALESCE(genre, '')) = '')", [])
        case .notAnalysed: return ("(energy_bucket IS NULL)", [])
        case .inNoPlaylist:
            return ("(NOT EXISTS (SELECT 1 FROM playlist_tracks pt WHERE pt.track_id = tracks.id))", [])
        case .linkedToSoundCloud: return linked("soundcloud", patterns: ["soundcloud://%", "%soundcloud.com%"])
        case .linkedToSpotify: return linked("spotify", patterns: ["spotify:%", "%spotify.com%"])
        case .linkedToYouTube: return linked("youtube", patterns: ["youtube://%", "%youtube.com%", "%youtu.be%"])
        }
    }

    private static func linked(_ source: String, patterns: [String]) -> (String, StatementArguments) {
        let paths = patterns.map { _ in "LOWER(original_path) LIKE ?" }.joined(separator: " OR ")
        let sql = """
            (EXISTS (SELECT 1 FROM track_sources ts JOIN sources s ON s.id = ts.source_id \
            WHERE ts.track_id = tracks.id AND s.name = ?) OR \(paths))
            """
        return (sql, StatementArguments([source] + patterns))
    }
}

/// One value offered after a filter word (`Techno 1,204`).
struct SearchValueSuggestion: Equatable, Sendable, Identifiable {
    let token: SearchToken
    /// Tracks with this value.
    let count: Int

    var id: String { token.id }
}

/// Read-only search queries over the open library (All Tracks with tokens, the Library scope,
/// token value suggestions, `In library` for online results). A sibling of `TrackScopeQueries`
/// (the repository keeps its database private to its file).
struct TrackSearchQueries: Sendable {
    let database: any DatabaseReader

    /// The open library's queries; `nil` before a library is open.
    @MainActor
    static func current(_ container: DependencyContainer = .shared) -> TrackSearchQueries? {
        container.databaseManager.map { TrackSearchQueries(database: $0.pool) }
    }

    /// Value suggestions are capped (the menu stays short; typing narrows it).
    static let suggestionLimit = 8

    // MARK: All Tracks

    /// Tracks of one availability scope matching the filter (W2-B's scope bar + the field).
    func fetchTracks(scope: TrackAvailabilityScope, filter: SearchFilter) async throws -> [Track] {
        var (predicate, arguments) = TrackSearchSQL.predicate(for: filter)
        if let scopePredicate = scope.sqlPredicate { predicate = "\(scopePredicate) AND (\(predicate))" }
        let sql = "SELECT * FROM tracks WHERE \(predicate) ORDER BY id"
        let finalArguments = arguments
        return try await database.read { db in
            try Track.fetchAll(db, sql: sql, arguments: finalArguments)
        }
    }

    /// Scope counts and durations for the filter (the scope bar follows the search).
    func scopeSummary(filter: SearchFilter) async throws -> TrackScopeSummary {
        let (predicate, arguments) = TrackSearchSQL.predicate(for: filter)
        return try await TrackScopeQueries(database: database).scopeSummary(predicate: predicate, arguments: arguments)
    }

    // MARK: Library scope

    /// The best `limit` tracks for the filter (local first, then by title) and how many match.
    func matchingTracks(filter: SearchFilter, limit: Int) async throws -> (tracks: [Track], total: Int) {
        guard !filter.isEmpty else { return ([], 0) }
        let (predicate, arguments) = TrackSearchSQL.predicate(for: filter)
        let countSQL = "SELECT COUNT(*) FROM tracks WHERE \(predicate)"
        let rowsSQL = """
            SELECT * FROM tracks WHERE \(predicate)
            ORDER BY CASE WHEN \(TrackAvailabilitySQL.local) THEN 0 ELSE 1 END, title COLLATE NOCASE, id
            LIMIT \(max(0, limit))
            """
        return try await database.read { db in
            let total = try Int.fetchOne(db, sql: countSQL, arguments: arguments) ?? 0
            let tracks = try Track.fetchAll(db, sql: rowsSQL, arguments: arguments)
            return (tracks, total)
        }
    }

    // MARK: Suggestions

    /// Library values for `kind` that contain `partial` (values starting with it first, then by
    /// track count), at most `limit`. Placeholder albums and artists are never offered.
    func valueSuggestions(kind: SearchTokenKind, partial: String, limit: Int = suggestionLimit) async throws -> [SearchValueSuggestion] {
        switch kind {
        case .artist, .album, .genre:
            let column = kind == .artist ? "artist" : kind == .album ? "album" : "genre"
            let trimmed = partial.trimmingCharacters(in: .whitespaces)
            var arguments = StatementArguments()
            var filter = "TRIM(COALESCE(\(column), '')) != ''"
            if !trimmed.isEmpty {
                filter += " AND \(column) LIKE ?"
                arguments += ["%\(trimmed)%"]
            }
            arguments += ["\(trimmed)%"]
            // Fetch a few more than shown so placeholders can be dropped afterwards.
            let sql = """
                SELECT TRIM(\(column)) AS value, COUNT(*) AS n FROM tracks
                WHERE \(filter)
                GROUP BY TRIM(\(column)) COLLATE NOCASE
                ORDER BY CASE WHEN TRIM(\(column)) LIKE ? THEN 0 ELSE 1 END, n DESC, value COLLATE NOCASE
                LIMIT \(limit + TrackMetadataPresentation.nonAlbumLiterals.count)
                """
            let finalArguments = arguments
            let rows: [(value: String, count: Int)] = try await database.read { db in
                try Row.fetchAll(db, sql: sql, arguments: finalArguments).compactMap { row in
                    guard let value: String = row["value"] else { return nil }
                    return (value, row["n"])
                }
            }
            var result: [SearchValueSuggestion] = []
            for (value, count) in rows {
                if kind == .album, !TrackMetadataPresentation.isRealAlbum(value) { continue }
                if kind == .artist, TrackMetadataPresentation.artistDisplay(value) == nil { continue }
                result.append(SearchValueSuggestion(token: SearchToken(kind: kind, value: .text(value, exact: true)), count: count))
                if result.count == limit { break }
            }
            return result
        case .availability:
            let counts = try await availabilityCounts()
            let folded = partial.trimmingCharacters(in: .whitespaces).lowercased()
            return SearchAvailabilityWord.allCases
                .filter { folded.isEmpty || $0.phrase.lowercased().hasPrefix(folded) || $0.phrase.lowercased().contains(folded) }
                .map { SearchValueSuggestion(token: .availability($0), count: counts[$0] ?? 0) }
        case .year, .bpm:
            return []
        }
    }

    /// Tracks per `is:` word, one pass.
    func availabilityCounts() async throws -> [SearchAvailabilityWord: Int] {
        var columns: [String] = []
        var arguments = StatementArguments()
        for word in SearchAvailabilityWord.allCases {
            let (sql, args) = TrackSearchSQL.predicate(for: SearchFilter(tokens: [.availability(word)]))
            columns.append("COALESCE(SUM(CASE WHEN \(sql) THEN 1 ELSE 0 END), 0)")
            arguments += args
        }
        let sql = "SELECT \(columns.joined(separator: ", ")) FROM tracks"
        let finalArguments = arguments
        return try await database.read { db in
            guard let row = try Row.fetchOne(db, sql: sql, arguments: finalArguments) else { return [:] }
            var counts: [SearchAvailabilityWord: Int] = [:]
            for (index, word) in SearchAvailabilityWord.allCases.enumerated() {
                counts[word] = row[index]
            }
            return counts
        }
    }

    // MARK: In library

    /// The library track each online result already is, by result id: the same provider
    /// identity in `track_sources` (any account), or the same link / synthetic path in
    /// `original_path` (the importers' conventions). Reads only.
    func libraryTrackIDs(for results: [RemoteSearchResult]) async throws -> [String: Int64] {
        guard !results.isEmpty else { return [:] }
        return try await database.read { db in
            var found: [String: Int64] = [:]
            for result in results {
                let source = result.source.storedName
                let external = result.externalId.trimmingCharacters(in: .whitespacesAndNewlines)
                if !external.isEmpty, let id = try Int64.fetchOne(db, sql: """
                    SELECT ts.track_id FROM track_sources ts JOIN sources s ON s.id = ts.source_id
                    WHERE s.name = ? AND ts.external_id = ? LIMIT 1
                    """, arguments: [source, external]) {
                    found[result.id] = id
                    continue
                }
                var paths = ["\(source)://\(external)"]
                if let url = result.sourceURL, !url.isEmpty { paths.append(url) }
                if result.source == .soundcloud, !external.isEmpty {
                    paths.append("https://api.soundcloud.com/tracks/\(external)")
                }
                let placeholders = paths.map { _ in "?" }.joined(separator: ", ")
                if let id = try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE original_path IN (\(placeholders)) LIMIT 1",
                                               arguments: StatementArguments(paths)) {
                    found[result.id] = id
                    continue
                }
                if result.source == .youtube, !external.isEmpty, let id = try Int64.fetchOne(db, sql: """
                    SELECT id FROM tracks
                    WHERE (original_path LIKE ? OR original_path LIKE ?) LIMIT 1
                    """, arguments: ["%youtube.com/watch?v=\(external)%", "%youtu.be/\(external)%"]) {
                    found[result.id] = id
                }
            }
            return found
        }
    }

    /// The library track a pasted link already is (same link in `original_path`, or a YouTube
    /// video with the same id).
    func trackID(forLink url: String) async throws -> Int64? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let videoID = URLDetector.extractYouTubeVideoID(trimmed)
        return try await database.read { db in
            if let id = try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE original_path = ? LIMIT 1", arguments: [trimmed]) {
                return id
            }
            if let videoID {
                return try Int64.fetchOne(db, sql: """
                    SELECT id FROM tracks WHERE original_path LIKE ? OR original_path LIKE ? LIMIT 1
                    """, arguments: ["%youtube.com/watch?v=\(videoID)%", "%youtu.be/\(videoID)%"])
            }
            return nil
        }
    }
}

extension RemoteSearchResult.Source {
    /// The `sources.name` / `format` word the importers store (`soundcloud`, `youtube`, …).
    var storedName: String {
        switch self {
        case .soundcloud: "soundcloud"
        case .spotify: "spotify"
        case .youtube: "youtube"
        case .dab: "dab"
        }
    }
}
