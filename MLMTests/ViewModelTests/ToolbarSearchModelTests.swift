import Foundation
import Testing
@testable import MLM

/// The window's search field (W2-I, UC-SEARCH-01…07): one behaviour — filter the current view
/// in place; scopes only on request; the query belongs to the view. Debounce on an injected
/// sleeper (never load-sensitive).
@Suite("Toolbar search model")
@MainActor
struct ToolbarSearchModelTests {
    private let sleeper = ManualSleeper()

    /// A place the test moves between.
    private final class PlaceBox {
        var place = SearchPlace.allTracks
    }

    private struct FakeSuggestions: SearchSuggestionProviding {
        var values: [SearchValueSuggestion] = []
        func values(kind: SearchTokenKind, partial: String) async -> [SearchValueSuggestion] { values }
        func lookUp(_ link: LinkSuggestion) async -> LinkLookup { LinkLookup() }
    }

    private func makeModel(_ coordinator: SearchCoordinator, places: PlaceBox = PlaceBox()) -> ToolbarSearchModel {
        let sleeper = self.sleeper
        let model = ToolbarSearchModel(coordinator: coordinator, sleep: { await sleeper.sleep($0) })
        model.placeProvider = { places.place }
        model.placeDidChange()
        return model
    }

    private func flush(_ model: ToolbarSearchModel, pending: Int = 1) async {
        await sleeper.waitForPending(pending)
        let task = model.debounceTask
        await sleeper.releaseAll()
        await task?.value
    }

    @Test func typingFiltersThisViewInPlaceAfterTheDebounce() async {
        let coordinator = SearchCoordinator()
        let model = makeModel(coordinator)
        model.text = "techno"
        #expect(coordinator.filter(for: .allTracks).isEmpty, "Nothing is committed before the debounce")
        await sleeper.waitForPending(1)
        #expect(await sleeper.durations == [ToolbarSearchModel.debounce])
        await flush(model)
        #expect(coordinator.filter(for: .allTracks).text == "techno")
        #expect(coordinator.scope == .thisView)
        #expect(!coordinator.isPresented, "Typing never opens another surface")
    }

    @Test func aNewKeystrokeReplacesThePendingCommit() async {
        let coordinator = SearchCoordinator()
        let model = makeModel(coordinator)
        model.text = "gl"
        await sleeper.waitForPending(1)
        let first = model.debounceTask
        model.text = "glass"
        await sleeper.waitForPending(2)
        let second = model.debounceTask
        await sleeper.releaseAll()
        await first?.value
        await second?.value
        #expect(coordinator.filter(for: .allTracks).text == "glass")
    }

    @Test func returnCommitsAtOnceAndMovesFocusToTheRows() async {
        let coordinator = SearchCoordinator()
        let model = makeModel(coordinator)
        var focused = 0
        model.moveFocusToResults = { focused += 1 }
        model.text = "skee"
        model.submit()
        #expect(coordinator.filter(for: .allTracks).text == "skee")
        #expect(!coordinator.isPresented, "Return never opens a results pane (PP-MAIN-31)")
        #expect(focused == 1)
        #expect(coordinator.submitCount == 1)
        await sleeper.releaseAll()
    }

    @Test func clearingCommitsAtOnceAndReturnsTheScopeToThisView() async {
        let coordinator = SearchCoordinator()
        let model = makeModel(coordinator)
        model.text = "x"
        model.scope = .library
        #expect(coordinator.isPresented)
        model.clear()
        #expect(model.text.isEmpty && model.tokens.isEmpty)
        #expect(coordinator.filter(for: .allTracks).isEmpty)
        #expect(model.scope == .thisView && coordinator.scope == .thisView)
        await sleeper.releaseAll()
    }

    @Test func deletingTheTextEndsTheWiderScope() async {
        let coordinator = SearchCoordinator()
        let model = makeModel(coordinator)
        model.text = "a"
        model.scope = .online
        model.text = ""
        #expect(model.scope == .thisView)
        #expect(coordinator.filter(for: .allTracks).isEmpty)
        await sleeper.releaseAll()
    }

