import Foundation
import GRDB
import SwiftUI
import Testing
@testable import MLM

/// The grid's and the page's models (W4-2): scope counts that follow the filter, sort,
/// first-load phases, the edition the page shows, the layout from a database, Edit Order's working
/// copy and the in-place filter.
@MainActor
@Suite("AlbumModelsTests")
struct AlbumModelsTests {
    typealias Library = AlbumListingTests.Library

    // MARK: The grid

    private func gridModel(_ lib: Library, sort: AlbumSort = .artist) -> AlbumsModel {
        AlbumsModel(albums: lib.albums, scopeQueries: TrackScopeQueries(database: lib.db), sort: sort)
    }

    @Test func theFirstLoadIsLoadingThenLoadedInPlace() async throws {
        let lib = try Library()
        try await lib.album("Low Season", count: 3)
        let model = gridModel(lib)
        #expect(model.phase == .loading)
        await model.reload()
        #expect(model.phase == .loaded)
        #expect(model.all.map(\.album.title) == ["Low Season"])
        try await lib.album("Good Lies", year: 2023, count: 2)
        await model.reload()
        #expect(model.all.count == 2, "a later reload replaces the data without going back to loading")
        #expect(model.phase == .loaded)
    }

    @Test func aModelWithoutADatabaseFailsOnFirstLoadOnly() async {
        let model = AlbumsModel(albums: nil, scopeQueries: nil)
        await model.reload()
        #expect(model.phase == .failed)
    }

    @Test func scopeCountsFollowTheFilterAndTheScopeNarrowsTheGrid() async throws {
        let lib = try Library()
        try await lib.album("Complete One", count: 3, numbers: [(1, 1), (1, 2), (1, 3)])
        try await lib.album("Complete Two", count: 2)
        try await lib.album("Half There", count: 2, numbers: [(1, 1), (1, 4)])
        try await lib.album("Mix Tape", artist: "Various Artists", count: 3, trackArtists: ["A", "B", "C"])
        let model = gridModel(lib)
        await model.reload()
        let all = model.counts(filter: .empty)
        #expect(all[.all] == 4)
        #expect(all[.complete] == 3)
        #expect(all[.incomplete] == 1)
        #expect(all[.compilations] == 1)
        let filter = SearchFilter(text: "complete")
        let filtered = model.counts(filter: filter)
        #expect(filtered[.all] == 2 && filtered[.complete] == 2 && filtered[.incomplete] == 0, "the counts follow the search")
        #expect(model.shown(scope: .incomplete, filter: .empty).map(\.album.title) == ["Half There"])
        #expect(model.shown(scope: .compilations, filter: .empty).map(\.album.title) == ["Mix Tape"])
        #expect(model.shown(scope: .all, filter: SearchFilter(tokens: [.artist("various artists")])).map(\.album.title) == ["Mix Tape"])
    }

    @Test func sortingReordersInMemoryByArtistTitleYearAndRecentlyAdded() async throws {
        let lib = try Library()
        try await lib.album("B Side", artist: "Zed", year: 2010, count: 2, added: "2026-03-01 10:00:00")
        try await lib.album("A Side", artist: "Zed", year: 2020, count: 2, added: "2026-01-01 10:00:00")
        try await lib.album("Cee", artist: "Abe", year: nil, count: 2, added: "2026-02-01 10:00:00")
        let model = gridModel(lib)
        await model.reload()
        #expect(model.all.map(\.album.title) == ["Cee", "B Side", "A Side"], "Artist, then year (oldest first)")
        model.setSort(.title)
        #expect(model.all.map(\.album.title) == ["A Side", "B Side", "Cee"])
        model.setSort(.year)
        #expect(model.all.map(\.album.title) == ["A Side", "B Side", "Cee"], "newest first, no year last")
        model.setSort(.recentlyAdded)
        #expect(model.all.map(\.album.title) == ["B Side", "Cee", "A Side"])
    }

    @Test func theFooterCountAndWhatMenusNeedComeWithTheLoad() async throws {
        let lib = try Library()
        let (id, tracks) = try await lib.album("Low Season", count: 3)
        try await lib.db.write { db in
            try db.execute(sql: "UPDATE tracks SET organized_path = NULL, download_status = NULL WHERE id = ?", arguments: [tracks[0]])
            try db.execute(sql: "UPDATE tracks SET organized_path = 'a/b.flac' WHERE id IN (?, ?)", arguments: [tracks[1], tracks[2]])
            for index in 0..<4 {
                _ = try AlbumTracksMigrationTests.insertTrack(db, title: "Loose \(index)", album: "unknown album")
            }
        }
        let model = gridModel(lib)
        await model.reload()
        #expect(model.noAlbumCount == 4)
        #expect(model.missingCount([id]) == 1)
        #expect(model.firstTracks[id] == tracks[0])
        #expect(model.cover(for: model.all[0]).firstTrackID == tracks[0])
    }

