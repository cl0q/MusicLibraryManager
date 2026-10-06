import Foundation
import GRDB
import Testing
@testable import MLM

/// `v50_album_tracks` (W4-1, IMP-067). Temporary databases only; foreign keys off.
@Suite("AlbumTracksMigrationTests")
struct AlbumTracksMigrationTests {
    static let v50 = "v50_album_tracks"
    static let previous = "v55_reel_state"

    static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = false
        return config
    }

    /// A database as v49/v55 left it: nothing links tracks to albums but the v16 backfill.
    static func preV50() throws -> (DatabaseQueue, DatabaseMigrator) {
        let queue = try DatabaseQueue(configuration: configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: previous)
        return (queue, migrator)
    }

    @discardableResult
    static func insertTrack(_ db: Database, title: String, artist: String = "Overmono", albumArtist: String = "",
                            album: String, albumID: Int64? = nil, year: Int? = nil) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO tracks (artist, album_artist, album, title, format, original_path, album_id, year)
            VALUES (?, ?, ?, ?, 'flac', ?, ?, ?)
            """, arguments: [artist, albumArtist, album, title, "/tmp/\(UUID().uuidString).flac", albumID, year])
        return db.lastInsertedRowID
    }

    @Test func freshDatabaseHasTheTableAndTheIndex() throws {
        let queue = try DatabaseManager.inMemory()
        let (columns, indexes) = try queue.read { db in
            (try db.columns(in: "album_tracks").map(\.name), try db.indexes(on: "album_tracks").map(\.name))
        }
        #expect(columns == ["album_id", "track_id", "disc", "position", "track_number"])
        #expect(indexes.contains("idx_album_tracks_track"))
    }

    @Test func registeredOnceAfterTheLatestEarlierMigration() throws {
        let migrations = DatabaseManager.buildMigrator().migrations
        #expect(migrations.filter { $0 == Self.v50 }.count == 1)
        let previousIndex = try #require(migrations.firstIndex(of: Self.previous))
        let index = try #require(migrations.firstIndex(of: Self.v50))
        #expect(previousIndex < index)
    }

    @Test func tracksWithAlbumTextAndNoAlbumIDLinkToOneRowPerName() throws {
        let (queue, migrator) = try Self.preV50()
        let ids: [Int64] = try queue.write { db in
            [try Self.insertTrack(db, title: "A", album: "Good Lies", year: 2022),
             try Self.insertTrack(db, title: "B", album: "good lies"),
             try Self.insertTrack(db, title: "C", album: "GOOD  LIES"),
             // NFC and NFD "é" are one name.
             try Self.insertTrack(db, title: "D", artist: "Beyonc\u{e9}", album: "Caf\u{e9}"),
             try Self.insertTrack(db, title: "E", artist: "Beyonce\u{301}", album: "Cafe\u{301}"),
             try Self.insertTrack(db, title: "F", artist: "Other", album: "Good Lies")]
        }
        try migrator.migrate(queue)
        let links: [Int64?] = try queue.read { db in try ids.map { try Int64.fetchOne(db, sql: "SELECT album_id FROM tracks WHERE id = ?", arguments: [$0]) } }
        #expect(links.allSatisfy { $0 != nil })
        #expect(Set(links[0...2].compactMap { $0 }).count == 1, "case and spacing variants of one name are one album")
        #expect(links[3] == links[4], "NFC and NFD forms are one album")
        #expect(links[5] != links[0], "another artist's album of the same name is another album")
        let year = try queue.read { db in try Int.fetchOne(db, sql: "SELECT year FROM albums WHERE id = ?", arguments: [links[0]!]) }
        #expect(year == 2022)
    }

    @Test func noAlbumTextIsNotAnAlbum() throws {
        let (queue, migrator) = try Self.preV50()
        let id: [Int64] = try queue.write { db in
            [try Self.insertTrack(db, title: "A", album: ""), try Self.insertTrack(db, title: "B", album: "unknown album"),
             try Self.insertTrack(db, title: "C", album: "Unknown Album")]
        }
        try migrator.migrate(queue)
        let (linked, rows) = try queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE album_id IS NOT NULL AND id IN (\(id.map(String.init).joined(separator: ",")))"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album_tracks"))
        }
        #expect(linked == 0)
        #expect(rows == 0)
    }

    @Test func linksToAnExistingAlbumRowInsteadOfCreatingOne() throws {
        let (queue, migrator) = try Self.preV50()
        let (existing, track): (Int64, Int64) = try queue.write { db in
            try db.execute(sql: "INSERT INTO albums (artist, album_artist, title, title_normalized) VALUES ('Overmono','Overmono','Good Lies','goodlies')")
            return (db.lastInsertedRowID, try Self.insertTrack(db, title: "A", albumArtist: "Overmono", album: "good-lies"))
        }
        try migrator.migrate(queue)
        let (link, albums) = try queue.read { db in
            (try Int64.fetchOne(db, sql: "SELECT album_id FROM tracks WHERE id = ?", arguments: [track]),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums"))
        }
        #expect(link == existing)
        #expect(albums == 1)
    }

    @Test func tracksWithAnAlbumIDAreSeededInTitleOrderOnDiscOne() throws {
        let (queue, migrator) = try Self.preV50()
        let (album, ids): (Int64, [Int64]) = try queue.write { db in
            try db.execute(sql: "INSERT INTO albums (artist, album_artist, title, title_normalized) VALUES ('Overmono','Overmono','Good Lies','goodlies')")
            let album = db.lastInsertedRowID
            let ids = [try Self.insertTrack(db, title: "Charlotte", album: "Good Lies", albumID: album),
                       try Self.insertTrack(db, title: "alpha", album: "Good Lies", albumID: album),
                       try Self.insertTrack(db, title: "Bravo", album: "Good Lies", albumID: album)]
            return (album, ids)
        }
        try migrator.migrate(queue)
        let rows = try queue.read { db in try AlbumTrack.fetchAll(db, sql: "SELECT * FROM album_tracks WHERE album_id = ? ORDER BY position", arguments: [album]) }
        #expect(rows.map(\.trackId) == [ids[1], ids[2], ids[0]])
        #expect(rows.allSatisfy { $0.disc == 1 && $0.trackNumber == nil })
        #expect(Set(rows.map(\.position)).count == 3)
    }

    @Test func runningTheBodyAgainChangesNothing() throws {
        let (queue, migrator) = try Self.preV50()
        try queue.write { db in
            try Self.insertTrack(db, title: "A", album: "Good Lies")
            try Self.insertTrack(db, title: "B", album: "Good Lies")
        }
        try migrator.migrate(queue)
        let first = try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM album_tracks ORDER BY track_id").map { "\($0)" } }
        let albums = try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums") }
        try queue.write { db in try AlbumMigrations.v50AlbumTracks(db) }
        let second = try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM album_tracks ORDER BY track_id").map { "\($0)" } }
        #expect(first.count == 2)
        #expect(first == second)
        #expect(try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums") } == albums)
    }

    @Test func aRowThatAlreadyExistsIsKept() throws {
        let (queue, migrator) = try Self.preV50()
        let album: Int64 = try queue.write { db in
            try db.execute(sql: "INSERT INTO albums (artist, album_artist, title, title_normalized) VALUES ('O','O','X','x')")
            let album = db.lastInsertedRowID
            let a = try Self.insertTrack(db, title: "A", album: "X", albumID: album)
            try Self.insertTrack(db, title: "B", album: "X", albumID: album)
            try db.execute(sql: "CREATE TABLE album_tracks (album_id INTEGER NOT NULL, track_id INTEGER NOT NULL, disc INTEGER NOT NULL DEFAULT 1, position TEXT NOT NULL, track_number INTEGER, PRIMARY KEY (album_id, track_id))")
            try db.execute(sql: "INSERT INTO album_tracks VALUES (?, ?, 2, 'zz', 7)", arguments: [album, a])
            return album
        }
        try migrator.migrate(queue)
        let rows = try queue.read { db in try AlbumTrack.fetchAll(db, sql: "SELECT * FROM album_tracks WHERE album_id = ? ORDER BY track_id", arguments: [album]) }
        #expect(rows.count == 2)
        #expect(rows[0].disc == 2 && rows[0].position == "zz" && rows[0].trackNumber == 7)
        #expect(rows[1].position.hasPrefix("zz|"), "the new row sorts after the kept one")
    }

    @Test func upgradeSeesTheMigrationAsPending() throws {
        let (queue, migrator) = try Self.preV50()
        let applied = try queue.read { try migrator.appliedIdentifiers($0) }
        #expect(BackupService.hasPendingMigrations(registered: Set(migrator.migrations), applied: applied))
    }
}
