import Foundation
import GRDB
import Testing
@testable import MLM

/// W3-SET review S2: `Reread tags from files` never replaces edits made in MLM — tracks with a
/// pending tag write or a typed field are skipped, and only the tag columns are updated (no
/// full-row write-back); it asks first and can be cancelled.
@Suite("Reread tags safety (W3-SET)", .serialized)
struct RereadTagsSafetyTests {

    private func makeRepository() throws -> (TrackRepository, DatabaseManager, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RereadTags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = try DatabaseManager(path: root.appendingPathComponent("music_library.db"))
        return (TrackRepository(database: manager.pool), manager, root)
    }

    @Test func tracksWithEditsMadeInMLMAreProtected() async throws {
        let (repository, manager, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try await manager.pool.write { db in
            for id in 1...3 {
                try db.execute(sql: """
                    INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, organized_path)
                    VALUES (?, 'A', 'A', 'B', 'T', 'm4a', ?, ?)
                    """, arguments: [id, "/x/\(id).m4a", "\(id).m4a"])
            }
            try db.execute(sql: "INSERT INTO pending_tag_writes (track_id, fields, stale_since) VALUES (1, 'title', '2026-10-01')")
            try db.execute(sql: "INSERT INTO tag_write_fields (track_id, field, intent, typed_value) VALUES (2, 'artist', 'typed', 'Mine')")
            try db.execute(sql: "INSERT INTO tag_write_fields (track_id, field, intent) VALUES (3, 'album', 'original')")
        }
        #expect(try await repository.trackIDsWithTagIntents() == [1, 2])
    }

    @Test func onlyTagColumnsAreUpdated() async throws {
        let (repository, manager, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try await manager.pool.write { db in
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, organized_path, date_added, bpm)
                VALUES (1, 'Old', 'Old', 'Old', 'Old', 'mp3', '/x/1.mp3', '1.mp3', '2020-01-01T00:00:00Z', 128)
                """)
        }
        let metadata = TrackMetadata(artist: "New", albumArtist: "New AA", album: "New Album", title: "New Title",
                                     genre: "House", year: 2024, bitrate: 320, duration: 300, format: "mp3",
                                     originalPath: "/elsewhere/ignored.mp3")
        #expect(try await repository.updateTagColumns(id: 1, from: metadata))
        let row = try #require(try await manager.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = 1")
        })
        #expect(row["title"] as String == "New Title")
        #expect(row["genre"] as String? == "House")
        #expect(row["original_path"] as String == "/x/1.mp3", "the file's place is not a tag")
        #expect(row["date_added"] as String == "2020-01-01T00:00:00Z")
        #expect(row["bpm"] as Double? == 128, "columns outside the read tags stay")
        #expect(!(try await repository.updateTagColumns(id: 99, from: metadata)))
    }

    @Test @MainActor func itAsksFirstWithTheCount() {
        #expect(MaintenanceJobs.rereadTitle(tracks: 12_935) == "Reread tags of \(12_935.formatted()) tracks from their files?")
        #expect(MaintenanceJobs.rereadMessage.hasPrefix("Edits made in MLM that were not written to files are replaced."))
        #expect(MaintenanceJob(action: MaintenanceJob.rereadTags).isCancellable)
        #expect(MenuCommand.rereadTagsFromFiles.title.hasSuffix("…"), "a question follows")
    }
}
