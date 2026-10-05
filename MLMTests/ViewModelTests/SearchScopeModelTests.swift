import Foundation
import GRDB
import Testing
@testable import MLM

/// The `Online` and `Library` scopes and the downloads they start (W2-I, UC-SEARCH-02/03).
/// Sources are fakes — no test hits the network.
@Suite("Online search model")
@MainActor
struct OnlineSearchModelTests {
    private let sleeper = ManualSleeper()

    /// A source with a fixed answer, counting its requests; it can be held until released.
    final class FakeSource: OnlineSearchProviding, @unchecked Sendable {
        let source: OnlineSource
        let unavailableReason: OnlineSourceFailure?
        var answer: Result<[RemoteSearchResult], OnlineSourceFailure>
        private(set) var queries: [String] = []
        private var gate: CheckedContinuation<Void, Never>?
        var holds = false

        init(_ source: OnlineSource, answer: Result<[RemoteSearchResult], OnlineSourceFailure> = .success([]),
             unavailable: OnlineSourceFailure? = nil) {
            self.source = source
            self.answer = answer
            self.unavailableReason = unavailable
        }

        func search(_ query: String) async throws -> [RemoteSearchResult] {
            queries.append(query)
            if holds { await withCheckedContinuation { gate = $0 } }
            return try answer.get()
        }

        func release() { gate?.resume(); gate = nil }
    }

    static func result(_ id: String, _ source: RemoteSearchResult.Source = .youtube, title: String = "Good Lies") -> RemoteSearchResult {
        RemoteSearchResult(id: id, source: source, artist: "Overmono", title: title, durationSeconds: 222, externalId: id,
                           sourceURL: "https://www.youtube.com/watch?v=\(id)")
    }

    private func makeModel(_ sources: [FakeSource]) -> OnlineSearchModel {
        let sleeper = self.sleeper
        let model = OnlineSearchModel(sleep: { await sleeper.sleep($0) })
        model.providers = { sources }
        return model
    }

    private func settle(_ model: OnlineSearchModel) async {
        await model.searchTask?.value
    }

    @Test func noRequestPerKeystrokeOnlyAfterThePause() async {
        let youtube = FakeSource(.youtube, answer: .success([Self.result("a")]))
        let model = makeModel([youtube])
        model.queryChanged("o")
        model.queryChanged("ov")
        model.queryChanged("overmono")
        await sleeper.waitForPending(1)
        #expect(youtube.queries.isEmpty, "Nothing is asked while typing")
        #expect(await sleeper.durations.last == OnlineSearchModel.pause)
        let pause = model.pauseTask
        await sleeper.releaseAll()
        await pause?.value
        await settle(model)
        #expect(youtube.queries == ["overmono"])
        #expect(model.sections.first?.state == .results([OnlineResultRow(result: Self.result("a"))]))
    }

    @Test func returnAsksAtOnce() async {
        let youtube = FakeSource(.youtube)
        let model = makeModel([youtube])
        model.searchNow("overmono")
        await settle(model)
        #expect(youtube.queries == ["overmono"])
    }

    @Test func aNewerQueryDropsTheOlderAnswer() async {
        let slow = FakeSource(.soundcloud, answer: .success([Self.result("old", .soundcloud)]))
        slow.holds = true
        let model = makeModel([slow])
        model.searchNow("old")
        while slow.queries.isEmpty { await Task.yield() }
        slow.holds = false
        slow.answer = .success([Self.result("new", .soundcloud)])
        model.searchNow("new")
        await settle(model)
        slow.release()
        #expect(model.query == "new")
        #expect(model.sections.first?.state == .results([OnlineResultRow(result: Self.result("new", .soundcloud))]))
    }

    @Test func eachSourceHasItsOwnStateInAnswerOrder() async {
        let youtube = FakeSource(.youtube, unavailable: .toolMissing)
        let soundcloud = FakeSource(.soundcloud, answer: .failure(.signInExpired))
        let dab = FakeSource(.dab, answer: .success([Self.result("d", .dab)]))
        dab.holds = true
        let model = makeModel([youtube, soundcloud, dab])
        model.searchNow("overmono")
        #expect(model.sections.map(\.state) == [.failed(.toolMissing), .searching, .searching])
        #expect(youtube.queries.isEmpty, "A missing tool isn't asked")
        while dab.queries.isEmpty || model.sections.first(where: { $0.source == .soundcloud })?.state == .searching {
            await Task.yield()
        }
        dab.release()
        await settle(model)
        #expect(model.sections.map(\.source) == [.youtube, .soundcloud, .dab])
        #expect(model.sections[1].state == .failed(.signInExpired))
    }

