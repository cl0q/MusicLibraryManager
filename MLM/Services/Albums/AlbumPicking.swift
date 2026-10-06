import Foundation
import GRDB

// The shared album picker's data (W4-2b, IMP-094): the albums a person can choose from, ranked
// for what they are choosing for. Used by Merge with Another Album and by Review ▸ Albums'
// `Choose Another Album…`. Pure ranking, one read query — unit-tested (`AlbumPickingTests`).

/// An album in the picker: the row and how many listed tracks it has.
struct AlbumCandidate: Identifiable, Equatable, Sendable {
    let album: Album
    let trackCount: Int

    var id: Int64 { album.id ?? 0 }

    /// `Low Season (Deluxe) · Overmono · 2020 · 4 tracks` — the title is the row's own line, so
    /// this is the second line: `Overmono · 2020 · 4 tracks` (`no year` when the album has none).
    var detailLine: String {
        let year = album.year.flatMap { $0 > 0 ? String($0) : nil } ?? "no year"
        return [album.albumArtist, year, StatusBarText.tracks(trackCount)].joined(separator: " · ")
    }
}

/// What the picker ranks against: the album being merged (its title and album artist), or the
/// track's suggestion (its title, possibly empty, and the track's artist).
struct AlbumPickReference: Equatable, Sendable {
    var title: String
    var albumArtist: String
}

enum AlbumPickRanking {
    /// How well a candidate fits the reference; lower is better.
    enum Tier: Int, Comparable, Sendable {
        /// The same `AlbumKey` (album artist and normalised title).
        case sameKey
        /// One title contains the other.
        case titleContains
        /// The same album artist.
        case sameArtist
        case other

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static func tier(of candidate: Album, for reference: AlbumPickReference) -> Tier {
        let sameArtist = AlbumKey.artistKey(candidate.albumArtist) == AlbumKey.artistKey(reference.albumArtist)
        let wanted = AlbumKey.normalize(reference.title)
        let have = AlbumKey.normalize(candidate.title)
        if sameArtist, !wanted.isEmpty, have == wanted { return .sameKey }
        if !wanted.isEmpty, !have.isEmpty, have.contains(wanted) || wanted.contains(have) { return .titleContains }
        if sameArtist { return .sameArtist }
        return .other
    }

    /// The candidates the search text leaves (title or album artist contains every word, case
    /// and diacritics ignored), best fit first; within a fit, by title.
    static func rank(_ candidates: [AlbumCandidate], for reference: AlbumPickReference, query: String, limit: Int = 200) -> [AlbumCandidate] {
        let words = SearchFilter.fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let shown = candidates.filter { candidate in
            guard !words.isEmpty else { return true }
            let text = SearchFilter.fold("\(candidate.album.title) \(candidate.album.albumArtist)")
            return words.allSatisfy(text.contains)
        }
        let ranked = shown.map { (candidate: $0, tier: tier(of: $0.album, for: reference)) }.sorted { l, r in
            if l.tier != r.tier { return l.tier < r.tier }
            let order = l.candidate.album.title.localizedStandardCompare(r.candidate.album.title)
            if order != .orderedSame { return order == .orderedAscending }
            return l.candidate.id < r.candidate.id
        }
        return Array(ranked.prefix(limit).map(\.candidate))
    }
}

extension AlbumRepository {
    /// The albums that can be picked: base albums (not editions of another) with at least one
    /// listed track, whose title is a real album. `excluding` leaves out the group of an album
    /// (itself, its editions and — for an edition — its base and siblings).
    func pickCandidates(excludingGroupOf albumID: Int64? = nil) async throws -> [AlbumCandidate] {
        try await database.read { db in
            var excluded = Set<Int64>()
            if let albumID, let album = try Album.fetchOne(db, key: albumID) {
                let base = album.variantOf ?? albumID
                excluded.insert(base)
                excluded.formUnion(try Int64.fetchAll(db, sql: "SELECT id FROM albums WHERE variant_of = ?", arguments: [base]))
                excluded.insert(albumID)
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT albums.*, COUNT(tracks.id) AS track_count
                FROM albums
                JOIN album_tracks ON album_tracks.album_id = albums.id
                JOIN tracks ON tracks.id = album_tracks.track_id AND \(TrackVisibility.listedSQL)
                WHERE albums.variant_of IS NULL
                GROUP BY albums.id
                """)
            return try rows.compactMap { row -> AlbumCandidate? in
                let album = try Album(row: row)
                guard let id = album.id, !excluded.contains(id), TrackMetadataPresentation.isRealAlbum(album.title) else { return nil }
                return AlbumCandidate(album: album, trackCount: row["track_count"])
            }
        }
    }
}

// MARK: - Review ▸ Albums: choosing an album for a row

extension AlbumSuggestionDecisions {
    /// The suggestion a chosen album makes: title, album artist and year from the album row, source
    /// `Chosen by you`, match 100.
    static func suggestion(choosing album: Album) -> AlbumSuggestion {
        AlbumSuggestion(albumTitle: album.title, albumArtist: album.albumArtist, year: album.year, trackNumber: nil, disc: nil,
                        source: chosenSource, match: 100)
    }

    static let chosenSource = "Chosen by you"

    /// The row with `album` as its suggestion: pending again (also from `No Match`); the
    /// suggestion it replaces joins the alternatives. Nothing is written to the track until Accept.
    static func row(_ row: AlbumSuggestionRow, choosing album: Album) -> AlbumSuggestionRow {
        var next = row
        if row.hasSuggestion, row.status == .pending { next.alternatives.append(row.suggestion) }
        next.suggestion = suggestion(choosing: album)
        // The chosen album is the suggestion now, not also an alternative.
        next.alternatives.removeAll {
            AlbumKey.normalize($0.albumTitle) == AlbumKey.normalize(album.title)
                && AlbumKey.artistKey($0.albumArtist) == AlbumKey.artistKey(album.albumArtist)
        }
        next.status = .pending
        next.decidedAt = nil
        return next
    }

    /// `Choose Another Album…` → the picked album replaces the row's suggestion (V-REV.N11).
    @discardableResult
    func choose(album: Album, for item: AlbumSuggestionItem) async -> Bool {
        guard item.row.status == .pending || item.row.status == .noMatch else { return false }
        do {
            try await dependencies.repository.upsert([Self.row(item.row, choosing: album)])
            dependencies.didChange()
            return true
        } catch {
            return false
        }
    }
}
