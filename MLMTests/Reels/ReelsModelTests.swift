import CoreGraphics
import Foundation
import GRDB
import Testing
@testable import MLM

// MARK: - Fakes (no network, audio or Vision)

final class FakeReelAnalyzer: ReelAnalyzing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var analysis = ReelAnalysis(keyframes: [], fragments: [], candidates: [])
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func analyze(_ url: URL) async -> ReelAnalysis {
        lock.lock(); _calls += 1; lock.unlock()
        return analysis
    }
}

final class FakeReelAudio: ReelAudioIdentifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var result: ReelAudioResult = .noMatch
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func identify(_ url: URL) async -> ReelAudioResult {
        lock.lock(); _calls += 1; lock.unlock()
        return result
    }
}

final class FakeReelSearch: ReelSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var _queries: [String] = []
    var outcome: ReelSearchOutcome = .groups(ReelSearch.groups(from: UnifiedSearchResults(dabTracks: [], squidTracks: [], soundCloudTracks: [], youtubeTracks: [])))
    var queries: [String] { lock.lock(); defer { lock.unlock() }; return _queries }
    func search(artist: String, title: String) async -> ReelSearchOutcome {
        lock.lock(); _queries.append(ReelSearch.query(artist: artist, title: title)); lock.unlock()
        return outcome
    }
}

final class FakeReelFetcher: ReelFetching, @unchecked Sendable {
    var file: URL?
    var error: (any Error)?
    func fetch(_ link: ReelLink, into folder: URL) async throws -> URL {
        if let error { throw error }
        return file ?? folder.appendingPathComponent("fetched.mp4")
    }
}

final class FakeReelFiles: ReelFileManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var existing: Set<String>
    private var _trashed: [String] = []
    var trashFailure: (any Error)?
    init(existing: [String]) { self.existing = Set(existing) }
    var trashed: [String] { lock.lock(); defer { lock.unlock() }; return _trashed }
    func fileExists(atPath path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return existing.contains(path) }
    func trash(_ url: URL) throws {
        if let trashFailure { throw trashFailure }
        lock.lock(); defer { lock.unlock() }
        existing.remove(url.path)
        _trashed.append(url.path)
    }
}

struct FakeFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

@MainActor
final class FakeReelDownloader: ReelResultDownloading {
    var started: [ReelSearchResult] = []
    var outcome: ReelDownloadStart = .started(trackID: 77)
    var states: [Int64: ReelResultDownload] = [:]
    func start(_ result: ReelSearchResult) async -> ReelDownloadStart {
        started.append(result)
        return outcome
    }
    func progress(of trackID: Int64) async -> ReelResultDownload { states[trackID] ?? .queued }
}

// MARK: - Environment

@MainActor
struct ReelsEnv {
    let db: DatabaseQueue
    let repo: ReelRepository
    let model: ReelsModel
    let undo: UndoCenter
    let manager: UndoManager
    let status: StatusBarCenter
    let analyzer: FakeReelAnalyzer
    let audio: FakeReelAudio
    let search: FakeReelSearch
    let fetcher: FakeReelFetcher
    let files: FakeReelFiles
    let downloader: FakeReelDownloader
    let memory: ReelsSelectionMemory
    let center: ActivityCenter
    let log: Log

    final class Log: @unchecked Sendable {
        var changes = 0
        var playlistAdds: [(Int64, Int64)] = []
        var newPlaylists: [Int64] = []
    }

    struct Seed {
        var file: String
        var artist = ""
        var title = ""
        var state: ReelState = .new
    }

    static let seeds = [
        Seed(file: "/r/Overmono - So U Kno.mp4", artist: "Overmono", title: "So U Kno", state: .identified),
        Seed(file: "/r/IMG_4471.mov"),
        Seed(file: "/r/old.mov", artist: "Bicep", title: "Glue", state: .done),
    ]

