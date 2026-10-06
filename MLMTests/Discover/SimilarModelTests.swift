import Foundation
import GRDB
import Testing
@testable import MLM

/// `Similar to “‹track›”` over a temporary database: the library matches come from the real
/// repository (held and hidden tracks excluded), the online part from a fake source.
@Suite("SimilarModelTests")
@MainActor
struct SimilarModelTests {
    final class Log: @unchecked Sendable {
        var started: [(title: String, hold: Bool)] = []
        var analysed: [Int64] = []
        var pipeline: [String: DownloadViewModel.DiscoveryStatus] = [:]
        var placements: [String: SimilarModel.OnlineRow.Placement] = [:]
    }

    struct Env {
        let db: DatabaseQueue
        let model: SimilarModel
        let tracks: TrackRepository
        let recs: RecommendationRepository
        let seed: Int64
        let near: Int64
        let far: Int64
        let held: Int64
        let hidden: Int64
        let log: Log
    }

    private static func vector(_ x: Float, _ y: Float) -> Data { [x, y].toData }

    static func make(analysed: Bool = true, swarm: FakeSwarm = FakeSwarm(), seedPath: String? = "Seed.m4a") async throws -> Env {
        let db = try DatabaseManager.inMemory()
        let tracks = TrackRepository(database: db)
        let recs = RecommendationRepository(database: db)
        func add(_ title: String, path: String?, vector: Data?) async throws -> Int64 {
            var track = Track(artist: "Artist", album: "", title: title, format: "m4a", originalPath: "/o/\(title).m4a")
            track.organizedPath = path
            track.duration = 200
            let id = try #require(try await tracks.insert(track).id)
            if let vector {
                try await db.write { db in
                    try db.execute(sql: "INSERT INTO track_embeddings (track_id, master_embedding, drop_offset) VALUES (?, ?, 0)",
                                   arguments: [id, vector])
                }
            }
            return id
        }
        let seed = try await add("Seed", path: seedPath, vector: analysed ? vector(1, 0) : nil)
        let near = try await add("Near", path: "Near.m4a", vector: vector(0.9, 0.1))
        let far = try await add("Far", path: "Far.m4a", vector: vector(0.2, 0.9))
        let held = try await add("Held", path: "Held.m4a", vector: vector(1, 0.01))
        let hidden = try await add("Hidden", path: "Hidden.m4a", vector: vector(1, 0.02))
        try await recs.markHeld(trackID: held, seedTrackID: seed, source: "soundcloud")
        try await db.write { db in try db.execute(sql: "UPDATE tracks SET is_duplicate = 1 WHERE id = ?", arguments: [hidden]) }
        let log = Log()
        let dependencies = SimilarModel.Dependencies(
            fetchTrack: { id in try? await tracks.fetchTrack(id: id) },
            similarInLibrary: { id, limit in
                ((try? await tracks.fetchSimilarTracks(seedTrackId: id, limit: limit)) ?? []).map { ($0.track, $0.score) }
            },
            isAnalysed: { id in analysed && id == seed },
            analyse: { track in log.analysed.append(track.id ?? 0) },
            swarm: swarm,
            startDownload: { recommendation, _, hold in log.started.append((recommendation.title, hold)) },
            pipelineStatus: { recommendation in
                log.pipeline[recommendation.scDownloadUrl ?? "\(recommendation.artist) - \(recommendation.title)"]
            },
            placement: { recommendation, _ in log.placements[recommendation.title] }
        )
        let model = SimilarModel(trackID: seed, dependencies: dependencies)
        return Env(db: db, model: model, tracks: tracks, recs: recs, seed: seed, near: near, far: far, held: held, hidden: hidden, log: log)
    }

    private func recommendation(_ title: String, url: String? = nil) -> SwarmRecommendation {
        SwarmRecommendation(artist: "Other", title: title, source: "soundcloud", sourceId: nil, scDownloadUrl: url)
    }

    // MARK: In library

    @Test func libraryRowsExcludeTheSeedAndHeldAndHiddenTracks() async throws {
        let env = try await Self.make()
        await env.model.load()
        #expect(env.model.seedState == .ready)
        let ids = env.model.inLibrary.compactMap(\.id)
        #expect(ids == [env.near, env.far], "ranked by sound")
        #expect(!ids.contains(env.seed) && !ids.contains(env.held) && !ids.contains(env.hidden))
        let near = try #require(env.model.matches[env.near])
        let far = try #require(env.model.matches[env.far])
        #expect(near > far && near <= 100)
    }

    @Test func aMissingSeedIsSaid() async throws {
        let env = try await Self.make()
        let model = SimilarModel(trackID: 99_999, dependencies: env.model.dependencies)
        await model.load()
        #expect(model.seedState == .missing)
    }