    @Test func failuresSayWhatAndOfferOneFix() {
        #expect(OnlineSourceFailure.signInExpired.sentence(for: .soundcloud) == "Sign-in expired")
        #expect(OnlineSourceFailure.signInExpired.fix.title == "Reconnect")
        #expect(OnlineSourceFailure.toolMissing.sentence(for: .youtube) == "yt-dlp not found")
        #expect(OnlineSourceFailure.toolMissing.fix.title == "Open Settings ▸ Sources")
        #expect(OnlineSourceFailure.noAnswer(details: "500").sentence(for: .soundcloud) == "SoundCloud didn’t answer")
        #expect(OnlineSourceFailure.noAnswer(details: "500").fix.title == "Try Again")
        #expect(OnlineSourceFailure.offline.sentence(for: .dab) == "DAB didn’t answer — no internet connection")
        #expect(LiveOnlineSearchProviders.failure(URLError(.notConnectedToInternet)) == .offline)
        #expect(LiveOnlineSearchProviders.failure(SoundCloudClient.SoundCloudError.tokenExpired) == .signInExpired)
    }

    @Test func retryAsksOneSourceAgain() async {
        let soundcloud = FakeSource(.soundcloud, answer: .failure(.noAnswer(details: "")))
        let model = makeModel([soundcloud])
        model.searchNow("x")
        await settle(model)
        soundcloud.answer = .success([])
        model.retry(.soundcloud)
        while model.sections.first?.state != .results([]) { await Task.yield() }
        #expect(soundcloud.queries == ["x", "x"])
    }

    @Test func noSourcesIsItsOwnState() {
        #expect(makeModel([]).hasNoSources)
    }

    @Test func inLibraryComesFromTheMatcherAndADownload() async {
        let youtube = FakeSource(.youtube, answer: .success([Self.result("a"), Self.result("b")]))
        let model = makeModel([youtube])
        model.libraryMatches = { _ in ["a": 7] }
        model.searchNow("x")
        await settle(model)
        guard case .results(let rows) = model.sections.first?.state else { Issue.record("no rows"); return }
        #expect(rows.map(\.libraryTrackID) == [7, nil])
        model.downloadStarted(resultID: "b", trackID: 9)
        guard case .results(let after) = model.sections.first?.state else { return }
        #expect(after.map(\.libraryTrackID) == [7, 9])
        #expect(model.startedDownloads == ["b": 9])
    }

    /// PP-MAIN-04: searching writes nothing — the online scope, the Library scope and the
    /// `In library` lookups all leave `tracks` untouched.
    @Test func searchingLeavesTheTracksTableUntouched() async throws {
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)
        _ = try await repo.insert(Track(artist: "Overmono", album: "Good Lies", title: "So U Kno", format: "m4a", originalPath: "/a"))
        let queries = TrackSearchQueries(database: db)
        let before = try await db.read { try Row.fetchAll($0, sql: "SELECT * FROM tracks") }

        let youtube = FakeSource(.youtube, answer: .success([Self.result("a"), Self.result("b")]))
        let soundcloud = FakeSource(.soundcloud, answer: .success([Self.result("c", .soundcloud)]))
        let model = makeModel([youtube, soundcloud])
        model.libraryMatches = { results in (try? await queries.libraryTrackIDs(for: results)) ?? [:] }
        model.searchNow("overmono")
        await settle(model)

        let library = LibrarySearchModel()
        library.trackSearch = { filter, limit in try await queries.matchingTracks(filter: filter, limit: limit) }
        library.search(SearchFilter(text: "overmono genre:techno"))
        await library.task?.value
        _ = try await queries.valueSuggestions(kind: .artist, partial: "o")

        let after = try await db.read { try Row.fetchAll($0, sql: "SELECT * FROM tracks") }
        #expect(after == before)
        let sources = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM track_sources") }
        #expect(sources == 0)
    }
}

/// A value tests can change from `@Sendable` closures.
final class SearchTestBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

private func playlist(_ id: Int64, _ name: String) -> Playlist {
    Playlist(id: id, name: name, description: nil, category: "native", isLiked: 0, isSmart: 0, isPinned: 0)
}

