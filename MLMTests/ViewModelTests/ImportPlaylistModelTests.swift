import Foundation
import GRDB
import Testing
@testable import MLM

/// S-IMPORT (W3-ADD): the three steps, the commit and what it leaves in the database. Ported
/// from the remote-playlists window's tests (`RemotePlaylistsViewModelTests`): staging without
/// writes, exactly the reviewed selection, the account list and its privacy marker.
@Suite("Import playlist sheet")
@MainActor
struct ImportPlaylistModelTests {
    struct Harness {
        let database: DatabaseQueue
        let model: ImportPlaylistModel
        let provider: FakePlaylistProvider
        let accounts: ImportTestAccounts
        let downloads: RecordingPlaylistDownloads
        let posted: Box

        var tracks: TrackRepository { TrackRepository(database: database) }
        var playlists: PlaylistRepository { PlaylistRepository(database: database) }
    }

    final class Box { var messages: [String] = [] }

    private func harness(_ source: LinkSource = .youtube, preview: RemotePlaylistPreview? = nil,
                         database: DatabaseQueue? = nil, downloadsRunning: Bool = false,
                         shuffle: @escaping ([Int]) -> [Int] = { $0 }) throws -> Harness {
        let database = try database ?? DatabaseManager.inMemory()
        let provider = FakePlaylistProvider(source, preview: preview ?? ImportFixtures.preview(source), database: database)
        let accounts = ImportTestAccounts()
        let downloads = RecordingPlaylistDownloads()
        let posted = Box()
        let environment = ImportPlaylistEnvironment(
            provider: { kind in kind.linkSource == source ? provider : nil },
            accounts: accounts,
            queries: ImportLibraryQueries(database: database),
            makeImporter: {
                PlaylistImporter(trackRepository: TrackRepository(database: database),
                                 sourceRepository: SourceRepository(database: database),
                                 playlistRepository: PlaylistRepository(database: database),
                                 queries: ImportLibraryQueries(database: database),
                                 downloads: downloads, notificationCenter: NotificationCenter())
            },
            downloadsRunning: { downloadsRunning },
            post: { text, _ in posted.messages.append(text) },
            shuffle: shuffle
        )
        return Harness(database: database, model: ImportPlaylistModel(environment: environment), provider: provider,
                       accounts: accounts, downloads: downloads, posted: posted)
    }

    private func loaded(_ h: Harness, _ source: LinkSource = .youtube) async {
        h.model.linkText = ImportFixtures.url(source)
        await h.model.loadLink()
    }

    private func commit(_ h: Harness) async {
        if h.model.step == .preview { await h.model.next() }
        h.model.importNow()
        await h.model.commitTask?.value
    }

    private func count(_ db: DatabaseQueue, _ sql: String) throws -> Int {
        try db.read { try Int.fetchOne($0, sql: sql) ?? 0 }
    }

    // MARK: Step 1 → 2

    @Test func loadingALinkStagesThePreviewWithoutWriting() async throws {
        let h = try harness()
        await loaded(h)

        #expect(h.model.step == .preview)
        #expect(h.model.preview?.title == "Late night rollers")
        #expect(h.model.selectedTracks.map(\.externalID) == ["v1", "v2", "v3"])
        #expect(try count(h.database, "SELECT COUNT(*) FROM tracks") == 0)
        #expect(try count(h.database, "SELECT COUNT(*) FROM playlists") == 0)
    }

    @Test func accountPlaylistsLoadWithPrivacyAndTheAlreadyImportedMarker() async throws {
        let h = try harness(.soundcloud)
        h.provider.summaries = [
            RemotePlaylistSummary(id: "pl-1", title: "Late night rollers", trackCount: 3),
            RemotePlaylistSummary(id: "pl-2", title: "Private edits", trackCount: 2, isPrivate: true),
        ]
        // `pl-1` was imported before.
        await loaded(h, .soundcloud)
        await commit(h)

        let again = try harness(.soundcloud, database: h.database)
        again.provider.summaries = h.provider.summaries
        again.model.selectedSource = .soundcloud
        await again.model.loadPlaylists(.soundcloud)

        #expect(again.model.visiblePlaylists.map(\.title) == ["Late night rollers", "Private edits"])
        #expect(again.model.visiblePlaylists[1].isPrivate)
        #expect(again.model.isImported(again.model.visiblePlaylists[0]))
        #expect(!again.model.isImported(again.model.visiblePlaylists[1]))
        again.model.playlistFilter = "priv"
        #expect(again.model.visiblePlaylists.map(\.id) == ["pl-2"])
    }

