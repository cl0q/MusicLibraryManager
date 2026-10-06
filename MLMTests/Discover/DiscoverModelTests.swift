import Foundation
import GRDB
import Testing
@testable import MLM

struct FakeSwarm: SwarmRecommending {
    var recommendations: [SwarmRecommendation] = []
    var failure: (any Error)?

    func fetchRecommendations(for track: Track, source: SwarmRecommendationService.SwarmSource, limit: Int) async throws -> [SwarmRecommendation] {
        if let failure { throw failure }
        return recommendations
    }
}

/// Discover's model over a temporary database, an undo center on its own manager and a fake Trash.
@MainActor
struct DiscoverEnv {
    let db: DatabaseQueue
    let model: DiscoverModel
    let recs: RecommendationRepository
    let tracks: TrackRepository
    let undo: UndoCenter
    let manager: UndoManager
    let status: StatusBarCenter
    let files: FakeReviewFiles
    let seeds: [Int64]
    let held: [Int64]
    let log: Log

    final class Log: @unchecked Sendable {
        var changes = 0
        var downloads: [String] = []
        var analysed: [Int64] = []
        var playing: Track?
        var isAnalysed = true
    }

    static let root = "/lib"

    /// Two seeds: `Seed A` with two recommendations (one analysed), `Seed B` with one, and one
    /// recommendation whose seed was removed.
    static func make(swarm: FakeSwarm = FakeSwarm(), existingFiles: [String]? = nil) async throws -> DiscoverEnv {
        let db = try DatabaseManager.inMemory()
        let tracks = TrackRepository(database: db)
        let recs = RecommendationRepository(database: db)
        func add(_ title: String, path: String, energy: Int? = nil) async throws -> Int64 {
            var track = Track(artist: "Artist", album: "", title: title, format: "m4a", originalPath: "/o/\(title).m4a")
            track.organizedPath = path
            track.energyBucket = energy
            track.duration = 200
            return try #require(try await tracks.insert(track).id)
        }
        let seedA = try await add("Seed A", path: "A.m4a", energy: 3)
        let seedB = try await add("Seed B", path: "B.m4a", energy: 2)
        let h1 = try await add("Held 1", path: "Neighbors/Held 1.m4a", energy: 4)
        let h2 = try await add("Held 2", path: "Neighbors/Held 2.m4a")
        let h3 = try await add("Held 3", path: "Neighbors/Held 3.m4a")
        let h4 = try await add("Held 4", path: "Neighbors/Held 4.m4a")
        try await recs.markHeld(trackID: h1, seedTrackID: seedA, source: "soundcloud")
        try await recs.markHeld(trackID: h2, seedTrackID: seedA, source: "lastfm")
        try await recs.markHeld(trackID: h3, seedTrackID: seedB, source: "soundcloud")
        try await recs.markHeld(trackID: h4, seedTrackID: 999_999, source: "lastfm")
        // Spread the log dates so the order is stable (newest first: h4, h3, h2, h1).
        try await db.write { db in
            for (index, id) in [h1, h2, h3, h4].enumerated() {
                try db.execute(sql: "UPDATE track_discovery_log SET date_added = ? WHERE discovered_track_id = ?",
                               arguments: ["2026-10-0\(index + 1) 10:00:00", id])
            }
        }
        let files = FakeReviewFiles(existing: existingFiles ?? ["h1", "h2", "h3", "h4"].map { "/lib/Neighbors/Held \($0.dropFirst()).m4a" })
        let manager = UndoManager()
        manager.groupsByEvent = false
        let sleeper = ManualSleeper()
        let status = StatusBarCenter(sleep: { await sleeper.sleep($0) }, announce: { _ in })
        let undo = UndoCenter(undoManager: manager, statusBar: status, log: { _ in })
        let log = Log()
        var dependencies = DiscoverModel.Dependencies(recommendations: recs, swarm: swarm)
        dependencies.libraryRoot = { root }
        dependencies.consequences = ReviewConsequences(files: files)
        dependencies.postChange = { log.changes += 1 }
        dependencies.startDownload = { rec, _ in log.downloads.append("\(rec.artist) – \(rec.title)") }
        dependencies.isAnalysed = { _ in log.isAnalysed }
        dependencies.analyse = { track in log.analysed.append(track.id ?? 0) }
        dependencies.fetchTrack = { id in try? await tracks.fetchTrack(id: id) }
        dependencies.playingTrack = { log.playing }
        dependencies.isInLibrary = { artist, title in
            ((try? await tracks.fetchTrackByArtistAndTitle(artist: artist, title: title)) ?? nil) != nil
        }
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let model = DiscoverModel(dependencies: dependencies, center: center)
        model.statusBar = status
        model.undo = undo
        return DiscoverEnv(db: db, model: model, recs: recs, tracks: tracks, undo: undo, manager: manager, status: status,
                           files: files, seeds: [seedA, seedB], held: [h1, h2, h3, h4], log: log)
    }

