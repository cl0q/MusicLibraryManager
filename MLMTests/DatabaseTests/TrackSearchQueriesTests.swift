import Foundation
import GRDB
import Testing
@testable import MLM

/// The search field in SQL (W2-I): tokens for All Tracks and the Library scope, value
/// suggestions, `In library` for online results — on temporary in-memory databases only.
@Suite("Track search queries")
struct TrackSearchQueriesTests {
    private struct Seed {
        var title: String
        var artist = "Overmono"
        var album = "Good Lies"
        var genre: String? = "Techno"
        var year: Int? = 2023
        var bpm: Int? = 130
        var path: String? = "A/x.m4a"
        var energy: Int? = 3
        var original: String?
    }

    private func makeDatabase(_ seeds: [Seed]) async throws -> (DatabaseQueue, TrackRepository, TrackSearchQueries, [Int64]) {
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)
        var ids: [Int64] = []
        for (index, seed) in seeds.enumerated() {
            var track = Track(artist: seed.artist, album: seed.album, title: seed.title, format: "m4a",
                              originalPath: seed.original ?? "/orig/\(index).m4a")
            track.genre = seed.genre
            track.year = seed.year
            track.bpm = seed.bpm
            track.organizedPath = seed.path
            track.energyBucket = seed.energy
            ids.append(try #require(try await repo.insert(track).id))
        }
        return (db, repo, TrackSearchQueries(database: db), ids)
    }

    private let library: [Seed] = [
        Seed(title: "So U Kno"),
        Seed(title: "Is U", genre: "Tech House", year: 2019, bpm: 124),
        Seed(title: "Cold Blooded", artist: "Skee Mask", album: "Compro", genre: "Techno", year: 2018, bpm: 126, path: nil),
        Seed(title: "Rip", artist: "Skee Mask", album: "YouTube", genre: "Ambient", year: nil, bpm: nil, path: nil, energy: nil,
             original: "https://soundcloud.com/skee/rip"),
    ]

    @Test func tokensFilterAllTracksInSQL() async throws {
        let (_, _, queries, _) = try await makeDatabase(library)
        func titles(_ filter: SearchFilter, _ scope: TrackAvailabilityScope = .all) async throws -> Set<String> {
            Set(try await queries.fetchTracks(scope: scope, filter: filter).map(\.title))
        }
        #expect(try await titles(SearchFilter(tokens: [.genre("Techno")])) == ["So U Kno", "Cold Blooded"])
        #expect(try await titles(SearchFilter(tokens: [.genre("Techno"), .genre("Ambient")])) == ["So U Kno", "Cold Blooded", "Rip"])
        #expect(try await titles(SearchFilter(text: "genre:tech")) == ["So U Kno", "Is U", "Cold Blooded"])
        #expect(try await titles(SearchFilter(text: "bpm: 120–126")) == ["Is U", "Cold Blooded"])
        #expect(try await titles(SearchFilter(text: "year:2018-2019 artist:skee")) == ["Cold Blooded"])
        #expect(try await titles(SearchFilter(tokens: [.availability(.notDownloaded)])) == ["Cold Blooded", "Rip"])
        #expect(try await titles(SearchFilter(tokens: [.availability(.noAlbum)])) == ["Rip"])
        #expect(try await titles(SearchFilter(tokens: [.availability(.notAnalysed)])) == ["Rip"])
        #expect(try await titles(SearchFilter(tokens: [.availability(.linkedToSoundCloud)])) == ["Rip"])
        #expect(try await titles(SearchFilter(text: "kno")) == ["So U Kno"])
        #expect(try await titles(SearchFilter(tokens: [.genre("Techno")]), .local) == ["So U Kno"])
    }