    @Test func aRejectedSignInSaysSoInPlaceAndTheChosenPlaylistReloadsAfterReconnecting() async throws {
        let h = try harness(.soundcloud)
        h.provider.nextError = SoundCloudClient.SoundCloudError.tokenExpired
        await loaded(h, .soundcloud)

        #expect(h.model.previewPhase == .failed(.signInExpired(.soundcloud)))
        #expect(h.accounts.expired == [.soundcloud])

        try await h.accounts.signIn(.soundcloud)
        await h.model.reloadPreview()
        #expect(h.model.preview?.externalID == "pl-1")
    }

    @Test func providerProblemsBecomeTheirOwnStates() async throws {
        let h = try harness()
        h.provider.nextError = RemotePlaylistProviderError.ytDlpUnavailable
        await loaded(h)
        #expect(h.model.previewPhase == .failed(.toolMissing))

        h.provider.nextError = RemotePlaylistProviderError.emptyPlaylist
        await h.model.reloadPreview()
        #expect(h.model.previewPhase == .failed(.empty))

        h.provider.nextError = URLError(.timedOut)
        await h.model.reloadPreview()
        guard case .failed(.didNotAnswer(let source, _)) = h.model.previewPhase else {
            Issue.record("expected didNotAnswer, got \(h.model.previewPhase)")
            return
        }
        #expect(source == "YouTube")
    }

    // MARK: Step 2: preview

    @Test func previewRowsSayNewInLibraryOrAlreadyDownloaded() async throws {
        let database = try DatabaseManager.inMemory()
        let tracks = TrackRepository(database: database)
        let sources = SourceRepository(database: database)
        let youtube = try await sources.upsert(name: "youtube", userId: "local")
        var downloaded = Track(artist: "Artist 1", album: "", title: "Track 1", format: "m4a", originalPath: "/x/1.m4a")
        downloaded.organizedPath = "Artist 1/Track 1.m4a"
        let one = try await tracks.insert(downloaded)
        let two = try await tracks.insert(Track(artist: "Artist 2", album: "", title: "Track 2", format: "youtube",
                                                originalPath: "https://example.test/youtube/v2"))
        try await sources.linkTrackToSource(trackId: one.id!, sourceId: youtube.id!, externalId: "v1")
        try await sources.linkTrackToSource(trackId: two.id!, sourceId: youtube.id!, externalId: "v2")

        let h = try harness(database: database)
        await loaded(h)
        let rows = h.model.selectedTracks.map(h.model.match)
        #expect(rows == [.downloaded(trackID: one.id!), .inLibrary(trackID: two.id!), .new])
        #expect(rows.map(\.word) == ["Already downloaded", "In library", "New"])
        #expect(h.model.summaryLine == "3 tracks · 1 new · 2 already in library")
        #expect(h.model.offersAlsoDownload)
    }

    @Test func allFirstAndRandomShowExactlyWhatWillBeImported() async throws {
        let h = try harness(preview: ImportFixtures.preview(count: 5), shuffle: { $0.reversed() })
        await loaded(h)
        #expect(h.model.importButtonTitle == "Import 5 Tracks")

        h.model.selectionMode = .first
        h.model.count = 2
        #expect(h.model.selectedTracks.map(\.externalID) == ["v1", "v2"])
        #expect(h.model.importButtonTitle == "Import 2 Tracks")

        h.model.selectionMode = .random
        // The random pick is fixed per loaded playlist and shown in playlist order.
        #expect(h.model.selectedTracks.map(\.externalID) == ["v4", "v5"])
        #expect(h.model.selectedRows.map(\.number) == [4, 5])

        h.model.count = 99
        #expect(h.model.selectedTracks.count == 5, "n is capped at the playlist's length")
    }

    // MARK: Commit

    @Test func aOneTimeImportLeavesNoLinkAndNeverWritesASourceNameAsAlbum() async throws {
        let h = try harness(.soundcloud)
        await loaded(h, .soundcloud)
        h.model.keepLinked = false
        #expect(h.model.linkValue == "Not linked (one-time import)")
        await commit(h)

        let playlist = try #require(try await h.playlists.fetchAll().first)
        #expect(playlist.sourceId == nil)
        #expect(playlist.externalId == nil)
        #expect(playlist.name == "Late night rollers")
        let tracks = try await h.playlists.fetchTracks(playlistId: playlist.id!)
        #expect(tracks.map(\.title) == ["Track 1", "Track 2", "Track 3"])
        #expect(tracks.allSatisfy { $0.album.isEmpty }, "the source name is never an album (DEC-013)")
        #expect(try count(h.database, "SELECT COUNT(*) FROM tracks WHERE album IN ('SoundCloud','YouTube','Spotify')") == 0)
        // The tracks themselves keep their source identity (the track's link, not a tag).
        #expect(try count(h.database, "SELECT COUNT(*) FROM track_sources") == 3)
    }

