import XCTest
import GRDB
@testable import MLMMobile

final class LikesServiceTests: XCTestCase {

    private var engine: PlaylistEngine!
    private var likesService: LikesService!
    private var dbQueue: DatabaseQueue!
    private var tempDBURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        dbQueue = try DatabaseQueue(path: tempDBURL.path)
        // Run migrations via LibraryIndexer
        let indexer = try LibraryIndexer(databaseURL: tempDBURL)
        _ = indexer
        engine = PlaylistEngine(dbQueue: dbQueue)
        likesService = LikesService(dbQueue: dbQueue, engine: engine)
    }

    override func tearDown() async throws {
        likesService = nil
        engine = nil
        dbQueue = nil
        if let url = tempDBURL {
            try? FileManager.default.removeItem(at: url)
        }
        try await super.tearDown()
    }

    // MARK: - Toggle

    func testToggleLikeOn() throws {
        let result = try likesService.toggleLike(trackUUID: "TRACK-1")
        XCTAssertTrue(result)
        XCTAssertTrue(try likesService.isLiked(trackUUID: "TRACK-1"))
    }

    func testToggleLikeOff() throws {
        _ = try likesService.toggleLike(trackUUID: "TRACK-1")
        let result = try likesService.toggleLike(trackUUID: "TRACK-1")
        XCTAssertFalse(result)
        XCTAssertFalse(try likesService.isLiked(trackUUID: "TRACK-1"))
    }

    func testFetchLikedUUIDs() throws {
        _ = try likesService.toggleLike(trackUUID: "T1")
        _ = try likesService.toggleLike(trackUUID: "T2")
        _ = try likesService.toggleLike(trackUUID: "T3")
        _ = try likesService.toggleLike(trackUUID: "T2")  // unlike T2

        let uuids = try likesService.fetchLikedUUIDs()
        XCTAssertEqual(uuids, Set(["T1", "T3"]))
    }

    // MARK: - Liked.m3u8 roundtrip

    /// Toggle hearts → file content correct → parse back → same set.
    func testLikedM3U8Roundtrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create some indexed tracks for lookup
        let track1 = IndexedTrack(
            id: nil, uuid: "UUID-A", title: "Song A", artist: "Artist 1",
            albumArtist: "Artist 1", album: "Album", duration: 200,
            path: "Artist 1/Album/Song A.m4a", energyBucket: 3, lufsI: -14.0
        )
        let track2 = IndexedTrack(
            id: nil, uuid: "UUID-B", title: "Song B", artist: "Artist 2",
            albumArtist: "Artist 2", album: "Album", duration: 300,
            path: "Artist 2/Album/Song B.mp3", energyBucket: 5, lufsI: -10.0
        )

        try dbQueue.write { db in
            var t1 = track1; try t1.insert(db)
            var t2 = track2; try t2.insert(db)
        }

        // Like both tracks
        _ = try likesService.toggleLike(trackUUID: "UUID-A")
        _ = try likesService.toggleLike(trackUUID: "UUID-B")

        // Materialize
        let tracksByUUID = ["UUID-A": track1, "UUID-B": track2]
        try likesService.materializeLikedPlaylist(to: tempDir, tracksByUUID: tracksByUUID)

        // Read the file
        let fileURL = tempDir.appendingPathComponent("Liked.m3u8")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let data = try Data(contentsOf: fileURL)
        let content = String(data: data, encoding: .utf8)!

        // Verify content
        XCTAssertTrue(content.hasPrefix("#EXTM3U"))
        XCTAssertTrue(content.contains("#EXTMLM-PLAYLIST:"))
        XCTAssertTrue(content.contains("#EXTMLM:UUID-A"))
        XCTAssertTrue(content.contains("#EXTMLM:UUID-B"))
        XCTAssertTrue(content.contains("Artist 1/Album/Song A.m4a"))
        XCTAssertTrue(content.contains("Artist 2/Album/Song B.mp3"))

        // Parse back
        let parsed = try engine.parse(url: fileURL)
        XCTAssertNotNil(parsed.playlistUUID)
        XCTAssertEqual(parsed.entries.count, 2)

        let parsedUUIDs = Set(parsed.entries.compactMap { $0.trackUUID })
        XCTAssertEqual(parsedUUIDs, Set(["UUID-A", "UUID-B"]))
    }

    /// Empty likes still writes the file with header only.
    func testEmptyLikesWritesFileWithHeader() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // No likes — materialize anyway
        try likesService.materializeLikedPlaylist(to: tempDir, tracksByUUID: [:])

        let fileURL = tempDir.appendingPathComponent("Liked.m3u8")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let data = try Data(contentsOf: fileURL)
        let content = String(data: data, encoding: .utf8)!

        // Header present
        XCTAssertTrue(content.hasPrefix("#EXTM3U"))
        XCTAssertTrue(content.contains("#EXTMLM-PLAYLIST:"))

        // No entries
        let parsed = try engine.parse(url: fileURL)
        XCTAssertTrue(parsed.entries.isEmpty)
        XCTAssertNotNil(parsed.playlistUUID)
    }

    /// Stable UUID persists across materializations.
    func testStablePlaylistUUID() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try likesService.materializeLikedPlaylist(to: tempDir, tracksByUUID: [:])
        let file1 = try String(contentsOf: tempDir.appendingPathComponent("Liked.m3u8"), encoding: .utf8)

        _ = try likesService.toggleLike(trackUUID: "T1")
        try likesService.materializeLikedPlaylist(to: tempDir, tracksByUUID: [:])
        let file2 = try String(contentsOf: tempDir.appendingPathComponent("Liked.m3u8"), encoding: .utf8)

        // Extract UUIDs
        let uuid1 = file1.components(separatedBy: "#EXTMLM-PLAYLIST:").dropFirst().first?.components(separatedBy: "\n").first
        let uuid2 = file2.components(separatedBy: "#EXTMLM-PLAYLIST:").dropFirst().first?.components(separatedBy: "\n").first

        XCTAssertEqual(uuid1, uuid2, "Playlist UUID must be stable across materializations")
    }

    /// Write-back keeps #EXTMLM lines for every entry.
    func testWriteBackKeepsEXTMLMForEveryEntry() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let track = IndexedTrack(
            id: nil, uuid: "UUID-X", title: "X", artist: "A",
            albumArtist: "A", album: "Al", duration: 100,
            path: "A/Al/X.mp3", energyBucket: 2, lufsI: -16.0
        )
        try dbQueue.write { db in var t = track; try t.insert(db) }

        _ = try likesService.toggleLike(trackUUID: "UUID-X")
        try likesService.materializeLikedPlaylist(to: tempDir, tracksByUUID: ["UUID-X": track])

        let content = try String(contentsOf: tempDir.appendingPathComponent("Liked.m3u8"), encoding: .utf8)
        let extmlmCount = content.components(separatedBy: "#EXTMLM:").count - 1
        XCTAssertEqual(extmlmCount, 1, "Must have exactly one #EXTMLM line per entry")
        XCTAssertTrue(content.contains("#EXTMLM:UUID-X"))
    }
}