    func undoStep() async {
        manager.undo()
        await undo.waitUntilIdle()
    }

    func redoStep() async {
        manager.redo()
        await undo.waitUntilIdle()
    }

    func waitingIDs() async throws -> Set<Int64> {
        Set(try await recs.waiting().map(\.id))
    }

    func listedIDs() async throws -> Set<Int64> {
        Set(try await tracks.fetchTracks(scope: .all).compactMap(\.id))
    }
}

@Suite("DiscoverModelTests")
@MainActor
struct DiscoverModelTests {
    // MARK: Groups, counts, first load

    @Test func firstLoadThenGroupsBySeedWithOtherLast() async throws {
        let env = try await DiscoverEnv.make()
        #expect(!env.model.isLoaded, "placeholder rows until the first load finishes")
        #expect(env.model.count(for: .recommendations) == nil)
        await env.model.reload()
        #expect(env.model.isLoaded && env.model.loadError == nil)
        let groups = env.model.groups
        #expect(groups.map(\.title) == ["Because of “Seed B”", "Because of “Seed A”", "Other recommendations"],
                "seed groups newest first, seedless rows last")
        #expect(groups[1].items.map(\.track.title) == ["Held 2", "Held 1"])
        #expect(env.model.waitingCount == 4)
        #expect(env.model.count(for: .recommendations) == 4)
        #expect(DiscoverModel.headerLine(4) == "4 recommendations — held here, not in All Tracks, until you keep them.")
        #expect(DiscoverModel.headerLine(1).hasPrefix("1 recommendation —"))
    }

    @Test func laterReloadsUpdateInPlaceWithoutLosingTheRows() async throws {
        let env = try await DiscoverEnv.make()
        await env.model.reload()
        try await env.db.write { db in try db.execute(sql: "DROP TABLE track_discovery_log") }
        await env.model.reload()
        #expect(env.model.loadError != nil, "a failed load is reported")
        #expect(env.model.waitingCount == 4, "…and never shown as empty")
        #expect(!env.model.isEmpty)
    }

    @Test func aFailedFirstLoadIsAnErrorNotAnEmptyList() async throws {
        let env = try await DiscoverEnv.make()
        try await env.db.write { db in try db.execute(sql: "DROP TABLE track_discovery_log") }
        await env.model.reload()
        #expect(env.model.loadError != nil)
        #expect(!env.model.isEmpty)
    }

    @Test func sourceWordsAreWordsNotCapsules() {
        #expect(DiscoverModel.sourceWord("soundcloud") == "SoundCloud")
        #expect(DiscoverModel.sourceWord("lastfm") == "Last.fm")
    }

    @Test func theFilterNarrowsGroupsButNotTheCount() async throws {
        let env = try await DiscoverEnv.make()
        await env.model.reload()
        env.model.filter = SearchFilter(text: "Held 3")
        #expect(env.model.visibleGroups.map(\.title) == ["Because of “Seed B”"])
        #expect(env.model.waitingCount == 4)
        env.model.filter = SearchFilter(text: "zzz")
        #expect(env.model.hasNoMatches)
        env.model.filter = .empty
        #expect(env.model.visibleCount == 4 && !env.model.hasNoMatches)
    }

    // MARK: Keep

    @Test func keepIsOneUndoStepWithExactRestore() async throws {
        let env = try await DiscoverEnv.make()
        await env.model.reload()
        await env.model.keep([env.held[0]])
        #expect(env.undo.stepCount == 1)
        #expect(env.manager.undoActionName == "Keep “Held 1”")
        #expect(env.status.message?.text == "Added “Held 1” to the library")
        #expect(env.status.message?.actions.map(\.title) == ["Undo"])
        #expect(try await env.listedIDs().contains(env.held[0]))
        #expect(try await env.waitingIDs() == [env.held[1], env.held[2], env.held[3]])
        #expect(env.log.changes >= 1, "All Tracks and the badge are told")
        await env.undoStep()
        #expect(!(try await env.listedIDs()).contains(env.held[0]))
        #expect(try await env.waitingIDs().contains(env.held[0]))
        await env.redoStep()
        #expect(try await env.listedIDs().contains(env.held[0]))
    }

    @Test func keepAllOnAGroupIsOneStep() async throws {
        let env = try await DiscoverEnv.make()
        await env.model.reload()
        let group = try #require(env.model.groups.first { $0.seedTrackID == env.seeds[0] })
        await env.model.keepAll(in: group)
        #expect(env.undo.stepCount == 1)
        #expect(env.status.message?.text == "Added 2 tracks to the library")
        #expect(try await env.waitingIDs() == [env.held[2], env.held[3]])
        await env.undoStep()
        #expect(try await env.waitingIDs().count == 4)
        #expect(env.undo.stepCount == 1, "the undone step stays reachable for Redo")
    }

    @Test func keepAndAddToPlaylistIsOneStep() async throws {
        let env = try await DiscoverEnv.make()
        let placed = Placed()
        var dependencies = env.model.dependencies
        dependencies.placeInPlaylist = { group, ids, _ in
            try await group.perform(do: { placed.ids = ids }, undo: { placed.ids = [] })
            return "Warm-up"
        }
        let model = DiscoverModel(dependencies: dependencies, center: ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0))
        model.statusBar = env.status
        model.undo = env.undo
        await model.reload()
        await model.keep([env.held[2]], addTo: 7)
        #expect(placed.ids == [env.held[2]])
        #expect(env.undo.stepCount == 1)
        #expect(env.status.message?.text == "Added “Held 3” to the library and to “Warm-up”")
        await env.undoStep()
        #expect(placed.ids.isEmpty)
        #expect(try await env.waitingIDs().contains(env.held[2]))
    }

    final class Placed: @unchecked Sendable { var ids: [Int64] = [] }

    // MARK: Dismiss

    @Test func dismissMovesTheFileToTheTrashAfterTheCommitAndUndoMovesItBack() async throws {
        let env = try await DiscoverEnv.make()
        await env.model.reload()
        await env.model.dismiss([env.held[1]])
        #expect(env.manager.undoActionName == "Dismiss “Held 2”")
        #expect(env.status.message?.text == "Dismissed “Held 2” — moved to the Trash")
        #expect(env.files.trashed == ["/lib/Neighbors/Held 2.m4a"])
        #expect(!env.files.fileExists(atPath: "/lib/Neighbors/Held 2.m4a"))
        #expect(try await env.recs.trashURLs(for: [env.held[1]]) == [env.held[1]: "/Trash/Held 2.m4a"])
        #expect(!(try await env.waitingIDs()).contains(env.held[1]))
        #expect(!(try await env.listedIDs()).contains(env.held[1]), "a dismissed row stays out of every list")
        await env.undoStep()
        #expect(env.files.fileExists(atPath: "/lib/Neighbors/Held 2.m4a"))
        #expect(try await env.waitingIDs().contains(env.held[1]))
        #expect(try await env.recs.trashURLs(for: [env.held[1]]).isEmpty)
        await env.redoStep()
        #expect(!(try await env.waitingIDs()).contains(env.held[1]))
        #expect(!env.files.fileExists(atPath: "/lib/Neighbors/Held 2.m4a"))
    }

    @Test func undoSaysSoWhenTheFileIsNoLongerInTheTrash() async throws {
        let env = try await DiscoverEnv.make()
        await env.model.reload()
        await env.model.dismiss([env.held[0]])
        env.files.removeFromTrash("Held 1.m4a")
        await env.undoStep()
        #expect(env.status.message?.text == "Can’t undo — 1 file is no longer in the Trash")
        #expect(!(try await env.waitingIDs()).contains(env.held[0]), "the row isn’t brought back without its file")
    }

    @Test func dismissAllOnAGroupIsOneStep() async throws {
        let env = try await DiscoverEnv.make()
        await env.model.reload()
        let group = try #require(env.model.groups.first { $0.seedTrackID == env.seeds[0] })
        await env.model.dismissAll(in: group)
        #expect(env.undo.stepCount == 1)
        #expect(env.status.message?.text == "Dismissed 2 recommendations — moved to the Trash")
        #expect(env.files.trashed.count == 2)
        await env.undoStep()
        #expect(try await env.waitingIDs().count == 4)
        #expect(env.files.trashed.count == 2)
    }

    @Test func dismissIsRefusedWhileTheDriveIsAway() async throws {
        let env = try await DiscoverEnv.make()
        await env.model.reload()
        env.model.drive = LibraryDriveState(volumeName: "Lexxar", isConnected: false)
        #expect(env.model.dismissRefusal == "“Lexxar” is not connected")
        await env.model.dismiss([env.held[0]])
        await env.model.dismissAll(in: env.model.groups[0])
        #expect(env.status.message?.text == "Can’t dismiss — “Lexxar” is not connected")
        #expect(env.files.trashed.isEmpty)
        #expect(env.undo.stepCount == 0)
        #expect(try await env.waitingIDs().count == 4)
        // Keep needs no files: it still works.
        await env.model.keep([env.held[0]])
        #expect(try await env.listedIDs().contains(env.held[0]))
    }

    @Test func aFileThatCannotMoveLeavesItsRowWaiting() async throws {
        let env = try await DiscoverEnv.make()
        await env.model.reload()
        env.files.failing = ["/lib/Neighbors/Held 1.m4a"]
        await env.model.dismiss([env.held[0]])
        #expect(try await env.waitingIDs().contains(env.held[0]))
        #expect(env.status.message?.text == "Couldn’t move 1 file to the Trash")
        #expect(env.status.message?.actions.map(\.title) == ["Show Logs"])
        #expect(env.undo.stepCount == 0, "nothing changed, no step")
    }

    @Test func aRecommendationWithoutAFileIsStillDismissed() async throws {
        let env = try await DiscoverEnv.make(existingFiles: [])
        await env.model.reload()
        await env.model.dismiss([env.held[3]])
        #expect(!(try await env.waitingIDs()).contains(env.held[3]))
        await env.undoStep()
        #expect(try await env.waitingIDs().contains(env.held[3]))
    }

    // MARK: Find Recommendations…

    @Test func findWithoutASeedSaysSo() async throws {
        let env = try await DiscoverEnv.make()
        await env.model.reload()
        #expect(await env.model.findRecommendations(selected: []) == nil)
        #expect(env.status.message?.text == "Select a track or play one to find recommendations from")
        #expect(env.log.downloads.isEmpty)
    }

    @Test func findWithAnUnanalysedSeedOffersAnalyse() async throws {
        let env = try await DiscoverEnv.make()
        await env.model.reload()
        env.log.isAnalysed = false
        #expect(await env.model.findRecommendations(selected: [env.held[0]]) == nil)
        #expect(env.status.message?.text == "“Seed A” isn’t analysed yet")
        let analyse = try #require(env.status.message?.actions.first)
        #expect(analyse.title == "Analyse")
        env.status.perform(analyse)
        for _ in 0..<50 where env.log.analysed.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(env.log.analysed == [env.seeds[0]])
    }

    @Test func findUsesTheSelectedRecommendationsSeedElseThePlayingTrackAndSkipsWhatIsInTheLibrary() async throws {
        var swarm = FakeSwarm()
        swarm.recommendations = [
            SwarmRecommendation(artist: "Artist", title: "Seed B", source: "soundcloud"),
            SwarmRecommendation(artist: "New", title: "One", source: "soundcloud", sourceId: "1", scDownloadUrl: "https://soundcloud.com/n/1"),
            SwarmRecommendation(artist: "New", title: "Two", source: "soundcloud"),
        ]
        let env = try await DiscoverEnv.make(swarm: swarm)
        await env.model.reload()
        #expect(await env.model.findRecommendations(selected: [env.held[2]]) == 2, "Seed B’s recommendation seeds it; Seed B itself is already here")
        #expect(env.log.downloads == ["New – One", "New – Two"])
        env.log.downloads = []
        env.log.playing = try await env.tracks.fetchTrack(id: env.seeds[0])
        #expect(await env.model.findRecommendations(selected: []) == 2)
        #expect(env.undo.stepCount == 0, "a search is not an undo step")
    }

    @Test func aFailedSearchSaysWhy() async throws {
        var swarm = FakeSwarm()
        swarm.failure = SwarmError.soundCloudRelatedError(statusCode: 503)
        let env = try await DiscoverEnv.make(swarm: swarm)
        await env.model.reload()
        #expect(await env.model.findRecommendations(selected: [env.held[0]]) == nil)
        #expect(env.status.message?.text == "Couldn’t find recommendations — SoundCloud could not load recommendations (HTTP 503).")
        #expect(env.status.message?.actions.map(\.title) == ["Show Logs"])
    }
}
