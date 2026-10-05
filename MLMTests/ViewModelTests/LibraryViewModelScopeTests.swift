import Foundation
import GRDB
import Testing
@testable import MLM

/// All Tracks with the availability scope bar (W2-B): rows, counts and totals per scope from
/// SQL, the selection kept across scopes, in-place updates — on temporary databases only.
@MainActor
@Suite("LibraryViewModelScopeTests")
struct LibraryViewModelScopeTests {
    private struct Fixture {
        let db: DatabaseQueue
        let repo: TrackRepository
        let model: LibraryViewModel
        var ids: [String: Int64]
    }

    private static let failureJSON = try! TrackDownloadFailure(
        reason: "Authentication expired — re-authorize and retry", date: Date(timeIntervalSince1970: 1_720_000_000), attempts: 1
    ).encodedJSON()

    private func makeFixture(empty: Bool = false) async throws -> Fixture {
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)
        var ids: [String: Int64] = [:]
        if !empty {
            // title: (organized_path, missing, status, failure, duration)
            let rows: [(String, String?, String?, String?, String?, Int)] = [
                ("Local One", "A/1.m4a", nil, nil, nil, 200),
                ("Local Two", "A/2.m4a", nil, nil, nil, 300),
                ("Gone", "A/3.m4a", "2026-10-05T10:00:00Z", nil, nil, 400),
                ("Linked", nil, nil, "remote", nil, 100),
                ("Busy", nil, nil, "downloading", nil, 50),
                ("Broken", nil, nil, "failed", Self.failureJSON, 70),
            ]
            for row in rows {
                var track = Track(artist: "Artist", album: "Album", title: row.0, format: "m4a",
                                  originalPath: "https://soundcloud.com/a/\(row.0)")
                track.organizedPath = row.1
                track.downloadStatus = row.3
                track.downloadFailure = row.4
                track.duration = row.5
                let inserted = try await repo.insert(track)
                let id = try #require(inserted.id)
                ids[row.0] = id
                if let missing = row.2 {
                    try await db.write { db in
                        try db.execute(sql: "UPDATE tracks SET file_missing_since = ? WHERE id = ?", arguments: [missing, id])
                    }
                }
            }
        }
        let model = LibraryViewModel(
            trackRepository: repo,
            configRepository: ConfigRepository(database: db),
            scopeQueries: TrackScopeQueries(database: db)
        )
        return Fixture(db: db, repo: repo, model: model, ids: ids)
    }

    private func titles(_ model: LibraryViewModel) -> Set<String> {
        Set(model.displayedTracks.map(\.title))
    }

    @Test func eachScopeShowsItsRowsCountsAndTotals() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        await model.loadTracks()
        #expect(model.counts?.all == 6)
        #expect(model.libraryTrackCount == 6)
        #expect(model.totals == TrackListTotals(count: 6, duration: 1_120))

        let expected: [TrackAvailabilityScope: Set<String>] = [
            .local: ["Local One", "Local Two"],
            .notDownloaded: ["Linked", "Busy"],     // downloading counts here (IMP-021)
            .downloadFailed: ["Broken"],
            .fileMissing: ["Gone"],
            .all: ["Local One", "Local Two", "Gone", "Linked", "Busy", "Broken"],
        ]
        for (scope, titles) in expected {
            model.scope = scope
            await model.refresh()
            #expect(self.titles(model) == titles, "\(scope)")
            #expect(model.counts?.count(for: scope) == titles.count, "\(scope) count")
            #expect(model.totals?.count == titles.count, "\(scope) status bar count")
        }
        model.scope = .local
        await model.refresh()
        #expect(model.totals == TrackListTotals(count: 2, duration: 500))
    }

    /// UC-TABLE-08: the selection survives a scope switch; rows outside the scope are not
    /// shown (and not acted on) but come back selected.
    @Test func switchingScopeKeepsTheSelection() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        await model.loadTracks()
        let local = try #require(fixture.ids["Local One"])
        let failed = try #require(fixture.ids["Broken"])
        model.selectedTrackIDs = [local, failed]

        model.scope = .downloadFailed
        await model.refresh()
        #expect(model.selectedTrackIDs == [local, failed])
        #expect(model.selectedTracks.map(\.id) == [failed], "commands act on shown rows only")

        model.scope = .all
        await model.refresh()
        #expect(Set(model.selectedTracks.compactMap(\.id)) == [local, failed])
    }

    @Test func searchCombinesWithTheScopeAndTheLibrarySizeIgnoresIt() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        model.scope = .local
        model.searchQuery = "two"
        await model.refresh()
        #expect(titles(model) == ["Local Two"])
        #expect(model.counts?.all == 1)
        #expect(model.counts?.local == 1)
        #expect(model.totals == TrackListTotals(count: 1, duration: 300))
        #expect(model.libraryTrackCount == 6)
        #expect(!model.isLibraryEmpty)
    }

    @Test func removalUpdatesRowsAndCountsInPlace() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        await model.loadTracks()
        let gone = try #require(fixture.ids["Linked"])
        try await fixture.repo.delete(ids: [gone])
        model.removeTracks(ids: [gone])
        await model.waitForSummary()
        #expect(!titles(model).contains("Linked"))
        #expect(model.counts?.all == 5)
        #expect(model.counts?.notDownloaded == 1)
        #expect(model.libraryTrackCount == 5)
    }

    @Test func refreshPicksUpNewFailuresInPlace() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        model.scope = .downloadFailed
        await model.loadTracks()
        #expect(titles(model) == ["Broken"])
        let linked = try #require(fixture.ids["Linked"])
        _ = try await fixture.repo.persistDownloadFailure(trackId: linked, reason: "Video unavailable")
        await model.refresh()
        #expect(titles(model) == ["Broken", "Linked"])
        #expect(model.counts?.failed == 2)
        // The second line, in plain words (UC-TABLE-13).
        let row = try #require(model.list.row(id: linked))
        #expect(row.failureDetail == "No match found on any source · 2 attempts left")
        let broken = try #require(model.list.row(id: fixture.ids["Broken"] ?? -1))
        #expect(broken.failureDetail == "Sign-in expired (SoundCloud) · 2 attempts left")
    }

    @Test func goToCurrentTrackKeepsAScopeThatListsTheTrack() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        model.scope = .downloadFailed
        let failed = try #require(fixture.ids["Broken"])
        model.reveal(trackID: failed, availability: .failed(reason: "", date: .distantPast, attempts: 1))
        #expect(model.scope == .downloadFailed)
        #expect(model.selectedTrackIDs == [failed])
        let local = try #require(fixture.ids["Local One"])
        model.reveal(trackID: local, availability: .local)
        #expect(model.scope == .all)
        #expect(model.selectedTrackIDs == [local])
    }

    @Test func anEmptyLibraryIsKnownAfterTheFirstLoad() async throws {
        let fixture = try await makeFixture(empty: true)
        let model = fixture.model
        #expect(!model.isLibraryEmpty, "unknown before the first load — no false empty state")
        await model.loadTracks()
        #expect(model.isLibraryEmpty)
        #expect(model.isLoaded)
        #expect(model.displayedTracks.isEmpty)
    }

    @Test func allTracksOffersTheFiveGlossaryScopesInOrder() {
        let counts = TrackAvailabilityCounts(all: 10, local: 4, notDownloaded: 3, downloading: 1, failed: 2, fileMissing: 1)
        let items = AllTracksScopeBar.items(counts: counts)
        #expect(items.map(\.title) == ["All", "Local", "Not downloaded", "Download failed", "File missing"])
        #expect(items.map(\.count) == [10, 4, 3, 2, 1])
        #expect(items.allSatisfy { !$0.hidesWhenEmpty }, "All Tracks shows every scope (UC-SCOPE-02)")
        // Before the first load: the words only.
        #expect(AllTracksScopeBar.items(counts: nil).allSatisfy { $0.count == nil })
    }

    @Test func emptyScopesSayWhatTheScopeMeans() {
        #expect(AllTracksScopeEmptyState(scope: .all) == nil)
        #expect(AllTracksScopeEmptyState(scope: .downloadFailed)?.title == "No tracks with failed downloads")
        #expect(AllTracksScopeEmptyState(scope: .notDownloaded)?.title == "Every track is downloaded")
        #expect(AllTracksScopeEmptyState(scope: .fileMissing)?.title == "No missing files")
        #expect(AllTracksScopeEmptyState(scope: .local)?.title == "No local tracks")
        for scope in TrackAvailabilityScope.allCases {
            if let title = AllTracksScopeEmptyState(scope: scope)?.title {
                #expect(!title.hasSuffix("."), "\(title): a title, not a sentence")
                #expect(!title.contains("Remote"), "\(title): retired word")
            }
        }
    }

    /// The view is a pure table: no header buttons, no Local/Remote tabs, no "Remote" word
    /// (DEC-048, DEC-011, §15.4); Scan and Shuffle stay reachable from the menu bar.
    @Test func allTracksIsAPureTable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("MLM/Views/Library/LibraryView.swift"), encoding: .utf8)
        for banned in ["Remote", "Picker(", "Label(\"Shuffle\"", "ScanLibraryFolderButton", "rescan_button",
                       "playShuffled", "scanLibraryFolder()"] {
            #expect(!view.contains(banned), "LibraryView still contains \(banned)")
        }
        let model = try String(contentsOf: root.appendingPathComponent("MLM/ViewModels/LibraryViewModel.swift"), encoding: .utf8)
        #expect(!model.contains("LibraryTab") && !model.contains("remoteCount"), "the tab state is gone")
        #expect(MenuCommand.shuffleView.wiring == .app && MenuCommand.playView.wiring == .app)
        #expect(MenuCommand.refreshFromSource.shortcut == .cmd("r"))
        #expect(MenuCommand.filter.wiring == .app)
    }
}
