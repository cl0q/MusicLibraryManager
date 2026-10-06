import Foundation
import GRDB

// The Albums grid's queries (W4-1, IMP-069). Counts, durations and track lists read listed
// tracks only (`TrackVisibility.listedSQL`, IMP-049/053).

extension AlbumRepository {
    /// Albums the grid lists, in `sort` order, narrowed by `scope` and the search field's
    /// in-place `filter` (title, album artist and year; text only). Only base albums (not
    /// editions of another) with at least two listed tracks, or a known tracklist, are listed;
    /// one-track albums exist and open from `Go to Album`. Albums whose title is no album (a
    /// source name, `unknown album`) are never listed (DEC-021).
    func fetchListed(scope: AlbumScope = .all, sort: AlbumSort = .artist, filter: SearchFilter = .empty) async throws -> [AlbumListing] {
        let listings = try await database.read { db in try Self.listings(db) }
        return Self.sorted(listings.filter { scope.contains($0) && Self.matches($0, filter) }, by: sort)
    }

    /// The count of every scope for the same `filter` (the scope bar's live counts).
    func scopeCounts(filter: SearchFilter = .empty) async throws -> [AlbumScope: Int] {
        let listings = try await database.read { db in try Self.listings(db) }
        let shown = listings.filter { Self.matches($0, filter) }
        return Dictionary(uniqueKeysWithValues: AlbumScope.allCases.map { scope in
            (scope, shown.filter { scope.contains($0) }.count)
        })
    }

