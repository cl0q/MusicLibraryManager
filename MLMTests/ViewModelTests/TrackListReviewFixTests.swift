import Foundation
import GRDB
import Testing
@testable import MLM

/// W2-A review round: Download Again safety (S1), sort-vs-load races (S2), hidden rows and
/// removal (S5), drive-aware Play (S7), hidden kept-alive tables, context-menu keys.
@Suite("TrackListReviewFixTests")
@MainActor
struct TrackListReviewFixTests {

    private func track(_ id: Int64, title: String = "Song", path: String? = "A/song.m4a",
                       missing: Bool = false, original: String = "https://soundcloud.com/a/b") -> Track {
        var track = Track(artist: "Artist", album: "Album", title: title, format: "m4a", originalPath: original)
        track.id = id
        track.organizedPath = path
        track.fileMissingSince = missing ? "2026-10-05T10:00:00Z" : nil
        track.duration = 100
        return track
    }

    private let offline = TrackTableLiveState(offlineVolumePath: "/Volumes/Lexxar", offlineVolumeName: "Lexxar")

    // MARK: - S1 Download Again

    private struct FailingRunner: DownloadBatchRunning {
        func downloadBatch(
            _ requests: [DownloadOrchestrator.DownloadRequest],
            onProgress: ((Int, Int, String) -> Void)?,
            onTrackProgress: ((Double) -> Void)?
        ) async -> DownloadOrchestrator.BatchResult {
            DownloadOrchestrator.BatchResult(
                succeeded: 0, failed: requests.count,
                failedTrackIds: Set(requests.map(\.trackId)),
                failureReasons: Dictionary(uniqueKeysWithValues: requests.map { ($0.trackId, "Network error") })
            )
        }
    }

    private func missingRow(_ repo: TrackRepository, original: String = "https://soundcloud.com/a/b") async throws -> Int64 {
        var t = Track(artist: "Artist", album: "Album", title: "Gone", format: "m4a", originalPath: original)
        t.organizedPath = "A/gone.m4a"
        let id = try #require(try await repo.insert(t).id)
        #expect(try await repo.recordFileMissing(trackId: id))
        return id
    }