    @Test func aLinkedImportSetsTheLinkColumns() async throws {
        let h = try harness(.soundcloud)
        await loaded(h, .soundcloud)
        #expect(h.model.linkValue == "Linked to SoundCloud")
        await commit(h)

        let playlist = try #require(try await h.playlists.fetchAll().first)
        #expect(playlist.sourceId != nil)
        #expect(playlist.externalId == "pl-1")
    }

    @Test func reImportingAPartIntoTheLinkedPlaylistOnlyAdds() async throws {
        let h = try harness(.soundcloud)
        await loaded(h, .soundcloud)
        await commit(h)
        let playlistID = try #require(try await h.playlists.fetchAll().first?.id)

        // The source playlist grew by one; the user re-imports only the first two.
        let grown = try harness(.soundcloud, preview: ImportFixtures.preview(.soundcloud, count: 4), database: h.database)
        await loaded(grown, .soundcloud)
        #expect(grown.model.target == .existing(id: playlistID, name: "Late night rollers"))
        grown.model.selectionMode = .first
        grown.model.count = 2
        #expect(grown.model.targetNote.hasPrefix("Re-importing a part"))
        await commit(grown)

        let tracks = try await h.playlists.fetchTracks(playlistId: playlistID)
        #expect(tracks.map(\.title) == ["Track 1", "Track 2", "Track 3"], "nothing removed (was truncated to n)")
        #expect(try await h.playlists.fetchAll().count == 1)

        grown.model.selectionMode = .all
        await commit(grown)
        #expect(try await h.playlists.fetchTracks(playlistId: playlistID).map(\.title).last == "Track 4")
        #expect(try count(h.database, "SELECT COUNT(*) FROM tracks") == 4, "known tracks are not inserted twice")
    }

    @Test func aTrackListedTwiceBecomesOneLibraryTrack() async throws {
        var preview = ImportFixtures.preview(count: 2)
        preview = RemotePlaylistPreview(sourceName: preview.sourceName, externalID: preview.externalID, title: preview.title,
                                        tracks: preview.tracks + [preview.tracks[0]])
        let h = try harness(preview: preview)
        await loaded(h)
        await commit(h)
        #expect(try count(h.database, "SELECT COUNT(*) FROM tracks") == 2)
        #expect(h.downloads.started.first?.tracks.count == 2)
    }

    @Test func aSecondCopyOfALinkedPlaylistIsNotLinked() async throws {
        let h = try harness(.soundcloud)
        await loaded(h, .soundcloud)
        await commit(h)

        let again = try harness(.soundcloud, database: h.database)
        await loaded(again, .soundcloud)
        again.model.target = .newPlaylist
        #expect(!again.model.linkIsAvailable)
        #expect(!again.model.effectiveKeepLinked)
        await commit(again)

        let all = try await h.playlists.fetchAll()
        #expect(all.count == 2)
        #expect(all.filter { $0.externalId == "pl-1" }.count == 1, "one link per source playlist")
        #expect(all.contains { $0.name == "Late night rollers 2" && $0.sourceId == nil })
    }

    @Test func downloadsGoToTheLaneAsOnePlaylistOperationAndOffMeansNone() async throws {
        let h = try harness()
        await loaded(h)
        await commit(h)
        let playlist = try #require(try await h.playlists.fetchAll().first)
        #expect(h.downloads.started.count == 1)
        #expect(h.downloads.started[0].playlistID == playlist.id)
        #expect(h.downloads.started[0].name == "Late night rollers")
        #expect(h.downloads.started[0].tracks.count == 3)
        #expect(h.posted.messages.isEmpty, "a running download announces itself (UC-JOB-08)")

        let off = try harness(preview: ImportFixtures.preview(id: "pl-2", title: "Other"))
        await loaded(off)
        off.model.downloadNow = false
        #expect(off.model.downloadValue == "Not now")
        await commit(off)
        #expect(off.downloads.started.isEmpty)
        #expect(off.posted.messages == ["Imported “Other” — 3 tracks, nothing downloaded"])
    }

    @Test func anImportWhileDownloadsRunSaysItIsQueued() async throws {
        let h = try harness(downloadsRunning: true)
        await loaded(h)
        await h.model.next()
        #expect(h.model.queuedNote?.hasSuffix("This import is queued and starts when that one ends. You don’t need to wait here.") == true)
        h.model.importNow()
        await h.model.commitTask?.value
        #expect(h.posted.messages == ["Import queued — 3 tracks"])
    }