    static func make(seeds: [Seed] = ReelsEnv.seeds, existingFiles: [String]? = nil) async throws -> ReelsEnv {
        let db = try DatabaseManager.inMemory()
        let repo = ReelRepository(database: db)
        for (index, seed) in seeds.enumerated() {
            try await repo.save(ImportedReelRecord(
                id: "id\(index)", filePath: seed.file, title: seed.title, artist: seed.artist,
                createdAt: Date(timeIntervalSince1970: 10_000 - Double(index)), updatedAt: Date(timeIntervalSince1970: 10_000),
                state: seed.state))
        }
        let manager = UndoManager()
        manager.groupsByEvent = false
        let sleeper = ManualSleeper()
        let status = StatusBarCenter(sleep: { await sleeper.sleep($0) }, announce: { _ in })
        let undo = UndoCenter(undoManager: manager, statusBar: status, log: { _ in })
        let log = Log()
        let analyzer = FakeReelAnalyzer()
        let audio = FakeReelAudio()
        let search = FakeReelSearch()
        let fetcher = FakeReelFetcher()
        let files = FakeReelFiles(existing: existingFiles ?? seeds.map(\.file))
        let downloader = FakeReelDownloader()
        let pollSleeper = ManualSleeper()
        var dependencies = ReelsModel.Dependencies(
            repository: repo, analyzer: analyzer, audio: audio, search: search, fetcher: fetcher, downloader: downloader)
        dependencies.fetchFolder = FileManager.default.temporaryDirectory
        dependencies.files = files
        dependencies.postChange = { log.changes += 1 }
        dependencies.addToPlaylist = { trackID, playlistID in log.playlistAdds.append((trackID, playlistID)) }
        dependencies.newPlaylist = { trackID in log.newPlaylists.append(trackID) }
        dependencies.sleep = { await pollSleeper.sleep($0) }
        let counter = Counter()
        dependencies.makeID = { "new\(counter.next())" }
        let memory = ReelsSelectionMemory()
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let model = ReelsModel(dependencies: dependencies, memory: memory, center: center)
        model.statusBar = status
        model.undo = undo
        return ReelsEnv(db: db, repo: repo, model: model, undo: undo, manager: manager, status: status, analyzer: analyzer,
                        audio: audio, search: search, fetcher: fetcher, files: files, downloader: downloader,
                        memory: memory, center: center, log: log)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 100
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }

    func record(_ id: String) async throws -> ImportedReelRecord? {
        try await repo.fetchAll().first { $0.id == id }
    }

    func undoStep() async {
        manager.undo()
        await undo.waitUntilIdle()
    }

    func redoStep() async {
        manager.redo()
        await undo.waitUntilIdle()
    }

    var statusText: String? { status.message?.text }
}

// MARK: - Tests

@Suite("ReelsModelTests")
@MainActor
struct ReelsModelTests {
    // MARK: List and selection

