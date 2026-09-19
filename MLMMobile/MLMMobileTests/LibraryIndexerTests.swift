import XCTest
import GRDB
@testable import MLMMobile

final class LibraryIndexerTests: XCTestCase {

    private var indexer: LibraryIndexer!
    private var tempDBURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        indexer = try LibraryIndexer(databaseURL: tempDBURL)
    }

    override func tearDown() async throws {
        indexer = nil
        if let url = tempDBURL {
            try? FileManager.default.removeItem(at: url)
        }
        try await super.tearDown()
    }

    private func makeManifest(
        generatedAt: String = "2026-09-04T12:00:00Z",
        tracks: [ManifestTrack] = [],
        playlists: [ManifestPlaylist] = []
    ) -> LibraryManifest {
        LibraryManifest(
            schema: 1,
            profile: "Test",
            generatedAt: generatedAt,
            tracks: tracks,
            playlists: playlists
        )
    }

    private func makeTrack(
        uuid: String = "track-1",
        title: String = "Title",
        artist: String = "Artist",
        energyBucket: Int = 3
    ) -> ManifestTrack {
        ManifestTrack(
            uuid: uuid,
            title: title,
            artist: artist,
            albumArtist: artist,
            album: "Album",
            duration: 200,
            path: "\(artist)/Album/\(title).m4a",
            energyBucket: energyBucket,
            lufsI: -14.0
        )
    }

    func testInsertTracksAndPlaylists() throws {
        let manifest = makeManifest(
            tracks: [
                makeTrack(uuid: "t1", title: "Song A", artist: "Artist 1"),
                makeTrack(uuid: "t2", title: "Song B", artist: "Artist 2", energyBucket: 5)
            ],
            playlists: [
                ManifestPlaylist(uuid: "p1", name: "Favorites", file: "Favorites.m3u8")
            ]
        )

        let updated = try indexer.index(manifest: manifest)
        XCTAssertTrue(updated)

        let tracks = try indexer.fetchAllTracks()
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].uuid, "t1")
        XCTAssertEqual(tracks[1].uuid, "t2")

        let playlists = try indexer.fetchAllPlaylists()
        XCTAssertEqual(playlists.count, 1)
        XCTAssertEqual(playlists[0].name, "Favorites")
    }

    func testSkipsReindexWhenGeneratedAtUnchanged() throws {
        let manifest = makeManifest(
            generatedAt: "2026-09-04T12:00:00Z",
            tracks: [makeTrack(uuid: "t1")]
        )

        let first = try indexer.index(manifest: manifest)
        XCTAssertTrue(first)

        let second = try indexer.index(manifest: manifest)
        XCTAssertFalse(second, "Should skip re-index when generated_at is unchanged")

        let tracks = try indexer.fetchAllTracks()
        XCTAssertEqual(tracks.count, 1, "Should still have exactly 1 track")
    }

    func testReindexesWhenGeneratedAtChanges() throws {
        let manifest1 = makeManifest(
            generatedAt: "2026-09-04T12:00:00Z",
            tracks: [makeTrack(uuid: "t1")]
        )
        _ = try indexer.index(manifest: manifest1)

        let manifest2 = makeManifest(
            generatedAt: "2026-09-04T13:00:00Z",
            tracks: [
                makeTrack(uuid: "t1"),
                makeTrack(uuid: "t2", title: "New Song")
            ]
        )
        let updated = try indexer.index(manifest: manifest2)
        XCTAssertTrue(updated)

        let tracks = try indexer.fetchAllTracks()
        XCTAssertEqual(tracks.count, 2, "Should have both tracks after re-index")
    }

    func testSearchTracks() throws {
        let manifest = makeManifest(
            tracks: [
                makeTrack(uuid: "t1", title: "Sunset Drive", artist: "Chill Vibes"),
                makeTrack(uuid: "t2", title: "Morning Run", artist: "Energy Boost"),
                makeTrack(uuid: "t3", title: "Night Owl", artist: "Chill Vibes")
            ]
        )
        _ = try indexer.index(manifest: manifest)

        let results = try indexer.searchTracks(query: "Chill")
        XCTAssertEqual(results.count, 2)

        let titleResults = try indexer.searchTracks(query: "Morning")
        XCTAssertEqual(titleResults.count, 1)
        XCTAssertEqual(titleResults[0].uuid, "t2")
    }

    func testFetchTracksByEnergyBucket() throws {
        let manifest = makeManifest(
            tracks: [
                makeTrack(uuid: "t1", energyBucket: 1),
                makeTrack(uuid: "t2", energyBucket: 3),
                makeTrack(uuid: "t3", energyBucket: 3),
                makeTrack(uuid: "t4", energyBucket: 5)
            ]
        )
        _ = try indexer.index(manifest: manifest)

        let bucket3 = try indexer.fetchTracks(energyBucket: 3)
        XCTAssertEqual(bucket3.count, 2)

        let bucket1 = try indexer.fetchTracks(energyBucket: 1)
        XCTAssertEqual(bucket1.count, 1)

        let bucket4 = try indexer.fetchTracks(energyBucket: 4)
        XCTAssertEqual(bucket4.count, 0)
    }

    func testClearIndex() throws {
        let manifest = makeManifest(
            tracks: [makeTrack()],
            playlists: [ManifestPlaylist(uuid: "p1", name: "P", file: "P.m3u8")]
        )
        _ = try indexer.index(manifest: manifest)

        try indexer.clearIndex()

        let tracks = try indexer.fetchAllTracks()
        let playlists = try indexer.fetchAllPlaylists()
        let lastGen = try indexer.lastIndexedGeneration()

        XCTAssertEqual(tracks.count, 0)
        XCTAssertEqual(playlists.count, 0)
        XCTAssertNil(lastGen)
    }

    func testLastIndexedGeneration() throws {
        XCTAssertNil(try indexer.lastIndexedGeneration())

        let manifest = makeManifest(generatedAt: "2026-09-04T12:00:00Z")
        _ = try indexer.index(manifest: manifest)

        XCTAssertEqual(try indexer.lastIndexedGeneration(), "2026-09-04T12:00:00Z")
    }
}
