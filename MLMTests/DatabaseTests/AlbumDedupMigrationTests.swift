import Foundation
import GRDB
import Testing
@testable import MLM

/// `v51_album_dedup` (W4-1, IMP-068). Temporary databases only; foreign keys off.
@Suite("AlbumDedupMigrationTests")
struct AlbumDedupMigrationTests {
    static let v51 = "v51_album_dedup"
    static let previous = "v50_album_tracks"

    /// A database at v50: albums that are one album written two ways coexist (the unique index
    /// is case-insensitive for ASCII only and sees `é` / `é` as different bytes).
    static func preV51() throws -> (DatabaseQueue, DatabaseMigrator) {
        let queue = try DatabaseQueue(configuration: AlbumTracksMigrationTests.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: previous)
        return (queue, migrator)
    }

    @discardableResult
    static func album(_ db: Database, artist: String, title: String, variantOf: Int64? = nil, kind: String? = nil,
                      year: Int? = nil, cover: String? = nil) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO albums (artist, album_artist, title, title_normalized, year, cover_path, variant_of, variant_kind)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [artist, artist, title, AlbumKey.normalize(title) + (kind ?? ""), year, cover, variantOf, kind])
        return db.lastInsertedRowID
    }

    /// A track in the album with a join row.
    @discardableResult
    static func member(_ db: Database, _ album: Int64, title: String, position: String, number: Int? = nil, disc: Int = 1) throws -> Int64 {
        let id = try AlbumTracksMigrationTests.insertTrack(db, title: title, album: "X", albumID: album)
        try db.execute(sql: "INSERT INTO album_tracks VALUES (?, ?, ?, ?, ?)", arguments: [album, id, disc, position, number])
        return id
    }

    static let nfc = "Beyonc\u{e9}"
    static let nfd = "Beyonce\u{301}"

    @Test func registeredOnceAfterV50() throws {
        let migrations = DatabaseManager.buildMigrator().migrations
        #expect(migrations.filter { $0 == Self.v51 }.count == 1)
        let v50 = try #require(migrations.firstIndex(of: Self.previous))
        let v51 = try #require(migrations.firstIndex(of: Self.v51))
        #expect(v50 < v51)
    }

    @Test func theRowWithTheMostTracksSurvivesTiesGoToTheLowestID() throws {
        let (queue, migrator) = try Self.preV51()
        let (small, big, tieA, tieB): (Int64, Int64, Int64, Int64) = try queue.write { db in
            let small = try Self.album(db, artist: Self.nfc, title: "Lemonade")
            let big = try Self.album(db, artist: Self.nfd, title: "LEMONADE")
            try Self.member(db, small, title: "a", position: "a1")
            for (i, p) in ["a1", "a2", "a3"].enumerated() { try Self.member(db, big, title: "b\(i)", position: p) }
            let tieA = try Self.album(db, artist: "Åsa", title: "Same")
            let tieB = try Self.album(db, artist: "A\u{30a}sa", title: "Same")
            try Self.member(db, tieA, title: "t1", position: "a1")
            try Self.member(db, tieB, title: "t2", position: "a1")
            return (small, big, tieA, tieB)
        }
        try migrator.migrate(queue)
        let survivors = try queue.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM albums ORDER BY id") }
        #expect(survivors == [big, tieA], "most tracks wins; a tie keeps the lowest id")
        #expect(!survivors.contains(small) && !survivors.contains(tieB))
        let log = try queue.read { db in try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = 'albums.dedup.v51'") }
        let decoded = try JSONDecoder().decode([String: Int64].self, from: Data(try #require(log).utf8))
        #expect(decoded == [String(small): big, String(tieB): tieA])
    }

    @Test func tracksJoinsPreferencesAndVariantsAreRepointed() throws {
        let (queue, migrator) = try Self.preV51()
        let ids: (win: Int64, lose: Int64, shared: Int64, variant: Int64, loserOnly: Int64) = try queue.write { db in
            let win = try Self.album(db, artist: Self.nfc, title: "Lemonade", year: nil, cover: nil)
            let lose = try Self.album(db, artist: Self.nfd, title: "Lemonade", year: 2016, cover: "cover.jpg")
            let shared = try Self.member(db, win, title: "shared", position: "a1")
            try Self.member(db, win, title: "w2", position: "a2")
            // The shared track is a row of both albums (join), plus one only the loser has.
            try db.execute(sql: "INSERT INTO album_tracks VALUES (?, ?, 1, 'a1', 5)", arguments: [lose, shared])
            let loserOnly = try Self.member(db, lose, title: "l1", position: "a2", number: 7)
            let variant = try Self.album(db, artist: Self.nfd, title: "Lemonade", variantOf: lose, kind: "deluxe")
            try db.execute(sql: "INSERT INTO user_album_variant_pref VALUES ('default', ?, ?, 'now')", arguments: [lose, variant])
            try db.execute(sql: "INSERT INTO user_album_variant_pref VALUES ('other', ?, ?, 'now')", arguments: [win, lose])
            return (win, lose, shared, variant, loserOnly)
        }
        try migrator.migrate(queue)
        try queue.read { db in
            #expect(try Int64.fetchOne(db, sql: "SELECT album_id FROM tracks WHERE id = ?", arguments: [ids.loserOnly]) == ids.win, "tracks.album_id")
            let rows = try AlbumTrack.fetchAll(db, sql: "SELECT * FROM album_tracks ORDER BY disc, position, track_id")
            #expect(Set(rows.map(\.albumId)) == [ids.win], "album_tracks")
            #expect(rows.count == 3, "the shared track has one row")
            #expect(rows.last?.trackId == ids.loserOnly)
            #expect(try Int.fetchOne(db, sql: "SELECT track_number FROM album_tracks WHERE track_id = ?", arguments: [ids.loserOnly]) == 7)
            #expect(try Int64.fetchOne(db, sql: "SELECT base_album_id FROM user_album_variant_pref WHERE user_id = 'default'") == ids.win, "pref base")
            #expect(try Int64.fetchOne(db, sql: "SELECT selected_album_id FROM user_album_variant_pref WHERE user_id = 'other'") == ids.win, "pref selected")
            #expect(try Int64.fetchOne(db, sql: "SELECT variant_of FROM albums WHERE id = ?", arguments: [ids.variant]) == ids.win, "variant_of")
            #expect(try Int.fetchOne(db, sql: "SELECT year FROM albums WHERE id = ?", arguments: [ids.win]) == 2016, "year fills in")
            #expect(try String.fetchOne(db, sql: "SELECT cover_path FROM albums WHERE id = ?", arguments: [ids.win]) == "cover.jpg")
        }
    }

    @Test func aWinnerThatHasAPreferenceKeepsIt() throws {
        let (queue, migrator) = try Self.preV51()
        let (win, variantA): (Int64, Int64) = try queue.write { db in
            let win = try Self.album(db, artist: Self.nfc, title: "L")
            let lose = try Self.album(db, artist: Self.nfd, title: "L")
            let a = try Self.album(db, artist: Self.nfc, title: "L", variantOf: win, kind: "deluxe")
            let b = try Self.album(db, artist: Self.nfd, title: "L", variantOf: lose, kind: "remaster")
            try Self.member(db, win, title: "x", position: "a1")
            try db.execute(sql: "INSERT INTO user_album_variant_pref VALUES ('default', ?, ?, 'now')", arguments: [win, a])
            try db.execute(sql: "INSERT INTO user_album_variant_pref VALUES ('default', ?, ?, 'now')", arguments: [lose, b])
            return (win, a)
        }
        try migrator.migrate(queue)
        let prefs = try queue.read { db in try Row.fetchAll(db, sql: "SELECT base_album_id, selected_album_id FROM user_album_variant_pref") }
        #expect(prefs.count == 1)
        #expect(prefs.first?["base_album_id"] as Int64? == win && prefs.first?["selected_album_id"] as Int64? == variantA)
    }

    @Test func variantsAreNeverMergedIntoTheirBase() throws {
        let (queue, migrator) = try Self.preV51()
        let (base, deluxe, remaster): (Int64, Int64, Int64) = try queue.write { db in
            let base = try Self.album(db, artist: Self.nfc, title: "Lemonade")
            let deluxe = try Self.album(db, artist: Self.nfc, title: "Lemonade", variantOf: base, kind: "deluxe")
            let remaster = try Self.album(db, artist: Self.nfd, title: "Lemonade", variantOf: base, kind: "remaster")
            try Self.member(db, deluxe, title: "d", position: "a1")
            return (base, deluxe, remaster)
        }
        try migrator.migrate(queue)
        let rows = try queue.read { db in try Row.fetchAll(db, sql: "SELECT id, variant_of, variant_kind FROM albums ORDER BY id") }
        #expect(rows.map { $0["id"] as Int64 } == [base, deluxe, remaster])
        #expect(rows.map { $0["variant_of"] as Int64? } == [nil, base, base])
        #expect(try queue.read { db in try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = 'albums.dedup.v51'") } == nil, "nothing merged, no log")
    }

    @Test func runningTheBodyAgainChangesNothing() throws {
        let (queue, migrator) = try Self.preV51()
        try queue.write { db in
            let a = try Self.album(db, artist: Self.nfc, title: "L")
            let b = try Self.album(db, artist: Self.nfd, title: "L")
            try Self.member(db, a, title: "x", position: "a1")
            try Self.member(db, b, title: "y", position: "a1")
        }
        try migrator.migrate(queue)
        func state() throws -> [String] {
            try queue.read { db in
                try Row.fetchAll(db, sql: "SELECT 'a', id, title FROM albums UNION ALL SELECT 'j', track_id, position FROM album_tracks UNION ALL SELECT 'l', 0, value FROM app_config WHERE key = 'albums.dedup.v51'")
                    .map { "\($0)" }
            }
        }
        let first = try state()
        try queue.write { db in try AlbumMigrations.v51AlbumDedup(db) }
        #expect(try state() == first)
        #expect(first.count == 4)
    }

    // MARK: The real migrator on a copy (W3-LAUNCH's approach)

    @Test func theRealMigratorOnACopyTakesThePreMigrationBackupAndMerges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AlbumDedupMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A fixture shaped like a v55 database: tracks with album text and no album_id, plus
        // two albums that are one album.
        let fixture = root.appendingPathComponent("fixture.db")
        do {
            let queue = try DatabaseQueue(path: fixture.path, configuration: AlbumTracksMigrationTests.configuration)
            try DatabaseManager.buildMigrator().migrate(queue, upTo: AlbumTracksMigrationTests.previous)
            try queue.write { db in
                try Self.album(db, artist: Self.nfc, title: "Lemonade")
                try Self.album(db, artist: Self.nfd, title: "Lemonade")
                try AlbumTracksMigrationTests.insertTrack(db, title: "Hold Up", artist: Self.nfc, album: "Lemonade")
                try AlbumTracksMigrationTests.insertTrack(db, title: "Sandcastles", artist: Self.nfd, album: "lemonade")
            }
            try queue.close()
        }
        // Work on a copy, never the fixture itself.
        let work = root.appendingPathComponent("library/music_library.db")
        try FileManager.default.createDirectory(at: work.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: work)

        let backups = root.appendingPathComponent("backups")
        let manager = try DatabaseManager(databaseURL: work, backupsRoot: backups)

        let bundles = (FileManager.default.enumerator(atPath: backups.path)?.allObjects as? [String] ?? [])
            .filter { $0.split(separator: "/").last?.hasPrefix("mlm-backup-") == true }
        #expect(bundles.count == 1, "the backup is taken for a database at v49/v55 before v50/v51 run")

        try manager.pool.read { db in
            let applied = try DatabaseManager.buildMigrator().appliedIdentifiers(db)
            #expect(applied.contains("v50_album_tracks") && applied.contains(Self.v51))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums WHERE title = 'Lemonade'") == 1, "one album remains")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album_tracks") == 2)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT album_id) FROM tracks WHERE album_id IS NOT NULL") == 1)
        }
        // The fixture itself is untouched (still at v55, no album_tracks).
        let untouched = try DatabaseQueue(path: fixture.path)
        #expect(try untouched.read { try $0.tableExists("album_tracks") } == false)
    }
}
