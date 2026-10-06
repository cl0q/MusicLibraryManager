import Foundation
import GRDB
import Testing
@testable import MLM

/// W3-SET review B2: a scan after the library folder changed (drive renamed, music copied) must
/// not add the library a second time — a file at the same place below the new folder is that
/// track and only its `original_path` is re-pointed. Temporary database, no audio files.
@Suite("Library folder change scan (W3-SET)", .serialized)
struct LibraryFolderChangeScanTests {

    private func metadata(_ path: String, title: String) -> TrackMetadata {
        TrackMetadata(artist: "Artist", albumArtist: "Artist", album: "Album", title: title, genre: nil, year: nil,
                      bitrate: 256, duration: 200, format: "m4a", originalPath: path)
    }

    private func makeService() throws -> (ImportService, DatabaseManager, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderChangeScan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = try DatabaseManager(path: root.appendingPathComponent("music_library.db"))
        return (ImportService(database: manager.pool, trackRepository: TrackRepository(database: manager.pool)), manager, root)
    }

    private func insert(_ db: Database, id: Int64, original: String, organized: String) throws {
        try db.execute(sql: """
            INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, organized_path, date_added)
            VALUES (?, 'Artist', 'Artist', 'Album', 'T', 'm4a', ?, ?, '2020-01-01T00:00:00Z')
            """, arguments: [id, original, organized])
    }

    @Test func aRenamedRootAddsNoRowsAndRepointsTheFiles() async throws {
        let (service, manager, root) = try makeService()
        defer { try? FileManager.default.removeItem(at: root) }
        try await manager.pool.write { db in
            try insert(db, id: 1, original: "/Volumes/A/Music/Artist/Album/01 One.m4a", organized: "Artist/Album/01 One.m4a")
            // organized_path generated differently: matched by the old-folder original_path.
            try insert(db, id: 2, original: "/Volumes/A/Music/Loose/two.m4a", organized: "Elsewhere/two.m4a")
        }
        let remap = LibraryRootRemap(oldRoot: "/Volumes/A/Music", newRoot: "/Volumes/B/Music/")
        let (succeeded, skipped, failures, inserted, _) = await service.saveBatches([
            // Letter case differs from organized_path (case-insensitive volume).
            metadata("/Volumes/B/Music/artist/album/01 one.m4a", title: "One"),
            metadata("/Volumes/B/Music/Loose/two.m4a", title: "Two"),
        ], remap: remap)
        #expect(succeeded == 0 && inserted.isEmpty, "zero new rows")
        #expect(skipped == 2)
        #expect(failures.isEmpty)
        let rows = try await manager.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, original_path, date_added FROM tracks ORDER BY id")
        }
        #expect(rows.count == 2)
        #expect(rows[0]["original_path"] as String == "/Volumes/B/Music/artist/album/01 one.m4a")
        #expect(rows[1]["original_path"] as String == "/Volumes/B/Music/Loose/two.m4a")
        #expect(rows.allSatisfy { ($0["date_added"] as String) == "2020-01-01T00:00:00Z" }, "date_added unchanged")
    }

    @Test func aNewFileIsStillAdded() async throws {
        let (service, manager, root) = try makeService()
        defer { try? FileManager.default.removeItem(at: root) }
        try await manager.pool.write { db in
            try insert(db, id: 1, original: "/Volumes/A/Music/x.m4a", organized: "x.m4a")
        }
        let remap = LibraryRootRemap(oldRoot: "/Volumes/A/Music", newRoot: "/Volumes/B/Music")
        let (succeeded, skipped, _, _, _) = await service.saveBatches([
            metadata("/Volumes/B/Music/x.m4a", title: "X"),
            metadata("/Volumes/B/Music/new.m4a", title: "New"),
        ], remap: remap)
        #expect(succeeded == 1)
        #expect(skipped == 1)
        let count = try await manager.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") }
        #expect(count == 2)
    }

    @Test func withoutARemapNothingIsRepointed() async throws {
        let (service, manager, root) = try makeService()
        defer { try? FileManager.default.removeItem(at: root) }
        try await manager.pool.write { db in
            try insert(db, id: 1, original: "/Volumes/A/Music/x.m4a", organized: "x.m4a")
        }
        let (succeeded, _, _, _, _) = await service.saveBatches([metadata("/Volumes/B/Music/x.m4a", title: "X")])
        #expect(succeeded == 1, "an ordinary import is unchanged")
    }

    @Test func relativePaths() {
        let remap = LibraryRootRemap(oldRoot: "/A/Music/", newRoot: "/B/Music")
        #expect(remap.relativePath(of: "/B/Music/x/y.m4a") == "x/y.m4a")
        #expect(remap.relativePath(of: "/B/Musical/y.m4a") == nil)
        #expect(remap.oldAbsolutePath(forRelative: "x/y.m4a") == "/A/Music/x/y.m4a")
    }
}