    /// The facts line of an album (`2019 · Techno · 12 tracks · 58 min`): its year (else the most
    /// common year of its tracks), the majority genre, and the count and total duration of its
    /// listed tracks. Nil when the album doesn't exist.
    func summary(id: Int64) async throws -> AlbumSummary? {
        try await database.read { db in
            guard let album = try Album.fetchOne(db, id: id) else { return nil }
            let rows = try Row.fetchAll(db, sql: """
                SELECT tracks.genre AS genre, tracks.year AS year, COALESCE(tracks.duration, 0) AS duration
                FROM album_tracks JOIN tracks ON tracks.id = album_tracks.track_id
                WHERE album_tracks.album_id = ? AND \(TrackVisibility.listedSQL)
                """, arguments: [id])
            let genres = rows.compactMap { (row: Row) -> String? in
                let genre: String? = row["genre"]
                let trimmed = genre?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            let years = rows.compactMap { (row: Row) -> Int? in row["year"] }.filter { $0 > 0 }
            let duration = rows.reduce(0) { total, row in total + (row["duration"] as Int) }
            return AlbumSummary(year: album.year ?? Self.majority(years), genre: Self.majority(genres),
                                trackCount: rows.count, duration: duration)
        }
    }

    // MARK: Internals

    /// The most common value; ties go to the smaller one.
    static func majority<T: Hashable & Comparable>(_ values: [T]) -> T? {
        var counts: [T: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
    }

    static func listings(_ db: Database) throws -> [AlbumListing] {
        let albums = try Row.fetchAll(db, sql: """
            SELECT albums.*, COUNT(tracks.id) AS track_count, MAX(tracks.date_added) AS last_added,
                   COUNT(DISTINCT LOWER(tracks.artist)) AS artist_count
            FROM albums
            JOIN album_tracks ON album_tracks.album_id = albums.id
            JOIN tracks ON tracks.id = album_tracks.track_id AND \(TrackVisibility.listedSQL)
            WHERE albums.variant_of IS NULL
            GROUP BY albums.id
            """)
        var numbers: [Int64: [(disc: Int, number: Int?)]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT album_tracks.album_id, album_tracks.disc, album_tracks.track_number
            FROM album_tracks JOIN tracks ON tracks.id = album_tracks.track_id AND \(TrackVisibility.listedSQL)
            """) {
            numbers[row["album_id"], default: []].append((row["disc"], row["track_number"]))
        }
        return try albums.compactMap { row -> AlbumListing? in
            let album = try Album(row: row)
            guard let id = album.id, TrackMetadataPresentation.isRealAlbum(album.title) else { return nil }
            let listing = AlbumListing(
                album: album, trackCount: row["track_count"], artistCount: row["artist_count"],
                lastAdded: row["last_added"], tracklist: AlbumTracklist(numbers[id] ?? []))
            return listing.isListed ? listing : nil
        }
    }

    static func matches(_ listing: AlbumListing, _ filter: SearchFilter) -> Bool {
        let album = listing.album
        return filter.matchesName("\(album.title) \(album.albumArtist) \(album.year.map(String.init) ?? "")")
    }

    static func sorted(_ listings: [AlbumListing], by sort: AlbumSort) -> [AlbumListing] {
        func compare(_ a: String, _ b: String) -> ComparisonResult { a.localizedStandardCompare(b) }
        /// Newest (largest) first.
        func descending<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a == b ? .orderedSame : (a > b ? .orderedAscending : .orderedDescending)
        }
        func before(_ l: AlbumListing, _ r: AlbumListing, _ keys: [ComparisonResult]) -> Bool {
            for key in keys where key != .orderedSame { return key == .orderedAscending }
            return (l.album.id ?? 0) < (r.album.id ?? 0)
        }
        return listings.sorted { l, r in
            switch sort {
            case .artist:
                let years = descending(r.album.year ?? 0, l.album.year ?? 0)   // oldest first within an artist
                return before(l, r, [compare(l.album.albumArtist, r.album.albumArtist), years, compare(l.album.title, r.album.title)])
            case .title:
                return before(l, r, [compare(l.album.title, r.album.title), compare(l.album.albumArtist, r.album.albumArtist)])
            case .year:
                return before(l, r, [descending(l.album.year ?? 0, r.album.year ?? 0), compare(l.album.title, r.album.title)])
            case .recentlyAdded:
                return before(l, r, [descending(l.lastAdded ?? "", r.lastAdded ?? ""), compare(l.album.title, r.album.title)])
            }
        }
    }
}

// MARK: - Grid types

/// The scope bar of the Albums grid (UC-SCOPE-02): `All · Complete · Incomplete · Compilations`.
enum AlbumScope: String, CaseIterable, Sendable {
    case all, complete, incomplete, compilations

    var title: String {
        switch self {
        case .all: "All"
        case .complete: "Complete"
        case .incomplete: "Incomplete"
        case .compilations: "Compilations"
        }
    }

    func contains(_ listing: AlbumListing) -> Bool {
        switch self {
        case .all: true
        case .complete: listing.isComplete
        case .incomplete: listing.isIncomplete
        case .compilations: listing.isCompilation
        }
    }
}

/// The Sort By menu of the Albums grid. `year` and `recentlyAdded` are newest first.
enum AlbumSort: String, CaseIterable, Sendable {
    case artist, title, year, recentlyAdded

    var title: String {
        switch self {
        case .artist: "Artist"
        case .title: "Title"
        case .year: "Year"
        case .recentlyAdded: "Recently Added"
        }
    }
}

/// What the files' track numbers say about an album's tracklist. "Known" = every listed track
/// has a number; then the tracklist is, per disc, 1 … the highest number there.
struct AlbumTracklist: Equatable, Sendable {
    /// Every listed member has a track number.
    let isKnown: Bool
    /// Tracks the tracklist has (sum over discs of the highest number); nil when not known.
    let expectedCount: Int?
    /// Positions of the tracklist that a listed track fills.
    let presentCount: Int

    init(_ members: [(disc: Int, number: Int?)]) {
        guard !members.isEmpty, members.allSatisfy({ ($0.number ?? 0) > 0 }) else {
            isKnown = false
            expectedCount = nil
            presentCount = 0
            return
        }
        var perDisc: [Int: Set<Int>] = [:]
        for member in members { perDisc[member.disc, default: []].insert(member.number ?? 0) }
        isKnown = true
        expectedCount = perDisc.values.reduce(0) { $0 + ($1.max() ?? 0) }
        presentCount = perDisc.values.reduce(0) { $0 + $1.count }
    }

    /// Known, and every position from 1 to the highest number is filled on every disc.
    var isFilled: Bool { isKnown && presentCount == expectedCount }
}

/// An album as the grid lists it.
struct AlbumListing: Identifiable, Equatable, Sendable {
    let album: Album
    /// Listed tracks of the album.
    let trackCount: Int
    /// Distinct track artists.
    let artistCount: Int
    /// The newest `date_added` among its tracks.
    let lastAdded: String?
    let tracklist: AlbumTracklist

    var id: Int64 { album.id ?? 0 }

    /// IMP-069: two or more tracks, or a known tracklist.
    var isListed: Bool { trackCount >= 2 || tracklist.isKnown }

    /// No known tracklist and at least two tracks, or a known tracklist with every position filled.
    var isComplete: Bool { tracklist.isKnown ? tracklist.isFilled : trackCount >= 2 }

    /// A known tracklist with a missing position (`Incomplete · 9 of 12`).
    var isIncomplete: Bool { tracklist.isKnown && !tracklist.isFilled }

    /// `Various Artists` (any case) or three or more different track artists.
    var isCompilation: Bool {
        album.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Various Artists") == .orderedSame
            || artistCount >= 3
    }
}

/// The facts line of an album.
struct AlbumSummary: Equatable, Sendable {
    let year: Int?
    let genre: String?
    let trackCount: Int
    /// Seconds, listed tracks.
    let duration: Int
}