    @Test func offlineDownloadAgainChangesNothing() async throws {
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)
        let id = try await missingRow(repo)
        let before = try await repo.fetchTrack(id: id)
        let prepared = await TrackDownloadAgain.prepare(
            ids: [id], repository: repo,
            check: { _ in TrackAvailabilityReconciler.Report(outcome: .skippedRootUnreachable) },
            isFolderReachable: { false }
        )
        #expect(prepared == .notConnected)
        #expect(try await repo.fetchTrack(id: id) == before, "the stored path stays")
        #expect(TrackDownloadAgain.notConnectedMessage("Lexxar") == "Can’t download — “Lexxar” is not connected")
        // A disk pulled between the check and the action.
        let late = await TrackDownloadAgain.prepare(
            ids: [id], repository: repo,
            check: { _ in TrackAvailabilityReconciler.Report(outcome: .completed) },
            isFolderReachable: { false }
        )
        #expect(late == .notConnected)
        let stopped = await TrackDownloadAgain.prepare(
            ids: [id], repository: repo,
            check: { _ in TrackAvailabilityReconciler.Report(outcome: .abortedSuspicious) },
            isFolderReachable: { true }
        )
        #expect(stopped == .checkStopped)
    }

    @Test func aFailedDownloadKeepsTheStoredPath() async throws {
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)
        let id = try await missingRow(repo)
        let prepared = await TrackDownloadAgain.prepare(
            ids: [id], repository: repo,
            check: { _ in TrackAvailabilityReconciler.Report(outcome: .completed) },
            isFolderReachable: { true }
        )
        guard case .ready(let tracks) = prepared else {
            Issue.record("expected tracks to download, got \(prepared)")
            return
        }
        #expect(tracks.map(\.id) == [id])
        #expect(tracks[0].organizedPath == nil, "only the in-memory copy has no path")
        #expect(try await repo.fetchTrack(id: id)?.organizedPath == "A/gone.m4a", "nothing written before the download")

        let downloads = DownloadViewModel(trackRepository: repo)
        downloads.batchRunnerOverride = FailingRunner()
        await downloads.downloadTracks(tracks)
        let after = try #require(try await repo.fetchTrack(id: id))
        #expect(after.organizedPath == "A/gone.m4a")
        #expect(after.fileMissingSince != nil)
        #expect(after.availability() == .fileMissing, "a failed download leaves the row File missing")
    }

    @Test func aRowWithoutASourceOffersNoDownloadAgain() async throws {
        let imported = track(1, missing: true, original: "/Users/o/Music/import.m4a")
        let reel = track(2, missing: true, original: "reels:///Users/o/Movies/x.mov")
        let unknown = track(3, missing: true, original: "something://x")
        for row in [imported, reel, unknown] {
            #expect(!TrackLinks.hasSource(row), "\(row.originalPath)")
            let model = TrackMenuModel.make(
                subject: TrackMenuSubject(rows: TrackRowBuilder.build([row]), live: .idle),
                context: TrackMenuContext(container: .library, canActivate: true, canRemoveFromContainer: false, canAddToSyncProfile: true))
            #expect(!model.items.contains(.downloadAgain))
        }
        for original in ["https://youtube.com/watch?v=x", "soundcloud://123", "spotify://track/abc", "dab://9"] {
            #expect(TrackLinks.hasSource(track(9, original: original)), "\(original)")
        }
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)
        let id = try await missingRow(repo, original: "/Users/o/import.m4a")
        let prepared = await TrackDownloadAgain.prepare(
            ids: [id], repository: repo,
            check: { _ in TrackAvailabilityReconciler.Report(outcome: .completed) },
            isFolderReachable: { true }
        )
        #expect(prepared == .nothingMissing)
    }

    // MARK: - S2 sort vs load

    private func bigList(_ count: Int, prefix: String) -> [Track] {
        (1...count).map { track(Int64($0), title: "\(prefix) \(String(format: "%05d", count - $0))") }
    }

    @Test func aSortDuringABigLoadSortsTheNewRows() async {
        let model = TrackListModel(sortOrder: nil)
        let tracks = bigList(TrackListModel.backgroundThreshold + 500, prefix: "T")
        let load = Task { await model.setTracks(tracks) }
        await Task.yield()
        await model.setSortOrder(TrackSortOrder(column: .title, ascending: true))
        await load.value
        #expect(model.isLoaded)
        #expect(model.rows.count == tracks.count, "the load is not dropped by the sort")
        #expect(model.rows.first?.title == "T 00000")
    }

    @Test func aStoredSortBeforeTheFirstLoadShowsNoFalseEmptyState() async {
        let model = TrackListModel(sortOrder: nil)
        await model.setSortOrder(TrackSortOrder(column: .title, ascending: false))
        #expect(!model.isLoaded, "placeholders stay until rows arrive")
        #expect(model.rows.isEmpty)
        await model.setTracks([track(1, title: "a"), track(2, title: "b")])
        #expect(model.rows.map(\.id) == [2, 1])
    }

    @Test func aHeaderClickDuringARefreshKeepsTheRefresh() async {
        let model = TrackListModel(sortOrder: TrackSortOrder(column: .title, ascending: true))
        await model.setTracks([track(1, title: "old")])
        let fresh = bigList(TrackListModel.backgroundThreshold + 10, prefix: "N")
        let refresh = Task { await model.setTracks(fresh) }
        await Task.yield()
        await model.setSortOrder(TrackSortOrder(column: .title, ascending: false))
        await refresh.value
        #expect(model.rows.count == fresh.count)
        #expect(model.rows.first?.title.hasPrefix("N ") == true)
        #expect(model.sortOrder == TrackSortOrder(column: .title, ascending: false))
    }

    @Test func playlistsSortPerPlaylist() {
        let a = TrackListConfiguration.playlist(id: 1, name: "A", activate: nil, remove: { _ in }, onInsert: nil)
        let b = TrackListConfiguration.playlist(id: 2, name: "B", activate: nil, remove: { _ in }, onInsert: nil)
        #expect(a.persistenceKey == b.persistenceKey, "one column set for all playlists")
        #expect(a.sortPersistenceKey == "playlist.1" && b.sortPersistenceKey == "playlist.2")
        #expect(a.defaultSort == TrackSortOrder(column: .number, ascending: true))
    }

    // MARK: - S5 hidden rows are never removed

    @Test func onlyShownSelectedRowsAreRemoved() async {
        let model = TrackListModel(sortOrder: TrackSortOrder(column: .number, ascending: true))
        await model.setTracks([track(1), track(2), track(3)])
        model.selection = [1, 2, 3]
        await model.setTracks([track(1), track(2), track(3)], visibleIDs: [1, 3])  // a search hides 2
        #expect(model.selection == [1, 2, 3], "the selection survives the filter")
        #expect(Set(model.selectedRows().map(\.id)) == [1, 3], "⌫ / Remove n act on these only")
    }

    // MARK: - S7 Play while the disk is away

    @Test func playIsOffWhileTheDiskIsAway() async {
        let model = TrackListModel()
        await model.setTracks([track(1), track(2, path: nil)])
        #expect(model.hasPlayableRows(live: .idle))
        #expect(!model.hasPlayableRows(live: offline))
        #expect(offline.cantPlayReason == "Can’t play — “Lexxar” is not connected")
        let elsewhere = TrackListModel()
        await elsewhere.setTracks([track(3, path: "/Users/o/Music/x.m4a")])
        #expect(elsewhere.hasPlayableRows(live: offline), "a file on another disk can still play")
    }

    // MARK: - Hidden kept-alive table

    @Test func theHiddenAllTracksTablePublishesNothing() {
        #expect(TrackTableVisibility.isVisible(isAllTracksTable: true, allTracksVisible: true, isSearching: false))
        #expect(!TrackTableVisibility.isVisible(isAllTracksTable: true, allTracksVisible: false, isSearching: false))
        #expect(!TrackTableVisibility.isVisible(isAllTracksTable: true, allTracksVisible: true, isSearching: true))
        #expect(TrackTableVisibility.isVisible(isAllTracksTable: false, allTracksVisible: false, isSearching: false))
    }

    // MARK: - Empty path = no file, everywhere

    @Test func anEmptyPathIsNoFileInEveryCount() async throws {
        let db = try DatabaseManager.inMemory()
        let repo = TrackRepository(database: db)
        var empty = Track(artist: "A", album: "B", title: "Empty", format: "m4a", originalPath: "/e.m4a")
        empty.organizedPath = ""
        var local = Track(artist: "A", album: "B", title: "Local", format: "m4a", originalPath: "/l.m4a")
        local.organizedPath = "A/l.m4a"
        _ = try await repo.insert(empty)
        _ = try await repo.insert(local)
        let split = try await repo.countTracksByAvailability()
        #expect(split.local == 1 && split.remote == 1)
        #expect(try await repo.libraryTotals(tab: .local).count == 1)
        #expect(try await repo.libraryTotals(tab: .remote).count == 1)
        #expect(try await repo.fetchForLibrary(tab: .remote, search: nil, sortBy: .title, ascending: true).map(\.title) == ["Empty"])
        #expect(try await repo.availabilityCounts().notDownloaded == 1)
        #expect(!empty.isLocal && empty.isRemote && empty.availability() == .notDownloaded)
    }

    // MARK: - Mount observer teardown

    @Test func aReplacedMountObserverIsStoppedForGood() throws {
        let container = DependencyContainer(snapshotDatabase: try DatabaseManager.inMemory())
        container.applyLibraryRoot(FileManager.default.temporaryDirectory.path, startMonitoring: true)
        let first = try #require(container.mountObserver)
        #expect(first.isMonitoring)
        container.applyLibraryRoot("/Volumes/NoSuchDisk-\(UUID().uuidString)/Music", startMonitoring: false)
        #expect(!first.isMonitoring, "stopped and unregistered — nothing is kept alive or posts later")
        #expect(container.mountObserver !== first)
        container.mountObserver?.stop()
    }
}
