import XCTest
import GRDB
@testable import MLMMobile

final class PlaylistEngineTests: XCTestCase {

    private var engine: PlaylistEngine!
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
    }

    override func tearDown() async throws {
        engine = nil
        dbQueue = nil
        if let url = tempDBURL {
            try? FileManager.default.removeItem(at: url)
        }
        try await super.tearDown()
    }

    // MARK: - Parsing

    /// Parse fixture per spec §2: uuid association, ordering, header uuid.
    func testParseSpecFixture() {
        let content = """
        #EXTM3U
        #EXTMLM-PLAYLIST:AA11BB22-CC33-DD44-EE55-FF6677889900
        #EXTINF:254,Test Artist - Test Song
        #EXTMLM:TRACK-UUID-1
        Test Artist/Test Album/Test Song.m4a
        #EXTINF:180,Ambient Artist - Chill Track
        #EXTMLM:TRACK-UUID-2
        Ambient Artist/Ambient Album/Chill Track.mp3

        """

        let parsed = engine.parse(content: content)

        XCTAssertEqual(parsed.playlistUUID, "AA11BB22-CC33-DD44-EE55-FF6677889900")
        XCTAssertEqual(parsed.entries.count, 2)

        XCTAssertEqual(parsed.entries[0].trackUUID, "TRACK-UUID-1")
        XCTAssertEqual(parsed.entries[0].path, "Test Artist/Test Album/Test Song.m4a")
        XCTAssertEqual(parsed.entries[0].extinfLine, "#EXTINF:254,Test Artist - Test Song")

        XCTAssertEqual(parsed.entries[1].trackUUID, "TRACK-UUID-2")
        XCTAssertEqual(parsed.entries[1].path, "Ambient Artist/Ambient Album/Chill Track.mp3")
        XCTAssertEqual(parsed.entries[1].extinfLine, "#EXTINF:180,Ambient Artist - Chill Track")
    }

    /// Unknown-comment preservation roundtrip (parse→write→parse identical).
    func testUnknownCommentPreservationRoundtrip() {
        let content = """
        #EXTM3U
        #EXTMLM-PLAYLIST:PLAYLIST-UUID-1
        #EXTENC:utf-8
        #EXTIMG:cover.jpg
        #EXTINF:200,Artist - Song A
        #EXTMLM:UUID-A
        Artist/Album/Song A.mp3
        #EXTBYZ:user@example.com
        #EXTINF:300,Artist - Song B
        #EXTMLM:UUID-B
        Artist/Album/Song B.mp3

        """

        let parsed1 = engine.parse(content: content)
        let serialized = engine.serialize(parsed1)
        let parsed2 = engine.parse(content: serialized)

        XCTAssertEqual(parsed1, parsed2, "parse→write→parse must be identical")
        XCTAssertEqual(parsed2.playlistUUID, "PLAYLIST-UUID-1")
        XCTAssertEqual(parsed2.entries.count, 2)

        // Header comments preserved
        XCTAssertTrue(parsed2.headerComments.contains("#EXTENC:utf-8"))
        XCTAssertTrue(parsed2.headerComments.contains("#EXTIMG:cover.jpg"))

        // Entry-level unknown comments preserved
        XCTAssertEqual(parsed2.entries[1].precedingComments, ["#EXTBYZ:user@example.com"])
    }

    func testParseEmptyPlaylist() {
        let content = """
        #EXTM3U
        #EXTMLM-PLAYLIST:EMPTY-UUID

        """
        let parsed = engine.parse(content: content)
        XCTAssertEqual(parsed.playlistUUID, "EMPTY-UUID")
        XCTAssertTrue(parsed.entries.isEmpty)
    }

    func testParseNoPlaylistUUID() {
        let content = """
        #EXTM3U
        #EXTINF:100,Artist - Title
        path/to/file.mp3

        """
        let parsed = engine.parse(content: content)
        XCTAssertNil(parsed.playlistUUID)
        XCTAssertEqual(parsed.entries.count, 1)
        XCTAssertEqual(parsed.entries[0].path, "path/to/file.mp3")
    }

    // MARK: - Serialization

    func testWriteBackKeepsEXTMLMLines() {
        let parsed = ParsedPlaylist(
            playlistUUID: "PL-UUID",
            headerComments: [],
            entries: [
                ParsedEntry(extinfLine: "#EXTINF:200,A - T1", trackUUID: "T-UUID-1", path: "A/B/T1.mp3", precedingComments: []),
                ParsedEntry(extinfLine: "#EXTINF:300,A - T2", trackUUID: "T-UUID-2", path: "A/B/T2.mp3", precedingComments: [])
            ]
        )

        let output = engine.serialize(parsed)

        XCTAssertTrue(output.hasPrefix("#EXTM3U\n"))
        XCTAssertTrue(output.contains("#EXTMLM-PLAYLIST:PL-UUID"))
        XCTAssertTrue(output.contains("#EXTMLM:T-UUID-1"))
        XCTAssertTrue(output.contains("#EXTMLM:T-UUID-2"))
        XCTAssertTrue(output.contains("A/B/T1.mp3"))
        XCTAssertTrue(output.contains("A/B/T2.mp3"))

        // Every entry has an #EXTMLM line
        let extmlmCount = output.components(separatedBy: "#EXTMLM:").count - 1
        XCTAssertEqual(extmlmCount, 2, "Write-back must keep #EXTMLM lines for every entry")
    }

    func testSerializeNFCNormalization() {
        // e + combining acute → should be NFC normalized to é
        let decomposed = "e\u{0301}"  // NFD
        let parsed = ParsedPlaylist(
            playlistUUID: "UUID",
            headerComments: [],
            entries: [
                ParsedEntry(extinfLine: nil, trackUUID: "T1", path: "path/\(decomposed).mp3", precedingComments: [])
            ]
        )

        let output = engine.serialize(parsed)
        let expected = "e\u{0301}".precomposedStringWithCanonicalMapping
        XCTAssertTrue(output.contains(expected))
    }

    // MARK: - Incremental sync

    /// Unchanged file = no state churn.
    func testSyncUnchangedFileIsNoOp() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let content = """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-1
        #EXTINF:200,A - T1
        #EXTMLM:UUID-1
        A/B/T1.mp3
        #EXTINF:300,A - T2
        #EXTMLM:UUID-2
        A/B/T2.mp3

        """
        let fileURL = tempDir.appendingPathComponent("Test.m3u8")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        // First sync: creates the playlist
        let result1 = try engine.syncFromFolder(playlistsDirectory: tempDir)
        XCTAssertEqual(result1.updated, 1)

        let playlists = try engine.fetchAllPlaylists()
        XCTAssertEqual(playlists.count, 1)
        let entries = try engine.fetchEntries(playlistID: playlists[0].id!)
        XCTAssertEqual(entries.count, 2)

        // Second sync: unchanged file = no-op
        let result2 = try engine.syncFromFolder(playlistsDirectory: tempDir)
        XCTAssertEqual(result2.unchanged, 1)
        XCTAssertEqual(result2.updated, 0)

        // Entries unchanged
        let entries2 = try engine.fetchEntries(playlistID: playlists[0].id!)
        XCTAssertEqual(entries2.count, 2)
        XCTAssertEqual(entries2.map { $0.trackUUID }, ["UUID-1", "UUID-2"])
    }

    /// Added entries are applied correctly.
    func testSyncAddedEntries() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Initial file with 2 entries
        let content1 = """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-1
        #EXTINF:200,A - T1
        #EXTMLM:UUID-1
        A/B/T1.mp3
        #EXTINF:300,A - T2
        #EXTMLM:UUID-2
        A/B/T2.mp3

        """
        let fileURL = tempDir.appendingPathComponent("Test.m3u8")
        try content1.write(to: fileURL, atomically: true, encoding: .utf8)

        _ = try engine.syncFromFolder(playlistsDirectory: tempDir)

        // Updated file with 3 entries (added UUID-3)
        let content2 = """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-1
        #EXTINF:200,A - T1
        #EXTMLM:UUID-1
        A/B/T1.mp3
        #EXTINF:300,A - T2
        #EXTMLM:UUID-2
        A/B/T2.mp3
        #EXTINF:150,A - T3
        #EXTMLM:UUID-3
        A/B/T3.mp3

        """
        try content2.write(to: fileURL, atomically: true, encoding: .utf8)

        let result = try engine.syncFromFolder(playlistsDirectory: tempDir)
        XCTAssertEqual(result.updated, 1)

        let playlists = try engine.fetchAllPlaylists()
        let entries = try engine.fetchEntries(playlistID: playlists[0].id!)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map { $0.trackUUID }, ["UUID-1", "UUID-2", "UUID-3"])
    }

    /// Removed entries are applied correctly.
    func testSyncRemovedEntries() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let content1 = """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-1
        #EXTINF:200,A - T1
        #EXTMLM:UUID-1
        A/B/T1.mp3
        #EXTINF:300,A - T2
        #EXTMLM:UUID-2
        A/B/T2.mp3
        #EXTINF:150,A - T3
        #EXTMLM:UUID-3
        A/B/T3.mp3

        """
        let fileURL = tempDir.appendingPathComponent("Test.m3u8")
        try content1.write(to: fileURL, atomically: true, encoding: .utf8)
        _ = try engine.syncFromFolder(playlistsDirectory: tempDir)

        // Remove UUID-2
        let content2 = """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-1
        #EXTINF:200,A - T1
        #EXTMLM:UUID-1
        A/B/T1.mp3
        #EXTINF:150,A - T3
        #EXTMLM:UUID-3
        A/B/T3.mp3

        """
        try content2.write(to: fileURL, atomically: true, encoding: .utf8)
        _ = try engine.syncFromFolder(playlistsDirectory: tempDir)

        let playlists = try engine.fetchAllPlaylists()
        let entries = try engine.fetchEntries(playlistID: playlists[0].id!)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map { $0.trackUUID }, ["UUID-1", "UUID-3"])
    }

    /// Reordered entries are applied correctly.
    func testSyncReorderedEntries() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let content1 = """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-1
        #EXTINF:200,A - T1
        #EXTMLM:UUID-1
        A/B/T1.mp3
        #EXTINF:300,A - T2
        #EXTMLM:UUID-2
        A/B/T2.mp3

        """
        let fileURL = tempDir.appendingPathComponent("Test.m3u8")
        try content1.write(to: fileURL, atomically: true, encoding: .utf8)
        _ = try engine.syncFromFolder(playlistsDirectory: tempDir)

        // Swap order
        let content2 = """
        #EXTM3U
        #EXTMLM-PLAYLIST:PL-1
        #EXTINF:300,A - T2
        #EXTMLM:UUID-2
        A/B/T2.mp3
        #EXTINF:200,A - T1
        #EXTMLM:UUID-1
        A/B/T1.mp3

        """
        try content2.write(to: fileURL, atomically: true, encoding: .utf8)
        _ = try engine.syncFromFolder(playlistsDirectory: tempDir)

        let playlists = try engine.fetchAllPlaylists()
        let entries = try engine.fetchEntries(playlistID: playlists[0].id!)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map { $0.trackUUID }, ["UUID-2", "UUID-1"])
    }

    // MARK: - Local edits

    func testAddAndRemoveEntry() throws {
        // Create a playlist in DB
        var playlist = LocalPlaylist(id: nil, uuid: "PL-LOCAL", name: "Local", file: "Local.m3u8")
        try dbQueue.write { db in try playlist.insert(db) }

        try engine.addEntry(playlistID: playlist.id!, trackUUID: "T1", relativePath: "a/b.mp3")
        try engine.addEntry(playlistID: playlist.id!, trackUUID: "T2", relativePath: "c/d.mp3")

        var entries = try engine.fetchEntries(playlistID: playlist.id!)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].trackUUID, "T1")
        XCTAssertEqual(entries[1].trackUUID, "T2")

        // Remove first
        try engine.removeEntry(entryID: entries[0].id!)
        entries = try engine.fetchEntries(playlistID: playlist.id!)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].trackUUID, "T2")
    }

    func testReorderEntries() throws {
        var playlist = LocalPlaylist(id: nil, uuid: "PL-REORDER", name: "Reorder", file: nil)
        try dbQueue.write { db in try playlist.insert(db) }

        try engine.addEntry(playlistID: playlist.id!, trackUUID: "T1", relativePath: "a.mp3")
        try engine.addEntry(playlistID: playlist.id!, trackUUID: "T2", relativePath: "b.mp3")
        try engine.addEntry(playlistID: playlist.id!, trackUUID: "T3", relativePath: "c.mp3")

        let entries = try engine.fetchEntries(playlistID: playlist.id!)
        let reversedIDs = entries.map { $0.id! }.reversed()
        try engine.reorderEntries(playlistID: playlist.id!, entryIDs: Array(reversedIDs))

        let reordered = try engine.fetchEntries(playlistID: playlist.id!)
        XCTAssertEqual(reordered.map { $0.trackUUID }, ["T3", "T2", "T1"])
    }
}