    @Test func theFirstReelIsSelectedWhenAnyExistAndNothingStartsWork() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        #expect(env.model.items.map(\.fileName) == ["Overmono - So U Kno.mp4", "IMG_4471.mov", "old.mov"])
        #expect(env.model.focusedID == "id0")
        #expect(env.model.selection == ["id0"])
        env.model.setSelection(["id1"])
        env.model.setSelection(["id2"])
        #expect(env.analyzer.calls == 0 && env.audio.calls == 0 && env.search.queries.isEmpty,
                "selecting a reel never starts work")
        #expect(env.model.items.map(\.state) == [.identified, .new, .done])
        #expect(env.model.items[0].guessLine == "Overmono — So U Kno")
        #expect(env.model.items[1].guessLine == "Not identified yet")
    }

    @Test func theSelectedReelIsRememberedWhileTheAppRuns() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.setSelection(["id1"])
        #expect(env.memory.reelID == "id1")
        // A new model (the view was rebuilt after a scope change) finds the same reel.
        let again = ReelsModel(dependencies: env.model.dependencies, memory: env.memory, center: env.center)
        await again.load()
        #expect(again.focusedID == "id1")
        // A remembered reel that is gone falls back to the first.
        env.memory.reelID = "gone"
        let third = ReelsModel(dependencies: env.model.dependencies, memory: env.memory, center: env.center)
        await third.load()
        #expect(third.focusedID == "id0")
    }

    @Test func emptyListHasNoSelection() async throws {
        let env = try await ReelsEnv.make(seeds: [])
        await env.model.load()
        #expect(env.model.isEmpty)
        #expect(env.model.focusedID == nil)
    }

    @Test func discoverCountsReelsThatAreNotDone() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        #expect(env.model.notDoneCount == 2)
        #expect(try await env.repo.notDoneCount() == 2)
    }

    // MARK: Fields

    @Test func fieldsAreSavedWhenYouLeaveThemNotPerKeystroke() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.setSelection(["id1"])
        env.model.setArtist("B")
        env.model.setArtist("Bi")
        env.model.setArtist("Bicep")
        env.model.setTitle("Glue")
        #expect(env.model.focusedBench?.filledFrom == "Typed by you")
        #expect(try await env.record("id1")?.artist == "", "nothing is written while typing")
        await env.model.commitFields()
        let saved = try await env.record("id1")
        #expect(saved?.artist == "Bicep" && saved?.title == "Glue" && saved?.state == .identified)
        #expect(env.model.item(for: "id1")?.state == .identified)
        #expect(env.log.changes >= 1)
    }

    @Test func leavingAReelSavesItsTypedFields() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.setSelection(["id1"])
        env.model.setArtist("Bicep")
        env.model.setSelection(["id0"])
        await env.model.settle()
        #expect(try await env.record("id1")?.artist == "Bicep")
    }

    @Test func searchIsPossibleWithEitherFieldAndReturnSearches() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.setSelection(["id1"])
        #expect(env.model.focusedBench?.canSearch == false)
        #expect(env.model.focusedBench?.search == .nothingToSearch)
        env.model.setTitle("So U Kno")
        #expect(env.model.focusedBench?.canSearch == true)
        await env.model.search()
        #expect(env.search.queries == ["So U Kno"])
        #expect(try await env.record("id1")?.title == "So U Kno", "searching saves the fields first")
    }

    @Test func searchOutcomesAreToldApart() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.setSelection(["id1"])
        env.model.setArtist("Fred again..")
        env.model.setTitle("Delilah")

        env.search.outcome = .offline
        await env.model.search()
        #expect(env.model.focusedBench?.search == .offline)

        env.search.outcome = .groups(ReelSearch.groups(from: UnifiedSearchResults(dabTracks: [], squidTracks: [], soundCloudTracks: [], youtubeTracks: [])))
        await env.model.search()
        #expect(env.model.focusedBench?.search == .noMatches(query: "Fred again.. Delilah"))

        let youtube = YouTubeTrack(id: "abc", title: "Delilah", duration: 252, url: nil, uploader: "Fred again..")
        env.search.outcome = .groups(ReelSearch.groups(from: UnifiedSearchResults(dabTracks: [], squidTracks: [], soundCloudTracks: [], youtubeTracks: [youtube])))
        await env.model.search()
        guard case .results(let query, let groups) = env.model.focusedBench?.search else {
            Issue.record("expected results")
            return
        }
        #expect(query == "Fred again.. Delilah")
        #expect(groups.map(\.countWord) == ["No matches", "1", "No matches", "No matches"])
    }

    // MARK: Guesses (IMP-061)

    @Test func useFillsBothFieldsSearchesAndIsOneUndoStep() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.setSelection(["id1"])
        env.model.setArtist("typed")
        await env.model.commitFields()
        let guess = ReelGuess(artist: "Fred again..", title: "Delilah", source: .shazam, confidence: 0.95, detail: "matched at 0:07")
        await env.model.use(guess)
        #expect(env.model.focusedBench?.artist == "Fred again.." && env.model.focusedBench?.title == "Delilah")
        #expect(env.model.focusedBench?.filledFrom == "Shazam" && env.model.focusedBench?.usedGuessID == guess.id)
        #expect(env.search.queries == ["Fred again.. Delilah"])
        let saved = try await env.record("id1")
        #expect(saved?.artist == "Fred again.." && saved?.state == .identified)
        #expect(env.manager.undoActionName == "Use Guess")

        await env.undoStep()
        #expect(env.model.focusedBench?.artist == "typed" && env.model.focusedBench?.title == "")
        #expect(try await env.record("id1")?.artist == "typed")
        #expect(env.model.item(for: "id1")?.state == .new)
        #expect(!env.manager.canUndo || env.manager.undoActionName != "Use Guess", "one step")

        await env.redoStep()
        #expect(env.model.focusedBench?.artist == "Fred again..")
        #expect(try await env.record("id1")?.title == "Delilah")
    }

    @Test func identifyProducesGuessesAndNeverTouchesTypedText() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.setSelection(["id1"])
        env.model.setArtist("My own artist")
        env.analyzer.analysis = ReelAnalysis(
            keyframes: [], fragments: ["actual life 3", "pull me out of this"],
            candidates: [ReelTextCandidate(artist: "Fred again", title: "delilah", score: 100, stillOffset: 4)])
        env.audio.result = .match(ReelShazamMatch(artist: "Fred again..", title: "Delilah", offset: 7))
        await env.model.identify("id1")
        let bench = try #require(env.model.focusedBench)
        #expect(bench.artist == "My own artist" && bench.title == "", "guesses never write the fields")
        #expect(bench.guesses.map(\.source) == [.shazam, .text])
        #expect(bench.fragments == ["actual life 3", "pull me out of this"])
        #expect(bench.stills == .read)
        guard case .found = bench.audio else { Issue.record("expected found"); return }
        #expect(!bench.isIdentifying)
        // The guesses are the reel's record.
        let json = try await env.record("id1")?.guessesJSON
        #expect(ReelGuesses.decode(json).map(\.source) == [.shazam, .text])
        #expect(env.analyzer.calls == 1 && env.audio.calls == 1)
    }

    @Test func offlineAndNoMatchAreDifferentResults() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.setSelection(["id1"])
        env.audio.result = .offline
        await env.model.identifyByAudio("id1")
        #expect(env.model.focusedBench?.audio == .offline)
        env.audio.result = .noMatch
        await env.model.identifyByAudio("id1")
        #expect(env.model.focusedBench?.audio == .notRecognised)
        env.audio.result = .failed("the audio couldn’t be read")
        await env.model.identifyByAudio("id1")
        #expect(env.model.focusedBench?.audio == .failed("the audio couldn’t be read"))
        #expect(env.analyzer.calls == 0, "audio alone doesn't read the stills")
        #expect(env.model.focusedBench?.guesses.isEmpty == true)
    }

    @Test func aFragmentFillsOneFieldAsOneUndoStep() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.setSelection(["id1"])
        await env.model.use(fragment: "Fred again..", as: .artist)
        #expect(env.model.focusedBench?.artist == "Fred again.." && env.model.focusedBench?.title == "")
        #expect(env.statusText == "Artist set from the text in the video" || env.statusText != nil)
        await env.model.use(fragment: "Delilah", as: .title)
        #expect(env.model.focusedBench?.title == "Delilah")
        await env.undoStep()
        #expect(env.model.focusedBench?.title == "")
        #expect(env.model.focusedBench?.artist == "Fred again..")
        // “Artist – Title” that can't be split does nothing.
        await env.model.use(fragment: "pull me out of this", as: .artistAndTitle)
        #expect(env.search.queries.isEmpty)
        await env.model.use(fragment: "Fred again - Delilah", as: .artistAndTitle)
        #expect(env.model.focusedBench?.artist == "Fred again" && env.model.focusedBench?.title == "Delilah")
        #expect(env.search.queries == ["Fred again Delilah"])
    }

    // MARK: State

    @Test func markAsDoneIsUndoableAndDoneNeverRegresses() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        await env.model.markDone(["id0", "id1"])
        #expect(env.model.items.map(\.state) == [.done, .done, .done])
        #expect(try await env.record("id1")?.doneAt != nil)
        await env.undoStep()
        #expect(env.model.items.map(\.state) == [.identified, .new, .done])
        #expect(try await env.record("id1")?.doneAt == nil)
        await env.redoStep()
        #expect(env.model.items.map(\.state) == [.done, .done, .done])

        // Typing other text never moves a Done reel back …
        env.model.setSelection(["id0"])
        env.model.setArtist("Someone else")
        env.model.setTitle("Another song")
        await env.model.commitFields()
        #expect(env.model.item(for: "id0")?.state == .done)
        // … only clearing both fields does.
        env.model.setArtist("")
        env.model.setTitle("")
        await env.model.commitFields()
        #expect(env.model.item(for: "id0")?.state == .new)
        #expect(try await env.record("id0")?.doneAt == nil)
    }

    // MARK: Download and playlists

    @Test func downloadMakesTheReelDoneAndFollowsTheInlineStates() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.setSelection(["id1"])
        let result = ReelSearchResult(source: .youtube, externalID: "abc", artist: "Fred again..", title: "Delilah", durationSeconds: 252, sourceURL: nil)
        await env.model.download(result)
        #expect(env.downloader.started == [result])
        #expect(env.model.focusedBench?.downloads[result.id] == .queued)
        #expect(env.model.item(for: "id1")?.state == .done)
        #expect(try await env.record("id1")?.state == .done)
        #expect(env.statusText == "Download started — “Delilah”")

        env.downloader.states[77] = .downloading
        await env.model.refreshDownloads()
        #expect(env.model.focusedBench?.downloads[result.id]?.word == "Downloading…")
        env.downloader.states[77] = .inLibrary
        await env.model.refreshDownloads()
        #expect(env.model.focusedBench?.downloads[result.id]?.word == "In library")

        // A second press on the same row doesn't start it twice.
        await env.model.download(result)
        #expect(env.downloader.started.count == 1)
    }

    @Test func aFailedDownloadSaysWhyAndCanBeRetried() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.setSelection(["id1"])
        let result = ReelSearchResult(source: .dab, externalID: "1", artist: "A", title: "T", durationSeconds: nil, sourceURL: nil)
        env.downloader.outcome = .failed("no library is open")
        await env.model.download(result)
        #expect(env.model.focusedBench?.downloads[result.id] == .failed("no library is open"))
        #expect(env.model.focusedBench?.downloads[result.id]?.word == "Download failed — no library is open")
        #expect(env.model.item(for: "id1")?.state == .new, "a failed download doesn't finish the reel")
        env.downloader.outcome = .started(trackID: 5)
        await env.model.retry(result)
        #expect(env.model.focusedBench?.downloads[result.id] == .queued)
        #expect(env.downloader.started.count == 2)
    }

    @Test func addToPlaylistGoesThroughTheStandardPathAndFinishesTheReel() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.setSelection(["id1"])
        let result = ReelSearchResult(source: .soundCloud, externalID: "9", artist: "A", title: "T", durationSeconds: nil, sourceURL: nil)
        await env.model.addToPlaylist(result, playlistID: 4)
        #expect(env.log.playlistAdds.count == 1 && env.log.playlistAdds[0] == (77, 4))
        #expect(env.model.item(for: "id1")?.state == .done)
        await env.model.newPlaylist(from: result)
        #expect(env.log.newPlaylists == [77])
    }

    @Test func aTrackAlreadyInTheLibraryIsSaidAndStillAddable() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.setSelection(["id1"])
        env.downloader.outcome = .alreadyInLibrary(trackID: 12)
        let result = ReelSearchResult(source: .dab, externalID: "1", artist: "A", title: "T", durationSeconds: nil, sourceURL: nil)
        await env.model.download(result)
        #expect(env.model.focusedBench?.downloads[result.id] == .inLibrary)
        #expect(env.statusText == "“T” is already in your library")
    }

    // MARK: Delete Reel… (IMP-062)

    @Test func theAlertWordsCountAndOfferTheTrash() {
        #expect(ReelsModel.deleteTitle(count: 1) == "Delete 1 reel?")
        #expect(ReelsModel.deleteTitle(count: 3) == "Delete 3 reels?")
        #expect(ReelsModel.trashToggleTitle(count: 1) == "Also move the video file to the Trash")
        #expect(ReelsModel.trashToggleTitle(count: 2) == "Also move the 2 video files to the Trash")
        #expect(ReelsModel.deleteMessage == "It is removed from this list. Tracks you downloaded from it stay in the library.")
    }

    @Test func deleteWithTheTrashMovesTheFileAndSaysSo() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.requestDelete(["id0", "id1"])
        #expect(env.model.pendingDeletion == ["id0", "id1"])
        await env.model.confirmDelete(moveFilesToTrash: true)
        #expect(env.files.trashed == ["/r/Overmono - So U Kno.mp4", "/r/IMG_4471.mov"])
        #expect(env.model.items.map(\.id) == ["id2"])
        #expect(try await env.repo.fetchAll().map(\.id) == ["id2"])
        #expect(env.model.focusedID == "id2", "the selection moves to a reel that is left")
        #expect(env.statusText == "Deleted 2 reels — video files moved to the Trash")
        #expect(env.model.pendingDeletion == nil)
    }

    @Test func deleteWithoutTheTrashKeepsTheFile() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.requestDelete(["id1"])
        await env.model.confirmDelete(moveFilesToTrash: false)
        #expect(env.files.trashed.isEmpty)
        #expect(env.files.fileExists(atPath: "/r/IMG_4471.mov"))
        #expect(env.statusText == "Deleted 1 reel — video file kept")
        #expect(try await env.repo.fetchAll().count == 2)
    }

    @Test func aFileThatCantGoToTheTrashKeepsTheReelListedAndNamesTheCause() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.files.trashFailure = FakeFailure(text: "the file is in use by another app")
        env.model.requestDelete(["id1"])
        await env.model.confirmDelete(moveFilesToTrash: true)
        #expect(env.model.items.map(\.id) == ["id0", "id1", "id2"], "the reel stays listed")
        #expect(try await env.repo.fetchAll().count == 3)
        #expect(env.statusText == "Couldn’t delete “IMG_4471.mov” — the file is in use by another app")
        #expect(env.status.message?.actions.map(\.title) == ["Show Logs"])
    }

    @Test func aReelWhoseVideoIsGoneStillDeletes() async throws {
        let env = try await ReelsEnv.make(existingFiles: [])
        await env.model.load()
        #expect(env.model.focusedBench?.videoReachable == false)
        env.model.requestDelete(["id1"])
        await env.model.confirmDelete(moveFilesToTrash: true)
        #expect(env.model.items.count == 2)
    }

    // MARK: Import and drops

    @Test func importAddsVideosFromFoldersWithoutCopyingAndSaysSo() async throws {
        let env = try await ReelsEnv.make(seeds: [])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reelsmodel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("Overmono - So U Kno.mp4"))
        try Data("x".utf8).write(to: root.appendingPathComponent("sub/clip.mov"))
        await env.model.load()
        await env.model.importURLs([root])
        #expect(env.model.items.count == 2)
        #expect(env.statusText == "Added 2 reels")
        #expect(env.model.items.contains { $0.artist == "Overmono" && $0.state == .identified })
        #expect(env.model.items.contains { $0.fileName == "clip.mov" && $0.state == .new })
        #expect(env.model.focusedID != nil, "the first reel is selected once any exist")
        #expect(env.log.changes >= 1)
        // The same folder again adds nothing and says so.
        await env.model.importURLs([root])
        #expect(env.model.items.count == 2)
        #expect(env.statusText == ReelsModel.nothingAddedSentence)
    }

    @Test func aFolderWithoutVideosIsNamedInTheStatusBar() async throws {
        let env = try await ReelsEnv.make(seeds: [])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Documents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        await env.model.load()
        await env.model.importURLs([folder])
        #expect(env.model.items.isEmpty)
        #expect(env.statusText == "No videos in “\(folder.lastPathComponent)”")
    }

    @Test func addedSentencesCountAndMentionRepeats() {
        #expect(ReelsModel.addedSentence(added: 1, alreadyListed: 0) == "Added 1 reel")
        #expect(ReelsModel.addedSentence(added: 3, alreadyListed: 2) == "Added 3 reels · 2 already listed")
    }

    // MARK: Links

    @Test func aLinkOfAnotherKindIsRefusedWithTheSheetsWords() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        #expect(env.model.addLink(text: "https://example.com/video") == ReelLinkParser.refusal)
        #expect(env.model.addLink(text: "not a link") == ReelLinkParser.refusal)
        env.model.addDroppedLink(URL(string: "https://example.com/video")!)
        #expect(env.statusText == ReelLinkParser.refusal)
    }

    @Test func aFetchedReelArrivesAsNewAndFinishesTheActivityOperation() async throws {
        let env = try await ReelsEnv.make(seeds: [])
        await env.model.load()
        env.fetcher.file = URL(fileURLWithPath: "/r/Instagram_C9xQ-2mTtP4k.mp4")
        let link = try #require(ReelLinkParser.parse("https://www.instagram.com/reel/C9xQ2mTtP4k/"))
        await env.model.addLink(link).value
        let item = try #require(env.model.items.first)
        #expect(item.fileName == "Instagram_C9xQ-2mTtP4k.mp4")
        #expect(item.state == .new && item.artist.isEmpty, "the site's id is not a song")
        let operation = try #require(env.center.allOperations.first)
        #expect(operation.title == "Fetching reel…")
        #expect(operation.state == .completed)
    }

    @Test func aFailedFetchFailsTheOperationInWords() async throws {
        let env = try await ReelsEnv.make(seeds: [])
        await env.model.load()
        env.fetcher.error = ReelFetchError.needsSignIn
        let link = try #require(ReelLinkParser.parse("https://www.tiktok.com/@a/video/1"))
        await env.model.addLink(link).value
        #expect(env.model.items.isEmpty)
        let operation = try #require(env.center.allOperations.first)
        #expect(operation.state == .failed)
        #expect(operation.result?.failureCause == "the link needs a sign-in")
    }

    // MARK: Playing

    @Test func playVideoSelectsTheReelAndAsksThePlayer() async throws {
        let env = try await ReelsEnv.make()
        await env.model.load()
        env.model.playVideo("id1", from: 4)
        #expect(env.model.focusedID == "id1" && env.model.selection == ["id1"])
        #expect(env.model.playRequest?.reelID == "id1" && env.model.playRequest?.offset == 4)
    }
}