    @Test func aPreloadedModelShowsItsListingsAtOnce() {
        let listings = [AlbumPresentationTests.listing(AlbumPresentationTests.album(1, title: "B"), tracks: 3),
                        AlbumPresentationTests.listing(AlbumPresentationTests.album(2, title: "A", artist: "Abe"), tracks: 2)]
        let model = AlbumsModel(preloaded: listings, noAlbumCount: 9)
        #expect(model.phase == .loaded)
        #expect(model.all.map(\.album.title) == ["A", "B"])
        #expect(model.noAlbumCount == 9)
    }

    // MARK: The page

    private func detailModel(_ lib: Library, _ id: Int64) -> AlbumDetailModel {
        AlbumDetailModel(albumID: id, albums: lib.albums)
    }

    @Test func aMissingAlbumIsNotFound() async throws {
        let lib = try Library()
        let model = detailModel(lib, 999)
        await model.load()
        #expect(model.phase == .missing)
    }

    @Test func thePageShowsGapsFactsAndTheStatusLineOfAKnownTracklist() async throws {
        let lib = try Library()
        let (id, tracks) = try await lib.album("Low Season", year: 2019, count: 3, genre: "Techno", duration: 300,
                                               numbers: [(1, 1), (1, 2), (1, 5)])
        try await lib.db.write { db in
            try db.execute(sql: "UPDATE tracks SET organized_path = 'a/1.flac' WHERE id IN (?, ?)", arguments: [tracks[0], tracks[1]])
            try db.execute(sql: "UPDATE tracks SET organized_path = NULL, download_status = 'failed' WHERE id = ?", arguments: [tracks[2]])
        }
        let model = detailModel(lib, id)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.list.rows.map(\.synthetic) == [.none, .none, .absent, .absent, .none])
        #expect(model.list.rows.map(\.displayNumber) == [1, 2, 3, 4, 5])
        #expect(model.factsLine == "2019 · Techno · 5 tracks · 15 min", "the tracklist counts, the library's duration")
        #expect(model.statusLine?.text == "Incomplete · 2 of 5 not in library · 1 download failed")
        #expect(model.statusLine?.downloadCount == 1)
        #expect(model.downloadableTracks.map(\.id) == [tracks[2]])
        #expect(AlbumNames.shared.name(for: id) == "Low Season")
    }

    @Test func anAlbumWithoutNumbersHasNoGapsAndCountsItsOwnTracks() async throws {
        let lib = try Library()
        let (id, _) = try await lib.album("Low Season", year: 2019, count: 3)
        let model = detailModel(lib, id)
        await model.load()
        let onlyTracks = model.list.rows.allSatisfy { $0.isTrack }
        #expect(onlyTracks)
        #expect(model.factsLine.contains("3 tracks"))
        #expect(model.layout?.absent == 0)
        #expect(!model.isCompilation)
    }

    @Test func aCompilationIsRecognisedByItsArtists() async throws {
        let lib = try Library()
        let (id, _) = try await lib.album("fabric", artist: "Various Artists", count: 3, trackArtists: ["A", "B", "C"])
        let model = detailModel(lib, id)
        await model.load()
        #expect(model.isCompilation)
    }

    @Test func twoDiscsShowHeadingsWithTheirOwnCounts() async throws {
        let lib = try Library()
        let (id, _) = try await lib.album("Double", count: 4, duration: 600, numbers: [(1, 1), (1, 2), (2, 1), (2, 2)])
        let model = detailModel(lib, id)
        await model.load()
        #expect(model.list.rows.map(\.synthetic) == [.discHeader, .none, .none, .discHeader, .none, .none])
        #expect(model.list.rows[0].title == "Disc 1 · 2 tracks · 20 min")
        #expect(model.list.rows.compactMap { $0.isTrack ? $0.displayNumber : nil } == [1, 2, 1, 2])
    }

    @Test func theFilterKeepsOnlyMatchingTracksAndNoGaps() async throws {
        let lib = try Library()
        let (id, _) = try await lib.album("Low Season", count: 3, numbers: [(1, 1), (1, 2), (1, 5)])
        let model = detailModel(lib, id)
        await model.load()
        #expect(model.list.rows.count == 5)
        await model.setFilter(SearchFilter(text: "Low Season 1"))
        #expect(model.list.rows.count == 1 && model.list.rows[0].isTrack)
        await model.setFilter(.empty)
        #expect(model.list.rows.count == 5)
    }

    @Test func editionsAreListedWithWhatTheLibraryHoldsAndThePreferredOneOpens() async throws {
        let lib = try Library()
        let (base, _) = try await lib.album("Low Season", year: 2019, count: 3, numbers: [(1, 1), (1, 2), (1, 4)])
        let (deluxe, _) = try await lib.album("Low Season (Deluxe)", year: 2020, count: 2)
        try await lib.db.write { db in
            try db.execute(sql: "UPDATE albums SET variant_of = ?, variant_kind = 'deluxe' WHERE id = ?", arguments: [base, deluxe])
        }
        let model = detailModel(lib, base)
        await model.load()
        #expect(model.album?.id == base, "no preference: the one opened")
        #expect(model.editions.map(\.line) == ["Standard edition (2019) — 3 of 4 in library", "Deluxe edition (2020) — 2 of 2 in library"])
        #expect(model.editions.map(\.isPreferred) == [true, false])
        try await lib.albums.setVariantPref(baseAlbumId: base, selectedAlbumId: deluxe)
        let again = detailModel(lib, base)
        await again.load()
        #expect(again.album?.id == deluxe, "the preferred edition opens")
        #expect(again.editions.map(\.isPreferred) == [false, true])
        // Picking one on the page shows it, whatever is preferred.
        await again.show(edition: base)
        #expect(again.album?.id == base)
        #expect(again.members.count == 3)
        // Opening the edition's own route shows it.
        let direct = detailModel(lib, deluxe)
        await direct.load()
        #expect(direct.album?.id == deluxe)
    }

    @Test func aSingleAlbumHasNoEditionPicker() async throws {
        let lib = try Library()
        let (id, _) = try await lib.album("Low Season", count: 2)
        let model = detailModel(lib, id)
        await model.load()
        #expect(model.editions.isEmpty)
    }

    @Test func editOrderDragsRowsAndDoneHandsOverTheNumbers() async throws {
        let lib = try Library()
        let (id, tracks) = try await lib.album("Low Season", count: 3, numbers: [(1, 1), (1, 2), (1, 5)])
        let model = detailModel(lib, id)
        await model.load()
        await model.beginEditingOrder()
        #expect(model.isEditingOrder)
        let onlyTracks = model.list.rows.allSatisfy { $0.isTrack }
        #expect(onlyTracks, "no gap rows while editing")
        #expect(model.statusLine == nil, "the bar replaces the status line")
        await model.dropTracks([tracks[2]], atRow: 0)
        #expect(model.list.rows.map(\.id) == [tracks[2], tracks[0], tracks[1]])
        #expect(model.list.rows.map(\.displayNumber) == [1, 2, 3], "numbers follow the new order")
        let numbered = try #require(model.finishEditingOrder())
        #expect(numbered.map(\.trackID) == [tracks[2], tracks[0], tracks[1]])
        #expect(numbered.map(\.number) == [1, 2, 3])
        #expect(!model.isEditingOrder)
    }

    @Test func cancelRestoresTheOrderShownAndNudgeUsesTheSelection() async throws {
        let lib = try Library()
        let (id, tracks) = try await lib.album("Low Season", count: 3)
        let model = detailModel(lib, id)
        await model.load()
        await model.beginEditingOrder()
        model.list.selection = [tracks[1]]
        await model.nudgeSelection(by: -1)
        #expect(model.list.rows.map(\.id) == [tracks[1], tracks[0], tracks[2]])
        await model.cancelEditingOrder()
        #expect(model.list.rows.map(\.id) == tracks)
        #expect(!model.isEditingOrder)
        await model.nudgeSelection(by: 1)
        #expect(model.list.rows.map(\.id) == tracks, "nothing moves outside Edit Order")
    }

    @Test func aPreloadedPageNeedsNoDatabase() async {
        let members = [AlbumPresentationTests.member(1, number: 1), AlbumPresentationTests.member(2, number: 3)]
        let model = AlbumDetailModel.preloaded(album: AlbumPresentationTests.album(), members: members)
        #expect(model.phase == .loaded)
        #expect(model.list.rows.map(\.synthetic) == [.none, .absent, .none])
        #expect(model.statusLine?.text == "Incomplete · 1 of 3 not in library")
        await model.load()
        #expect(model.phase == .loaded, "a preloaded page doesn't read")
    }

    @Test func theAlbumTableIsFixedInOrderAndNeverSortable() {
        let configuration = TrackListConfiguration.album(
            id: 4, name: "Low Season", isCompilation: false, activate: nil, remove: { _ in }, onInsert: nil)
        #expect(!configuration.isSortable)
        #expect(configuration.hasContainerOrder)
        #expect(configuration.columns == [.number, .title, .time, .status])
        #expect(!configuration.showsRowCover && configuration.playingGlyphInNumber)
        #expect(configuration.listContext.container == .album(id: 4, name: "Low Season"))
        #expect(configuration.listContext.viewName == "“Low Season”")
        let compilation = TrackListConfiguration.album(
            id: 4, name: "fabric", isCompilation: true, activate: nil, remove: { _ in }, onInsert: nil)
        #expect(compilation.columns == [.number, .title, .artist, .time, .status], "Artist only for a compilation")
    }
}
