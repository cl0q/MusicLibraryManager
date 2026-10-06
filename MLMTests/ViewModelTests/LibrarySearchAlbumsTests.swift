import Foundation
import Testing
@testable import MLM

/// W5-1a G28: the Library scope has an Albums section (5 rows and `Show All`) between Tracks and
/// Playlists; its rows push the album's page (UC-SEARCH-02, IMP-091).
@Suite("LibrarySearchAlbumsTests")
@MainActor
struct LibrarySearchAlbumsTests {
    @Test func albumsMatchTheFreeWordsAndAlbumTokensOnly() async throws {
        let lib = try AlbumListingTests.Library()
        try await lib.album("Low Season", artist: "Overmono", year: 2022, count: 3)
        try await lib.album("Good Lies", artist: "Overmono", year: 2023, count: 2)
        try await lib.album("Warm Leatherette", artist: "Grace Jones", year: 1980, count: 2)
        let byWord = try await LibraryAlbumSearch.albums(matching: SearchFilter(text: "overmono"), in: lib.albums)
        #expect(byWord.map(\.album.title).sorted() == ["Good Lies", "Low Season"])
        let byToken = try await LibraryAlbumSearch.albums(
            matching: SearchFilter(text: "", tokens: [SearchToken(kind: .album, value: .text("warm", exact: false))]), in: lib.albums)
        #expect(byToken.map(\.album.title) == ["Warm Leatherette"])
        // Tokens an album has no meaning for, alone, find no albums.
        let trackOnly = try await LibraryAlbumSearch.albums(matching: SearchFilter(text: "", tokens: [.availability(.local)]), in: lib.albums)
        #expect(trackOnly.isEmpty)
    }

    @Test func theModelGroupsAlbumsWithATotalAndFiveRows() async throws {
        let model = LibrarySearchModel()
        let asked = SearchTestBox<[SearchFilter]>([])
        let lib = try AlbumListingTests.Library()
        for index in 1...7 { try await lib.album("Wave \(index)", artist: "Overmono", count: 2) }
        model.albumSearch = { filter in
            asked.value.append(filter)
            return try await LibraryAlbumSearch.albums(matching: filter, in: lib.albums)
        }
        model.search(SearchFilter(text: "wave"))
        await model.task?.value
        let results = try #require(model.results)
        #expect(results.albumTotal == 7)
        #expect(results.albums.count == LibrarySearchModel.sectionLimit)
        #expect(!results.isEmpty)
        #expect(asked.value.count == 1)
        // A filter no album can use never asks.
        model.search(SearchFilter(text: "", tokens: [.availability(.local)]))
        await model.task?.value
        #expect(asked.value.count == 1)
        #expect(model.results?.albumTotal == 0)
    }

    @Test func aResultsPageWithOnlyAlbumsIsNotEmpty() {
        var results = LibrarySearchResults()
        #expect(results.isEmpty)
        results.albumTotal = 1
        #expect(!results.isEmpty)
    }

    @Test func theViewPlacesAlbumsBetweenTracksAndPlaylistsAndPushesTheAlbum() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("MLM/Views/Search/SearchResultsView.swift"), encoding: .utf8)
        let albums = try #require(text.range(of: "listHeader(\"Albums\""))
        let playlists = try #require(text.range(of: "listHeader(\"Playlists\""))
        #expect(albums.lowerBound < playlists.lowerBound)
        #expect(text.contains("navigation.push(.album(id))"))
        #expect(text.contains("in: .albums)"))
    }
}