    @Test func inNoPlaylistFollowsPlaylistMembership() async throws {
        let (db, _, queries, ids) = try await makeDatabase(library)
        let playlists = PlaylistRepository(database: db)
        let playlist = try await playlists.create(name: "Warm-up")
        try await playlists.appendTracks(playlistId: try #require(playlist.id), trackIds: [ids[0]])
        let rows = try await queries.fetchTracks(scope: .all, filter: SearchFilter(tokens: [.availability(.inNoPlaylist)]))
        #expect(Set(rows.compactMap(\.id)) == Set(ids.dropFirst()))
    }

    @Test func scopeCountsFollowTheTokens() async throws {
        let (_, _, queries, _) = try await makeDatabase(library)
        let summary = try await queries.scopeSummary(filter: SearchFilter(tokens: [.artist("Skee Mask")]))
        #expect(summary.counts.all == 2)
        #expect(summary.counts.notDownloaded == 2)
        #expect(summary.libraryCount == 4)
    }

    @Test func libraryScopeShowsLocalFirstAndCountsAll() async throws {
        let (_, _, queries, _) = try await makeDatabase(library)
        let found = try await queries.matchingTracks(filter: SearchFilter(text: "u"), limit: 1)
        #expect(found.total == 3)
        #expect(found.tracks.count == 1)
        #expect(found.tracks.first?.isLocal == true)
        let none = try await queries.matchingTracks(filter: .empty, limit: 5)
        #expect(none.total == 0 && none.tracks.isEmpty)
    }

    @Test func valueSuggestionsComeFromTheLibraryCapped() async throws {
        let (_, _, queries, _) = try await makeDatabase(library)
        let genres = try await queries.valueSuggestions(kind: .genre, partial: "te")
        #expect(genres.map(\.token.valueText) == ["Techno", "Tech House"])
        #expect(genres.first?.count == 2)
        #expect(genres.allSatisfy { if case .text(_, true) = $0.token.value { true } else { false } }, "Chosen values are exact")
        let albums = try await queries.valueSuggestions(kind: .album, partial: "")
        #expect(!albums.contains { $0.token.valueText == "YouTube" }, "A source name is no album")
        let capped = try await queries.valueSuggestions(kind: .genre, partial: "", limit: 1)
        #expect(capped.count == 1)
        let words = try await queries.valueSuggestions(kind: .availability, partial: "not")
        #expect(words.map(\.token) == [.availability(.notDownloaded), .availability(.notAnalysed)])
        #expect(words.first?.count == 2)
        #expect(try await queries.valueSuggestions(kind: .bpm, partial: "12").isEmpty)
    }

    @Test func onlineResultsKnowWhatTheLibraryHas() async throws {
        let (db, _, queries, ids) = try await makeDatabase(library + [
            Seed(title: "Video", original: "https://www.youtube.com/watch?v=abc123&list=x"),
        ])
        let sources = SourceRepository(database: db)
        let source = try await sources.upsert(name: "spotify", userId: "me")
        try await sources.linkTrackToSource(trackId: ids[1], sourceId: try #require(source.id), externalId: "sp1")
        let results = [
            RemoteSearchResult(id: "sc-1", source: .soundcloud, artist: "", title: "", durationSeconds: nil, externalId: "1",
                               sourceURL: "https://soundcloud.com/skee/rip"),
            RemoteSearchResult(id: "sp-1", source: .spotify, artist: "", title: "", durationSeconds: nil, externalId: "sp1", sourceURL: nil),
            RemoteSearchResult(id: "yt-abc123", source: .youtube, artist: "", title: "", durationSeconds: nil, externalId: "abc123",
                               sourceURL: "https://www.youtube.com/watch?v=abc123"),
            RemoteSearchResult(id: "dab-9", source: .dab, artist: "", title: "", durationSeconds: nil, externalId: "9", sourceURL: nil),
        ]
        let found = try await queries.libraryTrackIDs(for: results)
        #expect(found == ["sc-1": ids[3], "sp-1": ids[1], "yt-abc123": ids[4]])
        #expect(try await queries.trackID(forLink: "https://youtu.be/abc123") == ids[4])
        #expect(try await queries.trackID(forLink: "https://soundcloud.com/other") == nil)
    }
}