// MARK: - Drop decisions (DropTarget.reels)

@Suite("ReelsDropRulesTests")
struct ReelsDropRulesTests {
    private let context = DropContext(libraryID: "lib", isLibraryOpen: true, offlineVolumeName: nil)

    @Test func theWholeViewTakesFilesAndLinksButNotTracks() {
        #expect(DropRules.accepts(.files, on: .reels, context: context))
        #expect(DropRules.accepts(.link, on: .reels, context: context))
        #expect(!DropRules.accepts(.tracks, on: .reels, context: context))
        #expect(!DropRules.accepts(.playlists, on: .reels, context: context))
        #expect(!DropRules.accepts(.imageData, on: .reels, context: context))
    }

    @Test func videosAndFoldersAreAddedOthersAreRefusedInWords() {
        let video = DroppedFile(url: URL(fileURLWithPath: "/x/a.mp4"), kind: .other)
        let mov = DroppedFile(url: URL(fileURLWithPath: "/x/b.MOV"), kind: .other)
        let folder = DroppedFile(url: URL(fileURLWithPath: "/x/Clips"), kind: .folder)
        let text = DroppedFile(url: URL(fileURLWithPath: "/x/n.txt"), kind: .other)
        #expect(DropRules.decide(.files([video, mov, folder, text]), onto: .reels, context: context)
            == .addReels([video.url, mov.url, folder.url]))
        #expect(DropRules.decide(.files([text]), onto: .reels, context: context)
            == .refuse("Can’t add “n.txt” — it isn’t a video or a folder"))
    }

    @Test func aReelLinkIsFetchedAnyOtherLinkIsRefusedWithTheSheetsWords() {
        let reel = URL(string: "https://www.instagram.com/reel/C9xQ2mTtP4k/")!
        #expect(DropRules.decide(.link(reel), onto: .reels, context: context) == .fetchReelLink(reel))
        #expect(DropRules.decide(.link(URL(string: "https://example.com/a")!), onto: .reels, context: context)
            == .refuse(ReelLinkParser.refusal))
    }

    @Test func tracksOnTheReelsViewAreRefusedQuietly() {
        let payload = TrackDragPayload(items: [])
        #expect(DropRules.decide(.tracks(payload), onto: .reels, context: context) == .refuse(nil))
    }

    @Test func aDropOnTheReelsViewNeedsAnOpenLibrary() {
        let closed = DropContext(libraryID: nil, isLibraryOpen: false, offlineVolumeName: nil)
        #expect(!DropRules.accepts(.files, on: .reels, context: closed))
    }

    @Test func theLibraryDriveBeingAwayDoesNotMatterForReels() {
        let offline = DropContext(libraryID: "lib", isLibraryOpen: true, offlineVolumeName: "Lexxar")
        let video = DroppedFile(url: URL(fileURLWithPath: "/x/a.mp4"), kind: .other)
        #expect(DropRules.decide(.files([video]), onto: .reels, context: offline) == .addReels([video.url]))
    }
}