    @Test func aRunningImportSurvivesClosingTheSheet() async throws {
        let h = try harness()
        let gate = ImportTestGate()
        h.provider.sourceGate = gate
        await loaded(h)
        await h.model.next()
        h.model.importNow()
        await waitUntil { gate.isWaiting }

        // Esc / Cancel while the commit runs: the sheet closes, the import goes on.
        h.model.close()
        #expect(h.model.isFinished)
        gate.open()
        await h.model.commitTask?.value

        let playlist = try #require(try await h.playlists.fetchAll().first)
        #expect(try await h.playlists.fetchTracks(playlistId: playlist.id!).count == 3)
        #expect(h.downloads.started.count == 1)
    }

    @Test func aFailedCommitStaysInTheSheetAboveTheButtons() async throws {
        let h = try harness()
        await loaded(h)
        await h.model.next()
        let failing = ImportPlaylistModel(environment: ImportPlaylistEnvironment(
            provider: { _ in h.provider }, accounts: h.accounts, queries: nil, makeImporter: { nil }))
        failing.linkText = ImportFixtures.url(.youtube)
        await failing.loadLink()
        await failing.next()
        failing.importNow()
        #expect(failing.commitError == "Couldn’t import — the library isn’t ready yet.")
        #expect(!failing.isFinished)
    }
}

/// The download lane under two imports (PP-ACTIVITY-05): the second queues behind the first
/// and each operation names its own playlist — the sheet never shows another batch's numbers
/// (PP-SOURCES-03/09).
@Suite("Import download lane")
@MainActor
struct ImportDownloadLaneTests {
    private final class HeldRunner: DownloadBatchRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var gate: CheckedContinuation<Void, Never>?
        private var held = false

        var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return gate != nil }

        func release() {
            lock.lock(); let gate = gate; self.gate = nil; lock.unlock()
            gate?.resume()
        }

        func downloadBatch(_ requests: [DownloadOrchestrator.DownloadRequest], onProgress: ((Int, Int, String) -> Void)?,
                           onTrackProgress: ((Double) -> Void)?) async -> DownloadOrchestrator.BatchResult {
            lock.lock(); let hold = !held; held = true; lock.unlock()
            if hold { await withCheckedContinuation { c in lock.lock(); gate = c; lock.unlock() } }
            return DownloadOrchestrator.BatchResult(
                succeeded: requests.count,
                downloadedPaths: Dictionary(uniqueKeysWithValues: requests.map { ($0.trackId, "/lib/\($0.trackId).m4a") }))
        }
    }

    private struct QuietPersister: DownloadTrackPersisting {
        func markAsDownloaded(trackId: Int64, organizedPath: String, format: String, bitrate: Int?,
                              downloadStatus: String?) async throws {}
        func persistDownloadFailure(trackId: Int64, reason: String, date: Date, minimumAttempts: Int) async throws -> TrackDownloadFailure {
            TrackDownloadFailure(reason: reason, date: date, attempts: minimumAttempts)
        }
    }

    private func remote(_ id: Int64) -> Track {
        var track = Track(artist: "A", album: "", title: "T\(id)", format: "youtube", originalPath: "https://youtu.be/\(id)")
        track.id = id
        return track
    }

    @Test func aSecondImportQueuesBehindTheFirst() async throws {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let runner = HeldRunner()
        let downloads = DownloadViewModel(trackPersister: QuietPersister(), activity: center)
        downloads.batchRunnerOverride = runner
        let starter = LivePlaylistDownloadStarter(downloads: downloads)

        starter.startDownloads([remote(1), remote(2)], preferredSource: .youtube, playlistID: 10, playlistName: "First")
        await waitUntil { runner.isHeld }
        #expect(starter.hasActiveDownloads)
        starter.startDownloads([remote(3)], preferredSource: .youtube, playlistID: 11, playlistName: "Second")
        await waitUntil { center.activeOperations.count == 2 }

        let first = try #require(center.activeOperations.first { $0.subject.id == 10 })
        let second = try #require(center.activeOperations.first { $0.subject.id == 11 })
        #expect(first.state == .running)
        #expect(first.title == "Import “First”")
        #expect(second.state == .queued, "queued, not rejected")
        #expect(second.wait?.sentence == "Starts after “First”")
        #expect(center.echo(for: .playlist(11, name: "Second"))?.playlistText == "Queued · Starts after “First”")

        runner.release()
        await waitUntil { center.activeOperations.isEmpty }
    }
}