    @Test func theQueryBelongsToTheViewForTheSession() async {
        let coordinator = SearchCoordinator()
        let places = PlaceBox()
        let model = makeModel(coordinator, places: places)
        model.text = "warm"
        model.scope = .library

        places.place = SearchPlace(key: .playlist(7), capability: .tracks, name: "Warm-up")
        model.placeDidChange()
        #expect(model.text.isEmpty, "Another place starts with its own (empty) query")
        #expect(model.scope == .thisView, "This view each time")
        #expect(coordinator.filter(for: .allTracks).text == "warm", "The left place keeps its query")
        model.tokens = [.genre("Techno")]
        model.submit()

        places.place = .allTracks
        model.placeDidChange()
        #expect(model.text == "warm")
        #expect(model.tokens.isEmpty)
        places.place = SearchPlace(key: .playlist(7), capability: .tracks, name: "Warm-up")
        model.placeDidChange()
        #expect(model.tokens == [.genre("Techno")])
        await sleeper.releaseAll()
    }

    @Test func resetClearsTheVisiblePlaceOnly() async {
        let coordinator = SearchCoordinator()
        let places = PlaceBox()
        let model = makeModel(coordinator, places: places)
        coordinator.commit(SearchFilter(text: "hidden"), for: .playlist(3))
        model.text = "kept"
        model.submit()
        // Go to Current Track navigates first, then resets: the destination's filter clears.
        places.place = SearchPlace(key: .playlist(3), capability: .tracks, name: "Mix")
        model.reset()
        #expect(coordinator.filter(for: .playlist(3)).isEmpty)
        #expect(coordinator.filter(for: .allTracks).text == "kept")
        #expect(!model.isPresented)
        await sleeper.releaseAll()
    }

    @Test func returnOnALinkTakesItsActionAndFiltersNothing() async {
        let coordinator = SearchCoordinator()
        let model = makeModel(coordinator)
        var opened: [LinkSuggestion] = []
        model.openLink = { opened.append($0) }
        model.text = "https://www.youtube.com/watch?v=Zx3kQpL0v9E"
        #expect(model.link == .track(source: .youtube, url: "https://www.youtube.com/watch?v=Zx3kQpL0v9E"))
        model.submit()
        #expect(opened.count == 1)
        #expect(coordinator.filter(for: .allTracks).isEmpty, "A link is never searched as text")
        await sleeper.releaseAll()
    }

    @Test func choosingAValueReplacesTheTypedClause() async {
        let model = makeModel(SearchCoordinator())
        model.text = "remix genre: te"
        model.accept(.genre("Techno"))
        #expect(model.tokens == [.genre("Techno")])
        #expect(model.text == "remix ")
        await sleeper.releaseAll()
    }

    @Test func returnTakesTheFirstValueSuggestion() async {
        let coordinator = SearchCoordinator()
        let model = makeModel(coordinator)
        model.suggestionProvider = FakeSuggestions(values: [
            SearchValueSuggestion(token: .genre("Techno"), count: 12),
            SearchValueSuggestion(token: .genre("Tech House"), count: 3),
        ])
        model.text = "genre: te"
        await flush(model)
        await model.suggestionTask?.value
        #expect(model.valueSuggestions.count == 2)
        model.submit()
        #expect(model.tokens == [.genre("Techno")])
        #expect(model.text.isEmpty)
        await sleeper.releaseAll()
    }

    @Test func filterWordsAreOfferedOnlyWhereTheyApply() async {
        let places = PlaceBox()
        let model = makeModel(SearchCoordinator(), places: places)
        #expect(model.offeredKinds == SearchTokenKind.allCases)
        model.text = "gen"
        #expect(model.keywordCompletions.map(\.completion) == ["genre: "])
        places.place = SearchPlace(key: .allPlaylists, capability: .names, name: "All Playlists")
        model.placeDidChange()
        #expect(model.offeredKinds.isEmpty)
        model.scope = .library
        #expect(model.offeredKinds == SearchTokenKind.allCases)
        model.scope = .online
        #expect(model.offeredKinds.isEmpty)
        await sleeper.releaseAll()
    }

