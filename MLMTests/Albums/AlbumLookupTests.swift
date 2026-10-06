import Foundation
import GRDB
import Testing
@testable import MLM

/// `TagAlbumSuggester` (IMP-082) and `AlbumLookupRunner` (IMP-083). Names and temporary
/// databases only; no file is read, nothing touches the network.
@Suite("AlbumLookupTests")
@MainActor
struct AlbumLookupTests {
    typealias Rows = [(artist: String, albumArtist: String, album: String, year: Int?)]

    // MARK: Helpers

    static func track(_ artist: String = "Overmono", title: String = "Song", path: String? = nil) -> Track {
        var track = Track(artist: artist, album: "", title: title, format: "flac", originalPath: "/orig/\(title).flac")
        track.organizedPath = path
        return track
    }

    static func suggest(_ track: Track, root: String? = "/lib", index: ArtistAlbumIndex = ArtistAlbumIndex()) async throws -> [AlbumSuggestion] {
        try await TagAlbumSuggester().suggest(for: track, context: AlbumSuggestionContext(libraryRoot: root, index: index))
    }

    // MARK: Library tags

    @Test func libraryTagsScoreByTheShareOfTheArtistsTracks() async throws {
        var rows: Rows = []
        for _ in 0..<3 { rows.append((artist: "Overmono", albumArtist: "", album: "Good Lies", year: 2022)) }
        rows.append((artist: "OVERMONO", albumArtist: "", album: "Cooley High", year: nil))
        rows.append((artist: "Someone Else", albumArtist: "", album: "Elsewhere", year: nil))
        let result = try await Self.suggest(Self.track(), index: ArtistAlbumIndex(tracks: rows))
        #expect(result.map(\.albumTitle) == ["Good Lies", "Cooley High"], "case-folded artist, best first, other artists ignored")
        #expect(result[0].source == "Library tags")
        #expect(result[0].match == 50 + 45 * 0.75)
        #expect(result[1].match == 50 + 45 * 0.25)
        #expect(result[0].year == 2022)
    }

    @Test func aSingleAlbumIsCappedAtNinetyFive() async throws {
        let rows: Rows = [(artist: "Overmono", albumArtist: "", album: "Only", year: nil)]
        let result = try await Self.suggest(Self.track(), index: ArtistAlbumIndex(tracks: rows))
        #expect(result.first?.match == 95)
    }

    @Test func tracksWithoutARealAlbumDoNotCount() {
        let rows: Rows = [
            (artist: "Overmono", albumArtist: "", album: "SoundCloud", year: nil),
            (artist: "Overmono", albumArtist: "", album: "unknown album", year: nil),
            (artist: "Overmono", albumArtist: "", album: "", year: nil),
        ]
        #expect(ArtistAlbumIndex(tracks: rows).albums(of: "Overmono").isEmpty)
    }

    @Test func nfcAndNfdArtistsAreOneArtist() {
        let rows: Rows = [
            (artist: "Beyonc\u{e9}", albumArtist: "", album: "Lemonade", year: nil),
            (artist: "Beyonce\u{301}", albumArtist: "", album: "lemonade", year: nil),
        ]
        #expect(ArtistAlbumIndex(tracks: rows).albums(of: "BEYONC\u{c9}").map(\.tracks) == [2])
    }

    // MARK: Folder name

    @Test func aFolderUnderTheArtistIsNinety() async throws {
        let result = try await Self.suggest(Self.track(path: "Overmono/Good Lies/01 - So U Know.flac"))
        let folder = try #require(result.first)
        #expect(result.count == 1)
        #expect(folder.albumTitle == "Good Lies")
        #expect(folder.match == 90 && folder.source == "Folder name")
        #expect(folder.trackNumber == 1, "the number of `01 - Title` rides along")
    }

    @Test func aFolderUnderAnotherFolderIsEighty() async throws {
        let result = try await Self.suggest(Self.track(path: "Compilations/Warehouse Nights/Song.flac"))
        #expect(result.map(\.albumTitle) == ["Warehouse Nights"])
        #expect(result[0].match == 80 && result[0].source == "Folder name")
        #expect(result[0].trackNumber == nil)
    }

    @Test func theArtistsOwnFolderAndGenericFoldersAreNotAlbums() async throws {
        let own = try await Self.suggest(Self.track(path: "Overmono/Song.flac"))
        let downloads = try await Self.suggest(Self.track(path: "Downloads/Song.flac"))
        let source = try await Self.suggest(Self.track(path: "SoundCloud/Song.flac"))
        let flat = try await Self.suggest(Self.track(path: "Song.flac"))
        #expect(own.isEmpty && downloads.isEmpty && source.isEmpty && flat.isEmpty)
    }