    @Test func anUnanalysedSeedOffersAnalyseWithTheReasonWhenItCannotRun() async throws {
        let env = try await Self.make(analysed: false)
        await env.model.load()
        #expect(env.model.seedState == .notAnalysed)
        #expect(env.model.inLibrary.isEmpty)
        #expect(env.model.analyseRefusal == nil)
        await env.model.analyseSeed()
        #expect(env.log.analysed == [env.seed])
        env.model.drive = LibraryDriveState(volumeName: "Lexxar", isConnected: false)
        #expect(env.model.analyseRefusal == "Can’t analyse — “Lexxar” is not connected.")
        env.log.analysed = []
        await env.model.analyseSeed()
        #expect(env.log.analysed.isEmpty, "disabled with the reason, not enabled and silent")
        #expect(SimilarModel.analyseSentence("Night Drive") == "MLM compares tracks by their sound. Analysing “Night Drive” takes about 20 seconds.")
    }

    @Test func aSeedWithoutAFileCannotBeAnalysed() async throws {
        let env = try await Self.make(analysed: false, seedPath: nil)
        await env.model.load()
        #expect(env.model.analyseRefusal == "Can’t analyse — download the track first.")
    }

    // MARK: Online

    @Test func onlineRowsComeFromTheSourceAndRefreshReadsAgain() async throws {
        var swarm = FakeSwarm()
        swarm.recommendations = [recommendation("One", url: "https://soundcloud.com/a/one"), recommendation("Two")]
        let env = try await Self.make(swarm: swarm)
        await env.model.load()
        await env.model.waitForOnline()
        #expect(env.model.onlineState == .results)
        #expect(env.model.onlineRows.map(\.recommendation.title) == ["One", "Two"])
        env.log.placements["One"] = .library
        await env.model.refresh()
        await env.model.waitForOnline()
        #expect(env.model.onlineRows.first?.stateWord == "In library")
        #expect(SimilarModel.onlineLoadingLine(.soundcloud, "Night Drive") == "Asking SoundCloud for tracks related to “Night Drive”…")
    }

    @Test func downloadHoldsAndKeepDoesNot() async throws {
        var swarm = FakeSwarm()
        swarm.recommendations = [recommendation("One"), recommendation("Two")]
        let env = try await Self.make(swarm: swarm)
        await env.model.load()
        await env.model.waitForOnline()
        env.model.download(env.model.onlineRows[0])
        env.model.keep(env.model.onlineRows[1])
        #expect(env.log.started.map(\.title) == ["One", "Two"])
        #expect(env.log.started.map(\.hold) == [true, false], "Download is held in Discover, Keep goes into the library")
    }

    @Test func aRowThatIsBusyOrAlreadyHereOffersNothing() async throws {
        var swarm = FakeSwarm()
        swarm.recommendations = [recommendation("One"), recommendation("Two")]
        let env = try await Self.make(swarm: swarm)
        env.log.pipeline["Other - One"] = .downloading
        env.log.placements["Two"] = .held
        await env.model.load()
        await env.model.waitForOnline()
        let rows = env.model.onlineRows
        #expect(rows[0].stateWord == "Downloading…" && rows[0].isBusy)
        #expect(rows[1].stateWord == "In Recommendations" && rows[1].isPlaced)
        env.model.download(rows[0])
        env.model.keep(rows[1])
        #expect(env.log.started.isEmpty)
        var queued = rows[0]
        queued.pipeline = .queued
        #expect(queued.stateWord == "Queued")
    }

    @Test func noSourceErrorsAndOfflineArePointedAtAPlaceThatExists() async throws {
        var swarm = FakeSwarm()
        swarm.failure = SwarmError.soundCloudClientIdMissing
        let env = try await Self.make(swarm: swarm)
        await env.model.load()
        await env.model.waitForOnline()
        guard case .failed(let missing) = env.model.onlineState else {
            Issue.record("expected a failure")
            return
        }
        #expect(missing.kind == .noSource)
        #expect(missing.headline == "SoundCloud isn’t set up for suggestions")
        let offline = SimilarModel.failure(SwarmError.soundCloudNetworkError(underlying: URLError(.notConnectedToInternet)), source: .soundcloud)
        #expect(offline.kind == .offline)
        let noAnswer = SimilarModel.failure(SwarmError.soundCloudRelatedError(statusCode: 503), source: .soundcloud)
        #expect(noAnswer.kind == .noAnswer && noAnswer.headline == "SoundCloud didn’t answer")
        #expect(noAnswer.details.contains("HTTP 503") && noAnswer.details.contains("your library is not affected"))
        // The library section keeps working under a failed online section.
        #expect(env.model.seedState == .ready && !env.model.inLibrary.isEmpty)
    }

    @Test func nothingFoundIsSaidNotShownAsAnError() async throws {
        let env = try await Self.make()
        await env.model.load()
        await env.model.waitForOnline()
        #expect(env.model.onlineState == .empty)
        #expect(SimilarModel.noSuggestionsLine(.lastfm, "Seed") == "Last.fm has no related tracks for “Seed”.")
    }
}