// MARK: - Keyframes

@Suite("ReelKeyframeTests")
struct ReelKeyframeTests {
    @Test func stillsAreDownsizedToTheKeptSize() throws {
        let context = try #require(CGContext(
            data: nil, width: 1080, height: 1920, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let small = KeyframeGeometry.downsized(image)
        #expect(max(small.width, small.height) == KeyframeGeometry.keptLongSide)
        #expect(small.width < small.height, "the aspect ratio is kept")
        // A still already small enough is returned as it is.
        #expect(KeyframeGeometry.downsized(small).width == small.width)
        #expect(KeyframeGeometry.maximumKept == 10)
    }

    @Test func analysisKeepsTenStillsAtMostWithTheirText() async {
        struct Frames: KeyframeExtracting {
            func frames(of url: URL, count: Int) -> AsyncStream<ReelFrame> {
                AsyncStream { continuation in
                    for index in 0..<count {
                        guard let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: CGColorSpaceCreateDeviceRGB(),
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                              let image = context.makeImage() else { continue }
                        continuation.yield(ReelFrame(offset: Double(index), image: ReelImage(cgImage: image)))
                    }
                    continuation.finish()
                }
            }
        }
        struct Reader: ReelTextReading {
            func read(_ image: ReelImage) async -> [String] { ["Fred again.. - Delilah", "@someone", "pull me out of this"] }
        }
        let analysis = await LiveReelAnalyzer(extractor: Frames(), reader: Reader()).analyze(URL(fileURLWithPath: "/x.mp4"))
        #expect(analysis.keyframes.count == 10)
        #expect(analysis.keyframes[3].offset == 3)
        #expect(analysis.keyframes[0].texts == ["Fred again.. - Delilah", "pull me out of this"])
        #expect(analysis.candidates.map(\.artist) == ["Fred again.."])
        #expect(analysis.candidates.first?.stillOffset == 0, "the first still it appeared in")
        #expect(analysis.fragments == ["Fred again.. - Delilah", "pull me out of this"])
    }
}