    @Test func absolutePathsCountOnlyInsideTheLibraryFolder() async throws {
        let inside = try await Self.suggest(Self.track(path: "/lib/Overmono/Good Lies/Song.flac"), root: "/lib")
        #expect(inside.first?.albumTitle == "Good Lies")
        let outside = try await Self.suggest(Self.track(path: "/elsewhere/Overmono/Good Lies/Song.flac"), root: "/lib")
        #expect(outside.isEmpty)
        let none = try await Self.suggest(Self.track(path: nil))
        #expect(none.isEmpty, "no file, no names")
    }

    // MARK: File name

    @Test func artistAlbumNumberTitleIsEightyFive() async throws {
        let result = try await Self.suggest(Self.track(path: "Overmono - Good Lies - 04 Feel Good.flac"))
        #expect(result == [AlbumSuggestion(albumTitle: "Good Lies", albumArtist: "", year: nil, trackNumber: 4, disc: nil,
                                           source: "File name", match: 85)])
    }

    @Test func aNumberedFileUsesItsFolderAsTheAlbumAndMergesWithTheFolderCandidate() async throws {
        let result = try await Self.suggest(Self.track(path: "Mixes/Warehouse Nights/07. Song.flac"))
        #expect(result.count == 1, "the folder and file-name candidates are one album")
        #expect(result[0].albumTitle == "Warehouse Nights")
        #expect(result[0].match == 80 && result[0].source == "Folder name", "the better source wins")
        #expect(result[0].trackNumber == 7)
    }

    @Test func leadingNumbers() {
        #expect(TagAlbumSuggester.leadingNumber(of: "03 - Title")?.value == 3)
        #expect(TagAlbumSuggester.leadingNumber(of: "3. Title")?.rest == "Title")
        #expect(TagAlbumSuggester.leadingNumber(of: "12 Title")?.value == 12)
        #expect(TagAlbumSuggester.leadingNumber(of: "1999") == nil)
        #expect(TagAlbumSuggester.leadingNumber(of: "Title 03") == nil)
    }

    @Test func differentEvidenceForOneAlbumKeepsTheBestAndTheNumber() async throws {
        let rows: Rows = [(artist: "Overmono", albumArtist: "Overmono", album: "Good Lies", year: 2022)]
        let result = try await Self.suggest(Self.track(path: "Overmono/Good Lies/02 - Song.flac"), index: ArtistAlbumIndex(tracks: rows))
        #expect(result.count == 1)
        #expect(result[0].match == 95 && result[0].source == "Library tags")
        #expect(result[0].trackNumber == 2 && result[0].year == 2022 && result[0].albumArtist == "Overmono")
    }

    @Test func noEvidenceMeansNoSuggestion() async throws {
        let result = try await Self.suggest(Self.track(path: "Song.flac"))
        #expect(result.isEmpty)
    }

    // MARK: Runner

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ title: String) -> Int { lock.withLock { stored.append(title); return stored.count } }
        var titles: [String] { lock.withLock { stored } }
    }

    final class RunnerBox: @unchecked Sendable {
        var runner: AlbumLookupRunner?
    }

    struct ScriptedSuggester: AlbumSuggesting {
        let counter: Counter
        let found: Set<String>
        var onTrack: @Sendable (Int) async -> Void = { _ in }
        func suggest(for track: Track, context: AlbumSuggestionContext) async throws -> [AlbumSuggestion] {
            let count = counter.add(track.title)
            await onTrack(count)
            guard found.contains(track.title) else { return [] }
            return [AlbumSuggestion(albumTitle: "Album of \(track.title)", source: "Folder name", match: 80)]
        }
    }

    struct Env {
        let db: DatabaseQueue
        let center: ActivityCenter
        let repository: AlbumSuggestionRepository
        let config: ConfigRepository
    }

    static func env(tracks: Int) async throws -> Env {
        let db = try DatabaseManager.inMemory()
        try await db.write { db in
            for index in 0..<tracks { try AlbumTracksMigrationTests.insertTrack(db, title: "T\(index)", album: "") }
        }
        return Env(db: db, center: ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0),
                   repository: AlbumSuggestionRepository(database: db), config: ConfigRepository(database: db))
    }

    static func runner(_ env: Env, suggester: any AlbumSuggesting, at date: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> AlbumLookupRunner {
        AlbumLookupRunner(center: env.center, repository: { env.repository }, libraryRoot: { "/lib" }, config: { env.config },
                          suggester: suggester, now: { date }, didChange: {})
    }

    @Test func aRunFilesASuggestionOrNoMatchForEveryTrack() async throws {
        let env = try await Self.env(tracks: 5)
        let runner = Self.runner(env, suggester: ScriptedSuggester(counter: Counter(), found: ["T0", "T2"]))
        #expect(runner.start())
        await runner.waitUntilIdle()
        let counts = try await env.repository.counts()
        #expect(counts.pending == 2 && counts.noMatch == 3 && counts.rows == 5)
        let finished = try #require(env.center.finishedOperations.first { $0.kind == .albumLookup })
        #expect(finished.state == .completed)
        #expect(finished.title == "Looking up albums")
        #expect(finished.subject == .review)
        #expect(finished.result?.sentence == "2 suggestions · 3 no match")
        #expect(runner.lastOutcome == AlbumLookupRunner.Outcome(processed: 5, suggestions: 2, noMatch: 3, cancelled: false))
    }

    @Test func aFinishedRunStoresTheLastLookupDate() async throws {
        let env = try await Self.env(tracks: 2)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let runner = Self.runner(env, suggester: ScriptedSuggester(counter: Counter(), found: []), at: date)
        await runner.loadLastLookup()
        #expect(runner.lastLookup == nil && runner.hasLoadedLastLookup)
        runner.start()
        await runner.waitUntilIdle()
        #expect(runner.lastLookup?.date == date)
        let reloaded = await AlbumLastLookup.load(from: env.config)
        #expect(reloaded?.date == date)
    }

    @Test func aRunWithNothingToDoDoesNotClaimALookup() async throws {
        let env = try await Self.env(tracks: 0)
        let runner = Self.runner(env, suggester: ScriptedSuggester(counter: Counter(), found: []))
        runner.start()
        await runner.waitUntilIdle()
        #expect(runner.lastLookup == nil)
    }

    @Test func cancelKeepsTheRowsAndTheNextRunResumesWithoutLookingAtThemAgain() async throws {
        let env = try await Self.env(tracks: 8)
        let box = RunnerBox()
        let first = ScriptedSuggester(counter: Counter(), found: ["T0", "T1", "T2", "T3", "T4", "T5", "T6", "T7"], onTrack: { count in
            if count == 3 { await MainActor.run { box.runner?.cancel() } }
        })
        let runner = Self.runner(env, suggester: first)
        box.runner = runner
        runner.start()
        await runner.waitUntilIdle()
        let finished = try #require(env.center.finishedOperations.first { $0.kind == .albumLookup })
        #expect(finished.state == .cancelled)
        let kept = try await env.repository.counts().rows
        #expect(kept >= 2 && kept < 8, "rows done before the stop stay (got \(kept))")
        #expect(runner.lastOutcome?.cancelled == true)

        let secondCounter = Counter()
        let resumed = Self.runner(env, suggester: ScriptedSuggester(counter: secondCounter, found: []))
        resumed.start()
        await resumed.waitUntilIdle()
        #expect(secondCounter.titles.count == 8 - kept, "only the tracks without a row are looked up")
        let rows = try await env.repository.counts().rows
        #expect(rows == 8)
    }

    @Test func aSecondStartWhileRunningDoesNothing() async throws {
        let env = try await Self.env(tracks: 1)
        let runner = Self.runner(env, suggester: ScriptedSuggester(counter: Counter(), found: []))
        #expect(runner.start())
        #expect(!runner.start())
        #expect(runner.blockedReason == "A lookup is running — see Activity.")
        await runner.waitUntilIdle()
        #expect(runner.blockedReason == nil)
        #expect(env.center.finishedOperations.filter { $0.kind == .albumLookup }.count == 1)
    }

    @Test func theProviderFailingForATrackLeavesItWithoutARow() async throws {
        struct Failing: AlbumSuggesting {
            func suggest(for track: Track, context: AlbumSuggestionContext) async throws -> [AlbumSuggestion] {
                if track.title == "T1" { throw CocoaError(.fileReadUnknown) }
                return []
            }
        }
        let env = try await Self.env(tracks: 3)
        let runner = Self.runner(env, suggester: Failing())
        runner.start()
        await runner.waitUntilIdle()
        let counts = try await env.repository.counts()
        let remaining = try await env.repository.candidateCount()
        #expect(counts.rows == 2)
        #expect(remaining == 1, "looked up again next time")
    }

    @Test func libraryFindAlbumsIsWiredToTheLookup() {
        #expect(!MenuCommand.findAlbums.isPending, "Library ▸ Find Albums starts the lookup (W4-3)")
        #expect(MenuCommand.findAlbums.title == "Find Albums")
    }

    @Test func theIndexIsBuiltFromTracksWithARealAlbum() async throws {
        let env = try await Self.env(tracks: 0)
        try await env.db.write { db in
            try AlbumTracksMigrationTests.insertTrack(db, title: "a", album: "Good Lies")
            try AlbumTracksMigrationTests.insertTrack(db, title: "b", album: "SoundCloud")
            try AlbumTracksMigrationTests.insertTrack(db, title: "c", album: "")
        }
        let index = try await AlbumLookupRunner.buildIndex(env.repository)
        #expect(index.albums(of: "Overmono").map(\.title) == ["Good Lies"])
    }
}
