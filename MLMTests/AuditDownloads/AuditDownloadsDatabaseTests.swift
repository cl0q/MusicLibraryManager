import Foundation
import Testing
@testable import MLM

@MainActor
struct AuditDownloadsDatabaseTests {
    private func makeRepositories() throws -> (TrackRepository, PlaylistRepository, SourceRepository) {
        let database = try DatabaseManager.inMemory()
        return (
            TrackRepository(database: database),
            PlaylistRepository(database: database),
            SourceRepository(database: database)
        )
    }

    private func remoteTrack(_ title: String, path: String) -> Track {
        Track(
            artist: "Audit Artist",
            album: "Audit Album",
            title: title,
            format: "youtube",
            originalPath: path
        )
    }

    @Test func deletingTrackRemovesMembershipsAndSourceLink() async throws {
        let (tracks, playlists, sources) = try makeRepositories()
        let track = try await tracks.insert(remoteTrack("One", path: "youtube://audit-one"))
        let playlist = try await playlists.create(name: "Audit playlist")
        let source = try await sources.upsert(name: "youtube", userId: "audit")
        try await playlists.addTrack(
            playlistId: try #require(playlist.id),
            trackId: try #require(track.id),
            position: "999000"
        )
        try await sources.linkTrackToSource(
            trackId: try #require(track.id),
            sourceId: try #require(source.id),
            externalId: "audit-one"
        )

        try await tracks.delete(id: try #require(track.id))

        #expect(try await playlists.trackCount(playlistId: try #require(playlist.id)) == 0)
        #expect(try await sources.countTracks(sourceId: try #require(source.id)) == 0)
    }

    @Test func appendTracksUsesTailAndInputOrder() async throws {
        let (tracks, playlists, _) = try makeRepositories()
        let first = try await tracks.insert(remoteTrack("First", path: "youtube://first"))
        let second = try await tracks.insert(remoteTrack("Second", path: "youtube://second"))
        let third = try await tracks.insert(remoteTrack("Third", path: "youtube://third"))
        let playlist = try await playlists.create(name: "Append audit")
        try await playlists.addTrack(
            playlistId: try #require(playlist.id),
            trackId: try #require(first.id),
            position: "zzzzzz"
        )

        try await playlists.appendTracks(
            playlistId: try #require(playlist.id),
            trackIds: [try #require(second.id), try #require(third.id)]
        )

        let ordered = try await playlists.fetchTracks(playlistId: try #require(playlist.id))
        #expect(ordered.map(\.title) == ["First", "Second", "Third"])
    }

    @Test func materializationDeduplicatesConcurrentProviderIdentity() async throws {
        let (tracks, _, sources) = try makeRepositories()
        let materializer = RemoteTrackMaterializer(
            trackRepository: tracks,
            sourceRepository: sources
        )
        let result = RemoteSearchResult(
            id: "audit-video",
            source: .youtube,
            artist: "Audit Artist",
            title: "Audit Video",
            durationSeconds: 180,
            externalId: "audit-video",
            sourceURL: "https://youtube.com/watch?v=audit-video"
        )

        async let first = materializer.materialize([result, result])
        async let second = materializer.materialize([result])
        let (firstTracks, secondTracks) = try await (first, second)

        #expect(firstTracks.count == 2)
        #expect(firstTracks[0].id == firstTracks[1].id)
        #expect(firstTracks[0].id == secondTracks[0].id)
        #expect(try await tracks.fetchAllTracks().count == 1)
    }
}
