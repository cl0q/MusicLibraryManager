import Foundation
import GRDB
import Testing
@testable import MLM

/// The session state of the genre pages (W3-GEN): staging survives (it lives outside every
/// view), Discard and Save end it, `Not Now` hides for the session, suggestions are computed on
/// demand from the similarity source with the right states.
@Suite("Genres: staging and suggestions", .serialized)
@MainActor
struct GenreWorkbenchTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "GenreWorkbenchTests.\(UUID().uuidString)"))
    }

    private func track(_ id: Int64, genre: String? = nil) -> Track {
        var track = Track(artist: "Artist", album: "", title: "Title \(id)", format: "m4a", originalPath: "/x/\(id).m4a")
        track.id = id
        track.genre = genre
        return track
    }

    @Test func stagingKeepsOrderSkipsTheGenresOwnTracksAndEndsOnlyWithDiscardOrSave() throws {
        let bench = GenreWorkbench(defaults: try defaults(), activity: nil)
        #expect(bench.stage([track(1), track(2, genre: "Techno"), track(3, genre: "House"), track(1)], genreKey: "techno") == 2)
        #expect(bench.page("techno").staged.compactMap(\.id) == [1, 3])
        #expect(bench.stagedCount("techno") == 2)
        #expect(bench.stagedCount("house") == 0, "per genre")
        bench.unstage([1], genreKey: "techno")
        #expect(bench.page("techno").staged.compactMap(\.id) == [3])
        bench.stage([track(4)], genreKey: "techno")
        bench.didSave([3], genreKey: "techno")
        #expect(bench.page("techno").staged.compactMap(\.id) == [4])
        #expect(bench.discard(genreKey: "techno") == 1)
        #expect(bench.stagedCount("techno") == 0)
    }

    @Test func stagingBelongsToItsLibrary() throws {
        let bench = GenreWorkbench(defaults: try defaults(), activity: nil)
        bench.use(libraryID: "A")
        bench.stage([track(1)], genreKey: "techno")
        bench.use(libraryID: "A")
        #expect(bench.stagedCount("techno") == 1, "the same library keeps its staging")
        bench.use(libraryID: "B")
        #expect(bench.stagedCount("techno") == 0)
    }

    @Test func renameAndMergeCarryTheStagingToTheNewGenre() throws {
        let bench = GenreWorkbench(defaults: try defaults(), activity: nil)
        bench.stage([track(1), track(2)], genreKey: "hip hop")
        bench.stage([track(2), track(3)], genreKey: "hip-hop")
        bench.hide([9], genreKey: "hip hop")
        bench.move(from: "hip hop", to: "hip-hop")
        #expect(bench.page("hip-hop").staged.compactMap(\.id) == [2, 3, 1])
        #expect(bench.page("hip-hop").hidden == [9])
        #expect(bench.stagedCount("hip hop") == 0)
    }

    @Test func notNowHidesForTheSessionUntilShownAgain() throws {
        let bench = GenreWorkbench(defaults: try defaults(), activity: nil)
        bench.stage([track(5)], genreKey: "techno")
        bench.hide([5, 6], genreKey: "techno")
        #expect(bench.page("techno").hidden == [5, 6])
        #expect(bench.stagedCount("techno") == 0, "a hidden track isn't staged")
        bench.unhideAll(genreKey: "techno")
        #expect(bench.page("techno").hidden.isEmpty)
    }

    @Test func expandedStateAndOptionsAreRemembered() throws {
        let store = try defaults()
        let bench = GenreWorkbench(defaults: store, activity: nil)
        #expect(!bench.isSuggestionsExpanded, "collapsed by default (V-GENRED.N04)")
        bench.isSuggestionsExpanded = true
        bench.options.count = 20
        let again = GenreWorkbench(defaults: store, activity: nil)
        #expect(again.isSuggestionsExpanded)
        #expect(again.options.count == 20)
    }

    // MARK: Suggestions

    private func database(analysed ids: [Int64]) throws -> (DatabaseQueue, GenreRepository) {
        let db = try DatabaseManager.inMemory()
        try db.write { db in
            for id in 1...10 {
                try db.execute(sql: """
                    INSERT INTO tracks (id, artist, album_artist, album, title, genre, format, original_path, is_duplicate)
                    VALUES (?, 'Artist', 'Artist', '', ?, NULL, 'm4a', ?, 0)
                    """, arguments: [id, "Title \(id)", "/x/\(id).m4a"])
            }
            for id in ids {
                try db.execute(sql: "INSERT INTO track_embeddings (track_id, master_embedding, drop_offset) VALUES (?, ?, 0)",
                               arguments: [id, [Float(1), 0].toData])
            }
        }
        return (db, GenreRepository(database: db))
    }

    @Test func suggestionsAreComputedFromTheSourceAndLeaveOutStagedAndHidden() async throws {
        let (_, repository) = try database(analysed: [1])
        let bench = GenreWorkbench(defaults: try defaults(), activity: nil)
        let requested = GenreTestBox<[Int]>([])
        let candidates = (2...8).map { GenreSimilarityCandidate(track: track(Int64($0)), score: 1 - Float($0) / 100) }
        let source = GenreSimilaritySource { seed, limit, _ in
            requested.update { $0.append(limit) }
            #expect(seed == 1)
            return candidates
        }
        bench.stage([track(2)], genreKey: "techno")
        bench.hide([3], genreKey: "techno")
        bench.setReference(track(1), genreKey: "techno", genreName: "Techno", repository: repository, source: source)
        #expect(bench.page("techno").state == .loading)
        await bench.waitForSuggestions(genreKey: "techno")
        let page = bench.page("techno")
        #expect(page.state == .ready)
        #expect(page.suggestions.map(\.id) == [4, 5, 6, 7, 8])
        #expect(page.matchByID[4] == 96)
        #expect(requested.value == [GenreSuggestionRules.requestLimit(bench.options)])
        // Staging a suggestion takes it out of the list; it keeps its match.
        bench.stage([page.suggestions[0].track], genreKey: "techno")
        #expect(bench.page("techno").suggestions.map(\.id) == [5, 6, 7, 8])
        #expect(bench.page("techno").matchByID[4] == 96)
    }

    @Test func aReferenceWithoutAnalysisSaysSo() async throws {
        let (_, repository) = try database(analysed: [])
        let bench = GenreWorkbench(defaults: try defaults(), activity: nil)
        let source = GenreSimilaritySource { _, _, _ in
            Issue.record("no analysis, no similarity query")
            return []
        }
        bench.setReference(track(1), genreKey: "techno", genreName: "Techno", repository: repository, source: source)
        await bench.waitForSuggestions(genreKey: "techno")
        #expect(bench.page("techno").state == .notAnalysed)
        #expect(bench.page("techno").suggestions.isEmpty)
        bench.clearReference(genreKey: "techno")
        #expect(bench.page("techno").state == .noReference)
    }

    @Test func aFailedComputationSaysWhyAndANewerReferenceWins() async throws {
        let (_, repository) = try database(analysed: [1, 2])
        let bench = GenreWorkbench(defaults: try defaults(), activity: nil)
        struct Broken: Error {}
        let failing = GenreSimilaritySource { _, _, _ in throw Broken() }
        bench.setReference(track(1), genreKey: "techno", genreName: "Techno", repository: repository, source: failing)
        await bench.waitForSuggestions(genreKey: "techno")
        guard case .failed(let text) = bench.page("techno").state else {
            Issue.record("expected a failure state")
            return
        }
        #expect(text == "Couldn’t find suggestions — the library database didn’t answer.")
        let nine = track(9)
        let working = GenreSimilaritySource { _, _, _ in [GenreSimilarityCandidate(track: nine, score: 0.9)] }
        bench.setReference(track(2), genreKey: "techno", genreName: "Techno", repository: repository, source: working)
        await bench.waitForSuggestions(genreKey: "techno")
        #expect(bench.page("techno").reference?.id == 2)
        #expect(bench.page("techno").suggestions.map(\.id) == [9])
    }
}

/// A mutable value shared with a `@Sendable` closure in a test.
final class GenreTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
