import Foundation
import GRDB
import Testing
@testable import MLM

/// B1 (W4-1 fix round): rows the Tauri app wrote carry `title_normalized` as `good_lies`; albums
/// are found by the Swift key, and v51 rewrites the stored key.
@Suite("AlbumTauriKeyTests")
struct AlbumTauriKeyTests {
    @discardableResult
    static func tauriAlbum(_ db: Database, artist: String, title: String, stem: String) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO albums (artist, album_artist, title, title_normalized) VALUES (?, ?, ?, ?)
            """, arguments: [artist, artist, title, stem])
        return db.lastInsertedRowID
    }

    @Test func anImportJoinsATauriRowInsteadOfCreatingASecondOne() throws {
        let queue = try DatabaseManager.inMemory()
        try queue.write { db in
            let tauri = try Self.tauriAlbum(db, artist: "Overmono", title: "Good Lies", stem: "good_lies")
            let id = try AlbumTracksMigrationTests.insertTrack(db, title: "New", artist: "overmono", album: "good lies")
            let linked = try AlbumTrackRepository.linkImportedTrack(db, trackID: id, artist: "overmono", albumArtist: "", album: "good lies",
                                                                    year: nil, disc: nil, number: nil)
            #expect(linked == tauri)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums") == 1)
        }
    }

    @Test func v51RewritesTheStoredKeyToTheSwiftForm() throws {
        let (queue, migrator) = try AlbumDedupMigrationTests.preV51()
        try queue.write { db in
            try Self.tauriAlbum(db, artist: "Overmono", title: "Good Lies", stem: "good_lies")
        }
        try migrator.migrate(queue)
        let stored = try queue.read { db in try String.fetchAll(db, sql: "SELECT title_normalized FROM albums") }
        #expect(stored == ["goodlies"])
    }

    @Test func v50LinksIntoATauriRowAndLeavesOneAlbum() throws {
        let (queue, migrator) = try AlbumTracksMigrationTests.preV50()
        let (tauri, track): (Int64, Int64) = try queue.write { db in
            let tauri = try Self.tauriAlbum(db, artist: "Overmono", title: "Good Lies", stem: "good_lies")
            return (tauri, try AlbumTracksMigrationTests.insertTrack(db, title: "A", artist: "Overmono", album: "Good Lies"))
        }
        try migrator.migrate(queue)
        let (albums, link) = try queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums") ?? 0,
             try Int64.fetchOne(db, sql: "SELECT album_id FROM tracks WHERE id = ?", arguments: [track]))
        }
        #expect(albums == 1)
        #expect(link == tauri)
    }
}