@Suite("Library search model")
@MainActor
struct LibrarySearchModelTests {
    @Test func groupsTracksPlaylistsAndFoldersWithTotals() async {
        let model = LibrarySearchModel()
        let asked = SearchTestBox<[SearchFilter]>([])
        model.trackSearch = { filter, limit in
            asked.value.append(filter)
            return (Array(repeating: Track(artist: "A", album: "", title: "T", format: "m4a", originalPath: "/x"), count: limit), 12)
        }
        model.playlists = { (1...7).map { playlist(Int64($0), "Warm-up \($0)") } + [playlist(99, "Peak")] }
        model.folderSearch = { _ in [LibraryFolderHit(id: "/m/warm", name: "warm", location: "m")] }
        model.search(SearchFilter(text: "warm", tokens: [.availability(.local)]))
        await model.task?.value
        let results = try? #require(model.results)
        #expect(results?.trackTotal == 12)
        #expect(results?.tracks.count == LibrarySearchModel.sectionLimit)
        #expect(results?.playlistTotal == 7)
        #expect(results?.playlists.count == 5)
        #expect(results?.folderTotal == 1)
        #expect(asked.value.first?.tokens == [.availability(.local)], "Tracks get text and tokens")
    }

    @Test func tokensAloneFindNoNamesAndAnEmptyFilterNothing() async {
        let model = LibrarySearchModel()
        model.playlists = { [playlist(1, "Techno")] }
        model.search(SearchFilter(tokens: [.genre("Techno")]))
        await model.task?.value
        #expect(model.results?.playlistTotal == 0)
        model.search(.empty)
        #expect(model.results == nil)
    }

    @Test func folderLocationReadsLikeAPath() {
        #expect(LibraryFolderHit.location(of: "/Volumes/Disk/Music/Artists/Overmono", under: "/Volumes/Disk/Music") == "Music ▸ Artists")
        #expect(LibraryFolderHit.location(of: "/Volumes/Disk/Music/Overmono", under: "/Volumes/Disk/Music") == "Music")
    }

    @Test func titlesNameTheQueryAndTheScope() {
        #expect(SearchResultsView.title(filter: SearchFilter(text: "overmono"), scope: .library) == "“overmono” in your library")
        #expect(SearchResultsView.title(filter: SearchFilter(text: "overmono"), scope: .online) == "“overmono” online")
        #expect(SearchResultsView.title(filter: .empty, scope: .library) == "Search")
    }
}

@Suite("Search downloads")
@MainActor
struct SearchDownloadServiceTests {
    final class FakeStarter: TrackDownloadStarting {
        var isBusy = false
        private(set) var started: [(Track, DownloadOrchestrator.PreferredSource)] = []
        func start(_ track: Track, preferredSource: DownloadOrchestrator.PreferredSource, artworkURL: String?) {
            started.append((track, preferredSource))
        }
    }

    private func makeService() throws -> (SearchDownloadService, FakeStarter, TrackRepository, DatabaseQueue) {
        let db = try DatabaseManager.inMemory()
        let tracks = TrackRepository(database: db)
        let writer = LiveSearchTrackWriter(trackRepository: tracks, sourceRepository: SourceRepository(database: db),
                                           queries: TrackSearchQueries(database: db))
        let starter = FakeStarter()
        return (SearchDownloadService(writer: writer, starter: starter), starter, tracks, db)
    }

    /// DEC-013: a downloaded online result never gets its source name as album.
    @Test func aDownloadedOnlineResultHasNoSourceAsAlbum() async throws {
        let (service, starter, tracks, _) = try makeService()
        for source in RemoteSearchResult.Source.allCases {
            let result = RemoteSearchResult(id: "\(source)-1", source: source, artist: "Overmono", title: "Good Lies \(source)",
                                            durationSeconds: 222, externalId: "1", sourceURL: nil)
            let outcome = await service.download(result)
            guard case .started(let id, _) = outcome else { Issue.record("\(source): \(outcome)"); continue }
            let track = try #require(try await tracks.fetchTrack(id: id))
            #expect(track.album.isEmpty, "\(source): album stays empty")
            #expect(!TrackMetadataPresentation.isRealAlbum(track.album))
        }
        #expect(starter.started.map(\.1) == [.soundcloud, .auto, .youtube, .auto])
    }

    @Test func nothingIsWrittenWhileAnotherDownloadRuns() async throws {
        let (service, starter, tracks, _) = try makeService()
        starter.isBusy = true
        let outcome = await service.download(OnlineSearchModelTests.result("a"))
        #expect(outcome == .busy)
        #expect(try await tracks.fetchAllTracks().isEmpty)
        let link = await service.download(.track(source: .youtube, url: "https://www.youtube.com/watch?v=a"), metadata: nil)
        #expect(link == .busy)
        #expect(try await tracks.fetchAllTracks().isEmpty)
    }