    @Test func aPlaceThatFiltersByNameSaysWhichTokensItIgnores() async {
        let places = PlaceBox()
        places.place = SearchPlace(key: .allPlaylists, capability: .names, name: "All Playlists")
        let model = makeModel(SearchCoordinator(), places: places)
        var hints: [String] = []
        model.postHint = { hints.append($0) }
        model.text = "warm genre:techno"
        model.submit()
        #expect(hints == ["All Playlists filters by name only — “genre: techno” isn’t applied here"])
        model.submit()
        #expect(hints.count == 1, "Said once")
        await sleeper.releaseAll()
    }

    @Test func focusChoosesTheScope() async {
        let model = makeModel(SearchCoordinator())
        model.focus(scope: .library)
        #expect(model.isPresented && model.scope == .library)
        model.focus(scope: .thisView)
        #expect(model.scope == .thisView)
    }

    @Test func goToArtistShowsAllTracksFilteredByTheArtist() async {
        let coordinator = SearchCoordinator()
        let navigation = NavigationModel(selection: .playlist(4))
        let model = ToolbarSearchModel(coordinator: coordinator, sleep: { _ in })
        model.navigation = navigation
        model.placeProvider = { SearchPlace(navigation) }
        model.placeDidChange()
        model.text = "in the playlist"
        model.goToArtist("Overmono")
        #expect(navigation.selection == .allTracks)
        #expect(coordinator.filter(for: .allTracks).tokens == [.artist("Overmono")])
        #expect(model.tokens == [.artist("Overmono")])
        #expect(model.scope == .thisView)
        #expect(coordinator.filter(for: .playlist(4)).text == "in the playlist", "The playlist keeps its query")
    }

    @Test func recentSearchesAreRememberedOnReturn() async throws {
        let suite = "mlm.tests.recent.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = makeModel(SearchCoordinator())
        model.recentStore = RecentSearchStore(defaults: defaults, libraryID: { "lib" })
        model.text = "skee mask"
        model.submit()
        #expect(model.recentSearches.map(\.text) == ["skee mask"])
        model.clear()
        model.apply(model.recentSearches[0])
        #expect(model.text == "skee mask")
        await sleeper.releaseAll()
    }
}

@Suite("Search coordinator")
struct SearchCoordinatorTests {
    @Test func keepsOneFilterPerPlace() {
        let coordinator = SearchCoordinator()
        coordinator.commit(SearchFilter(text: "a"), for: .allTracks)
        coordinator.commit(SearchFilter(tokens: [.genre("Techno")]), for: .playlist(1))
        #expect(coordinator.filter(for: .allTracks).text == "a")
        #expect(coordinator.filter(for: .playlist(1)).tokens == [.genre("Techno")])
        coordinator.commit(.empty, for: .allTracks)
        #expect(coordinator.filters[.allTracks] == nil, "An empty filter isn't kept")
    }

    @Test func onlyAWiderScopeCoversThePlace() {
        let coordinator = SearchCoordinator()
        #expect(!coordinator.isPresented)
        coordinator.setScope(.library)
        #expect(coordinator.isPresented)
        coordinator.setScope(.online)
        #expect(coordinator.isPresented)
        coordinator.setScope(.thisView)
        #expect(!coordinator.isPresented)
    }

    @Test func theActiveFilterIsTheVisiblePlaces() {
        let coordinator = SearchCoordinator()
        coordinator.commit(SearchFilter(text: "x"), for: .folders)
        coordinator.setActivePlace(SearchPlace(key: .folders, capability: .names, name: "Folders"))
        #expect(coordinator.activeFilter.text == "x")
    }
}
