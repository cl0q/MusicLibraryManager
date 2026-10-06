import Foundation
import GRDB
import Testing
@testable import MLM

/// W5-F1 step 2: the sidebar and artwork backfill follow `.trackMetadataDidChange`. Each test
/// uses its own `NotificationCenter`, so no traffic from other suites can reach it.

/// Counts reload calls; the first one waits until the test opens the gate.
private actor ReloadGate {
    private(set) var count = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var opened = false

    func begin(blockFirst: Bool) async {
        count += 1
        if blockFirst, count == 1, !opened {
            await withCheckedContinuation { gate = $0 }
        }
    }

    func open() {
        opened = true
        gate?.resume()
        gate = nil
    }
}

@MainActor
@Suite("Metadata observers (W5-F1)", .serialized)
struct MetadataObserverTests {
    private func waitUntil(_ what: String, _ condition: () async -> Bool) async {
        for _ in 0..<5000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("timed out waiting for \(what)")
    }

    // MARK: Sidebar

    @Test func theSidebarReloadsWhenTagsChange() async {
        let center = NotificationCenter()
        let model = SidebarModel(defaults: UserDefaults(suiteName: "mlm.tests.sidebar.\(UUID().uuidString)")!)
        let gate = ReloadGate()
        model.observeMetadataChanges(notificationCenter: center) { await gate.begin(blockFirst: false) }
        center.post(name: .trackMetadataDidChange, object: nil)
        await waitUntil("the reload") { await gate.count == 1 }
        #expect(await gate.count == 1)
    }

    @Test func postsDuringAReloadCoalesceIntoOneMoreReload() async {
        let center = NotificationCenter()
        let model = SidebarModel(defaults: UserDefaults(suiteName: "mlm.tests.sidebar.\(UUID().uuidString)")!)
        let gate = ReloadGate()
        model.observeMetadataChanges(notificationCenter: center) { await gate.begin(blockFirst: true) }
        center.post(name: .trackMetadataDidChange, object: nil)
        await waitUntil("the first reload") { await gate.count == 1 }
        center.post(name: .trackMetadataDidChange, object: nil)
        center.post(name: .trackMetadataDidChange, object: nil)
        center.post(name: .trackMetadataDidChange, object: nil)
        await gate.open()
        await waitUntil("the coalesced reload") { await gate.count == 2 }
        // The loop is idle again: one more post is one more reload, nothing was left over.
        center.post(name: .trackMetadataDidChange, object: nil)
        await waitUntil("the next reload") { await gate.count >= 3 }
        #expect(await gate.count == 3)
    }

    @Test func aStoppedSidebarIgnoresTagChanges() async {
        let center = NotificationCenter()
        let model = SidebarModel(defaults: UserDefaults(suiteName: "mlm.tests.sidebar.\(UUID().uuidString)")!)
        let gate = ReloadGate()
        model.observeMetadataChanges(notificationCenter: center) { await gate.begin(blockFirst: false) }
        model.stopObservingMetadataChanges()
        center.post(name: .trackMetadataDidChange, object: nil)
        // A second, live subscription proves the post was delivered and handled before we look.
        let probe = ReloadGate()
        model.observeMetadataChanges(notificationCenter: center) { await probe.begin(blockFirst: false) }
        center.post(name: .trackMetadataDidChange, object: nil)
        await waitUntil("the probe") { await probe.count == 1 }
        #expect(await gate.count == 0)
    }

    // MARK: Artwork backfill

    private func makeBackfill() throws -> (DatabaseQueue, ArtworkBackfillService, NotificationCenter, AnalysisRepository) {
        let database = try DatabaseManager.inMemory()
        let center = NotificationCenter()
        let analysis = AnalysisRepository(database: database)
        let service = ArtworkBackfillService(
            database: database,
            trackRepository: TrackRepository(database: database),
            analysisRepository: analysis,
            configRepository: ConfigRepository(database: database),
            notificationCenter: center
        )
        return (database, service, center, analysis)
    }

    private func insertTrack(_ database: DatabaseQueue, _ title: String, withSentinel: Bool) async throws -> Int64 {
        try await database.write { db in
            var track = Track(artist: "Artist", album: "Album", title: title, format: "m4a",
                              originalPath: "/nonexistent/\(title).m4a")
            track.organizedPath = "Artist/Album/\(title).m4a"
            try track.insert(db)
            let id = try #require(track.id)
            if withSentinel {
                try Artwork(trackId: id, artworkPath: nil, source: "none", musicbrainzReleaseGroupId: nil,
                            resolution: nil, fetchedAt: "2026-01-01T00:00:00Z").save(db)
            }
            return id
        }
    }

    @Test func aTagEditPutsTheChangedTracksBackInTheArtworkQueue() async throws {
        let (database, service, center, analysis) = try makeBackfill()
        let changed = try await insertTrack(database, "Changed", withSentinel: true)
        let untouched = try await insertTrack(database, "Untouched", withSentinel: true)
        #expect(service.progress.total == 0)
        center.post(name: .trackMetadataDidChange, object: nil, userInfo: ["trackIds": [changed]])
        // The changed track's "no embedded art" mark is gone and the backfill listed it.
        await waitUntil("the backfill run") { service.progress.total == 1 && !service.isBackfilling }
        #expect(service.progress.total == 1, "only the changed track was listed")
        #expect(try await analysis.fetchArtwork(trackId: changed) == nil)
        #expect(try await analysis.fetchArtwork(trackId: untouched)?.source == "none")
    }

    @Test func aTagEditThatNamesNoTrackLeavesTheQueueAlone() async throws {
        let (database, service, _, analysis) = try makeBackfill()
        let id = try await insertTrack(database, "Alone", withSentinel: true)
        await service.requeueArtwork(forTrackIDs: [])
        #expect(service.progress.total == 0)
        #expect(try await analysis.fetchArtwork(trackId: id)?.source == "none")
    }

    @Test func realArtworkRowsSurviveATagEdit() async throws {
        let (database, service, _, analysis) = try makeBackfill()
        let id = try await insertTrack(database, "HasArt", withSentinel: false)
        try await analysis.saveArtwork(Artwork(trackId: id, artworkPath: nil, source: "musicbrainz",
                                               musicbrainzReleaseGroupId: "rg", resolution: "500",
                                               fetchedAt: "2026-01-01T00:00:00Z"))
        await service.requeueArtwork(forTrackIDs: [id])
        #expect(try await analysis.fetchArtwork(trackId: id)?.source == "musicbrainz")
    }
}
