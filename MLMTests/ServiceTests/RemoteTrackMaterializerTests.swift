import Foundation
import Testing
import GRDB
@testable import MLM

@MainActor
struct RemoteTrackMaterializerTests {

    private func makeRepo() async throws -> (DatabaseQueue, TrackRepository, SourceRepository) {
        let db = try DatabaseManager.inMemory()
        let trackRepo = TrackRepository(database: db)
        let sourceRepo = SourceRepository(database: db)
        return (db, trackRepo, sourceRepo)
    }

    private func sampleResult(
        id: String = "yt-abc",
        source: RemoteSearchResult.Source = .youtube,
        artist: String = "Artist",
        title: String = "Title",
        externalId: String = "abc",
        sourceURL: String? = "https://youtube.com/watch?v=abc"
    ) -> RemoteSearchResult {
        RemoteSearchResult(
            id: id,
            source: source,
            artist: artist,
            title: title,
            durationSeconds: 180,
            externalId: externalId,
            sourceURL: sourceURL
        )
    }

    // MARK: - Materialization

    @Test func materializesNewRemoteTrack() async throws {
        let (_, trackRepo, sourceRepo) = try await makeRepo()
        let materializer = RemoteTrackMaterializer(
            trackRepository: trackRepo,
            sourceRepository: sourceRepo
        )

        let results = [sampleResult()]
        let tracks = try await materializer.materialize(results)

        #expect(tracks.count == 1)
        #expect(tracks[0].isRemote)
        #expect(tracks[0].title == "Title")
        #expect(tracks[0].artist == "Artist")
        #expect(tracks[0].id != nil)
    }

    @Test func materializingTwiceDoesNotDuplicate() async throws {
        let (_, trackRepo, sourceRepo) = try await makeRepo()
        let materializer = RemoteTrackMaterializer(
            trackRepository: trackRepo,
            sourceRepository: sourceRepo
        )

        let results = [sampleResult()]
        let first = try await materializer.materialize(results)
        let second = try await materializer.materialize(results)

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first[0].id == second[0].id)

        // Verify only one track in DB
        let all = try await trackRepo.search(query: "Title")
        #expect(all.count == 1)
    }

    @Test func materializedTracksAreRemote() async throws {
        let (_, trackRepo, sourceRepo) = try await makeRepo()
        let materializer = RemoteTrackMaterializer(
            trackRepository: trackRepo,
            sourceRepository: sourceRepo
        )

        let results = [
            sampleResult(id: "yt-1", externalId: "1", sourceURL: "https://youtube.com/watch?v=1"),
            sampleResult(id: "sc-2", source: .soundcloud, artist: "SC", title: "SC Track",
                        externalId: "2", sourceURL: "https://soundcloud.com/2")
        ]
        let tracks = try await materializer.materialize(results)

        #expect(tracks.count == 2)
        #expect(tracks.allSatisfy { $0.isRemote })
    }

    @Test func emptyResultsReturnsEmpty() async throws {
        let (_, trackRepo, sourceRepo) = try await makeRepo()
        let materializer = RemoteTrackMaterializer(
            trackRepository: trackRepo,
            sourceRepository: sourceRepo
        )

        let tracks = try await materializer.materialize([])
        #expect(tracks.isEmpty)
    }

    @Test func sourceUpsertCalledOncePerDistinctSource() async throws {
        let (_, trackRepo, sourceRepo) = try await makeRepo()
        let materializer = RemoteTrackMaterializer(
            trackRepository: trackRepo,
            sourceRepository: sourceRepo
        )

        // 6 results across 3 distinct sources — the materializer must
        // upsert each source name only once, not once per track.
        let results = [
            sampleResult(id: "yt-1", source: .youtube, externalId: "yt1", sourceURL: "https://youtube.com/watch?v=yt1"),
            sampleResult(id: "yt-2", source: .youtube, artist: "A2", title: "T2", externalId: "yt2", sourceURL: "https://youtube.com/watch?v=yt2"),
            sampleResult(id: "yt-3", source: .youtube, artist: "A3", title: "T3", externalId: "yt3", sourceURL: "https://youtube.com/watch?v=yt3"),
            sampleResult(id: "sc-1", source: .soundcloud, artist: "SC1", title: "SC1", externalId: "sc1", sourceURL: "https://soundcloud.com/sc1"),
            sampleResult(id: "sc-2", source: .soundcloud, artist: "SC2", title: "SC2", externalId: "sc2", sourceURL: "https://soundcloud.com/sc2"),
            sampleResult(id: "sp-1", source: .spotify, artist: "SP1", title: "SP1", externalId: "sp1", sourceURL: nil),
        ]
        let tracks = try await materializer.materialize(results)

        #expect(tracks.count == 6)

        // Exactly 3 source rows (youtube, soundcloud, spotify) — not 6.
        let allSources = try await sourceRepo.fetchAll()
        #expect(allSources.count == 3)
        let sourceNames = Set(allSources.map(\.name))
        #expect(sourceNames == ["youtube", "soundcloud", "spotify"])
    }

    @Test func preservesInputOrder() async throws {
        let (_, trackRepo, sourceRepo) = try await makeRepo()
        let materializer = RemoteTrackMaterializer(
            trackRepository: trackRepo,
            sourceRepository: sourceRepo
        )

        let results = [
            sampleResult(id: "yt-1", source: .youtube, artist: "First", title: "First", externalId: "ord1", sourceURL: "https://youtube.com/watch?v=ord1"),
            sampleResult(id: "sc-2", source: .soundcloud, artist: "Second", title: "Second", externalId: "ord2", sourceURL: "https://soundcloud.com/ord2"),
            sampleResult(id: "sp-3", source: .spotify, artist: "Third", title: "Third", externalId: "ord3", sourceURL: nil),
            sampleResult(id: "yt-4", source: .youtube, artist: "Fourth", title: "Fourth", externalId: "ord4", sourceURL: "https://youtube.com/watch?v=ord4"),
        ]
        let tracks = try await materializer.materialize(results)

        #expect(tracks.count == 4)
        #expect(tracks[0].artist == "First")
        #expect(tracks[1].artist == "Second")
        #expect(tracks[2].artist == "Third")
        #expect(tracks[3].artist == "Fourth")
    }
}