    /// The single-URL download of the removed universal panel, kept as a service.
    @Test func aTrackLinkBecomesOneNotDownloadedTrackAndDownloads() async throws {
        let (service, starter, tracks, db) = try makeService()
        let url = "https://www.youtube.com/watch?v=Zx3kQpL0v9E"
        let outcome = await service.download(.track(source: .youtube, url: url),
                                             metadata: LinkMetadata(title: "Good Lies", artist: "XL Recordings", durationSeconds: 222))
        guard case .started(let id, let title) = outcome else { Issue.record("\(outcome)"); return }
        #expect(title == "Good Lies")
        let track = try #require(try await tracks.fetchTrack(id: id))
        #expect(track.album.isEmpty, "Was “YouTube” (source-as-album)")
        #expect(track.originalPath == url)
        #expect(track.isRemote)
        #expect(track.duration == 222)
        #expect(starter.started.first?.1 == .youtube)
        let links = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM track_sources WHERE track_id = ?", arguments: [id]) }
        #expect(links == 1)
        #expect(SearchDownloadService.message(for: outcome, title: "") == "Download started — “Good Lies”")

        let again = await service.download(.track(source: .youtube, url: url), metadata: nil)
        #expect(again == .alreadyInLibrary(trackID: id))
        #expect(try await tracks.fetchAllTracks().count == 1)
    }

    @Test func aLinkWithoutMetadataIsNamedByItsAddress() {
        let track = SearchDownloadService.linkedTrack(url: "https://soundcloud.com/a/b", source: .soundcloud, metadata: nil)
        #expect(track.title == "soundcloud.com/a/b")
        #expect(track.artist.isEmpty)
        #expect(track.album.isEmpty)
        #expect(track.format == "soundcloud")
    }
}

@Suite("Quick add router")
@MainActor
struct QuickAddRouterTests {
    final class Presenter: QuickAddPresenting {
        var links: [LinkSuggestion] = []
        func presentQuickAdd(for link: LinkSuggestion, lookup: LinkLookup?) { links.append(link) }
    }

    @Test func aPresenterTakesEveryLink() {
        let router = QuickAddRouter()
        let presenter = Presenter()
        router.presenter = presenter
        router.open(url: "https://soundcloud.com/a/sets/b")
        router.open(url: "not a link")
        #expect(presenter.links == [.playlist(source: .soundcloud, url: "https://soundcloud.com/a/sets/b")])
    }

    @Test func interimDownloadsATrackAndSaysSo() async {
        let router = QuickAddRouter()
        var posted: [String] = []
        let downloaded = SearchTestBox<[LinkSuggestion]>([])
        router.interim.download = { link, _ in
            downloaded.value.append(link)
            return .started(trackID: 1, title: "Good Lies")
        }
        router.interim.post = { posted.append($0) }
        router.open(url: "https://youtu.be/x", lookup: LinkLookup(metadata: LinkMetadata(title: "Good Lies")))
        await router.task?.value
        #expect(downloaded.value.count == 1)
        #expect(posted == ["Download started — “Good Lies”"])
    }

    @Test func interimShowsATrackTheLibraryHas() async {
        let router = QuickAddRouter()
        var revealed: [Int64] = []
        var posted: [String] = []
        router.interim.revealInLibrary = { revealed.append($0) }
        router.interim.post = { posted.append($0) }
        router.interim.download = { _, _ in Issue.record("must not download"); return .busy }
        router.open(url: "https://youtu.be/x", lookup: LinkLookup(metadata: LinkMetadata(title: "So U Kno"), libraryTrackID: 5))
        await router.task?.value
        #expect(revealed == [5])
        #expect(posted == ["“So U Kno” is already in your library"])
    }

    @Test func interimPlaylistsGoToTheImportOrSayWhere() {
        let router = QuickAddRouter()
        var opened: [(LinkSource, String)] = []
        var posted: [String] = []
        router.interim.importPlaylist = { source, url in
            opened.append((source, url))
            return source != .spotify
        }
        router.interim.post = { posted.append($0) }
        router.open(url: "https://www.youtube.com/playlist?list=PL1")
        #expect(opened.first?.0 == .youtube)
        #expect(posted.isEmpty)
        router.open(url: "https://open.spotify.com/playlist/1")
        #expect(posted == [QuickAddRouter.spotifyPlaylistMessage])
        router.open(url: "https://bandcamp.com/x")
        #expect(posted.last == "MLM can’t download from this site")
    }

    @Test func aWaitingPlaylistLinkIsTakenOnceBySource() {
        let request = RemotePlaylistLinkRequest()
        request.request("https://soundcloud.com/a/sets/b", source: .soundcloud)
        #expect(request.take(.youtube) == nil)
        #expect(request.take(.soundcloud) == "https://soundcloud.com/a/sets/b")
        #expect(request.take(.soundcloud) == nil)
    }
}
