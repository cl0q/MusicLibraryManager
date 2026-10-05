import Foundation
import GRDB
import Testing
@testable import MLM

/// `v44_pending_tag_writes` and `TrackTagRepository` (W2-E) on temporary databases.
@Suite("TrackTagRepository")
struct TrackTagRepositoryTests {
    static let v42 = "v42_track_availability"
    static let v44 = "v44_pending_tag_writes"

    static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = false
        return config
    }

    /// Inserts tracks; `path(i)` gives the organized path (nil = not downloaded).
    static func seed(_ db: some DatabaseWriter, count: Int, path: (Int) -> String? = { "Artist/\($0).mp3" }) throws -> [Int64] {
        try db.write { db in
            (0..<count).map { index in
                try? db.execute(sql: """
                    INSERT INTO tracks (artist, album_artist, album, title, genre, year, bpm, format, original_path, organized_path, is_duplicate)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'mp3', ?, ?, 0)
                    """, arguments: [
                        "Artist \(index % 7)", "Artist \(index % 7)", index % 3 == 0 ? "unknown album" : "Album \(index % 5)",
                        "Title \(index)", index % 4 == 0 ? nil : "Genre \(index % 6)", index % 5 == 0 ? nil : 1990 + index % 30,
                        index % 2 == 0 ? nil : 100 + index % 40, "/orig/\(index).mp3", path(index),
                    ])
                return db.lastInsertedRowID
            }
        }
    }

    // MARK: Migration

    @Test func freshDatabaseHasThePendingTable() throws {
        let db = try DatabaseManager.inMemory()
        let columns = try db.read { try $0.columns(in: "pending_tag_writes") }
        #expect(columns.map(\.name) == ["track_id", "fields", "stale_since", "revision", "attempts", "last_attempt_at", "last_error", "blocked"])
        let primaryKey = try db.read { try $0.primaryKey("pending_tag_writes") }
        #expect(primaryKey.columns == ["track_id"])
    }

    @Test func registeredOnceAfterV42() throws {
        let migrations = DatabaseManager.buildMigrator().migrations
        #expect(migrations.filter { $0 == Self.v44 }.count == 1)
        let v42Index = try #require(migrations.firstIndex(of: Self.v42))
        let v44Index = try #require(migrations.firstIndex(of: Self.v44))
        #expect(v42Index < v44Index)
    }

    @Test func upgradeFromV42KeepsTracksAndStartsEmpty() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.v42)
        let ids = try Self.seed(queue, count: 20)
        let applied = try queue.read { try migrator.appliedIdentifiers($0) }
        #expect(BackupService.hasPendingMigrations(registered: Set(migrator.migrations), applied: applied),
                "the pre-migration backup sees v44 as pending")
        try migrator.migrate(queue)
        let (tracks, pending) = try queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_tag_writes") ?? -1)
        }
        #expect(tracks == ids.count)
        #expect(pending == 0)
    }

    @Test func migrationIsIdempotentWhenTheTableAlreadyExists() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.v42)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE pending_tag_writes (track_id INTEGER PRIMARY KEY NOT NULL, fields TEXT NOT NULL,
                stale_since TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1, attempts INTEGER NOT NULL DEFAULT 0,
                last_attempt_at TEXT, last_error TEXT, blocked INTEGER NOT NULL DEFAULT 0)
                """)
            try db.execute(sql: "INSERT INTO pending_tag_writes (track_id, fields, stale_since) VALUES (1, 'genre', 'x')")
        }
        try migrator.migrate(queue)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pending_tag_writes") } == 1)
        try migrator.migrate(queue) // nothing pending: a no-op
    }

    @Test func v53FreshUpgradeAndIdempotent() throws {
        let fresh = try DatabaseManager.inMemory()
        let columns = try fresh.read { try $0.columns(in: "tag_write_fields") }.map(\.name)
        #expect(columns == ["track_id", "field", "intent", "typed_value", "original_state", "original_value", "original_captured_at"])
        #expect(try fresh.read { try $0.primaryKey("tag_write_fields") }.columns == ["track_id", "field"])
        let migrations = DatabaseManager.buildMigrator().migrations
        #expect(migrations.filter { $0 == "v53_tag_write_originals" }.count == 1)
        #expect(try #require(migrations.firstIndex(of: Self.v44)) < #require(migrations.firstIndex(of: "v53_tag_write_originals")))
        // Upgrade from v44 with a waiting write: kept; the new table starts empty.
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.v44)
        let ids = try Self.seed(queue, count: 2)
        try queue.write { try $0.execute(sql: "INSERT INTO pending_tag_writes (track_id, fields, stale_since) VALUES (?, 'genre', 'x')", arguments: [ids[0]]) }
        try queue.write { try $0.execute(sql: "CREATE TABLE tag_write_fields (track_id INTEGER NOT NULL, field TEXT NOT NULL, intent TEXT NOT NULL, typed_value TEXT, original_state TEXT NOT NULL DEFAULT 'unknown', original_value TEXT, original_captured_at TEXT, PRIMARY KEY (track_id, field))") }
        try migrator.migrate(queue) // the table already exists: IF NOT EXISTS
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pending_tag_writes") } == 1)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tag_write_fields") } == 0)
    }

    @Test func foreignKeysStayDisabled() throws {
        let db = try DatabaseManager.inMemory()
        #expect(try db.read { try Bool.fetchOne($0, sql: "PRAGMA foreign_keys") } == false)
    }

    // MARK: Edits

    @Test func applyChangesOnlyDifferingTracksAndReturnsExactPreviousValues() async throws {
        let db = try DatabaseManager.inMemory()
        let ids = try Self.seed(db, count: 12)
        let repository = TrackTagRepository(database: db)
        let before = try await repository.fetchTracks(ids: ids)
        let result = try await repository.apply(.text("Techno"), to: .genre, trackIDs: ids, queueFileWrites: false)
        let unchanged = before.filter { $0.genre == "Techno" }.count
        #expect(result.changedCount == ids.count - unchanged)
        for snapshot in result.previous {
            let old = try #require(before.first { $0.id == snapshot.trackID })
            #expect(snapshot.value == .text(old.genre))
        }
        let after = try await repository.fetchTracks(ids: ids)
        #expect(after.allSatisfy { $0.genre == "Techno" })
        #expect(after.allSatisfy { $0.searchText?.contains("techno") == true }, "search text follows the edit")
        // Undo: every track back to its own value (nil genres stay nil).
        _ = try await repository.restore(result.previous, field: .genre, queueFileWrites: false)
        let restored = try await repository.fetchTracks(ids: ids)
        #expect(restored.map(\.genre) == before.map(\.genre))
        #expect(restored.map(\.searchText) == before.map { DatabaseManager.foldedSearchText($0.rawSearchText) })
    }

    @Test func analysedBPMNeverReplacesATypedOne() async throws {
        let db = try DatabaseManager.inMemory()
        let ids = try Self.seed(db, count: 2)
        let repository = TrackTagRepository(database: db)
        _ = try await repository.apply(.number(nil), to: .bpm, trackIDs: ids, queueFileWrites: false)
        _ = try await repository.apply(.number(174), to: .bpm, trackIDs: [ids[0]], queueFileWrites: true) // typed meanwhile
        let pendingBefore = try await repository.pendingCount()
        #expect(try await repository.fillBPMIfEmpty(trackID: ids[0], bpm: 87) == false)
        #expect(try await repository.fillBPMIfEmpty(trackID: ids[1], bpm: 128))
        #expect(try await repository.fetchTracks(ids: ids).map(\.bpm) == [174, 128])
        #expect(try await repository.pendingCount() == pendingBefore, "analysis never queues a file write")
    }

    @Test func numericAndRequiredTextFields() async throws {
        let db = try DatabaseManager.inMemory()
        let ids = try Self.seed(db, count: 3)
        let repository = TrackTagRepository(database: db)
        _ = try await repository.apply(.number(nil), to: .year, trackIDs: ids, queueFileWrites: false)
        #expect(try await repository.fetchTracks(ids: ids).allSatisfy { $0.year == nil })
        _ = try await repository.apply(.number(2019), to: .year, trackIDs: ids, queueFileWrites: false)
        #expect(try await repository.fetchTracks(ids: ids).allSatisfy { $0.year == 2019 })
        _ = try await repository.apply(.text(""), to: .album, trackIDs: ids, queueFileWrites: false)
        #expect(try await repository.fetchTracks(ids: ids).allSatisfy { $0.album.isEmpty }, "NOT NULL text columns take an empty string")
        let none = try await repository.apply(.text(""), to: .album, trackIDs: ids, queueFileWrites: false)
        #expect(none.changedCount == 0)
    }

    @Test func onlyFilesInWritableFormatsAreQueued() async throws {
        let db = try DatabaseManager.inMemory()
        let paths: [String?] = ["A/1.mp3", "A/2.wav", nil, "A/4.m4a", "A/5.flac"]
        let ids = try Self.seed(db, count: paths.count) { paths[$0] }
        let repository = TrackTagRepository(database: db)
        let genre = try await repository.apply(.text("Dub"), to: .genre, trackIDs: ids, queueFileWrites: true)
        #expect(genre.queuedForFiles == 3)
        #expect(genre.unsupported == ["WAV isn’t supported": 1])
        let bpm = try await repository.apply(.number(140), to: .bpm, trackIDs: ids, queueFileWrites: true)
        #expect(bpm.unsupported["BPM can’t be written to M4A files"] == 1)
        let pending = try await repository.pendingWrites(limit: 10)
        #expect(Set(pending.map(\.trackID)) == [ids[0], ids[3], ids[4]])
        #expect(pending.first { $0.trackID == ids[0] }?.fields == [.genre, .bpm])
        #expect(pending.first { $0.trackID == ids[3] }?.fields == [.genre])
        #expect(try await repository.pendingCount() == 3)
        #expect(try await repository.pendingTrackIDs(among: ids) == [ids[0], ids[3], ids[4]])
    }

    @Test func revisionGuardsAWriteAgainstANewerEdit() async throws {
        let db = try DatabaseManager.inMemory()
        let ids = try Self.seed(db, count: 1)
        let repository = TrackTagRepository(database: db)
        _ = try await repository.apply(.text("A"), to: .genre, trackIDs: ids, queueFileWrites: true)
        let read = try #require(try await repository.pendingWrite(trackID: ids[0]))
        _ = try await repository.apply(.text("B"), to: .genre, trackIDs: ids, queueFileWrites: true) // during the write
        #expect(try await repository.completeWrite(trackID: ids[0], revision: read.revision) == false)
        let newer = try #require(try await repository.pendingWrite(trackID: ids[0]))
        #expect(newer.revision == read.revision + 1)
        #expect(try await repository.completeWrite(trackID: ids[0], revision: newer.revision))
        #expect(try await repository.pendingWrite(trackID: ids[0]) == nil)
    }

    @Test func failuresCountAndBlockedRowsWaitForTheNextEdit() async throws {
        let db = try DatabaseManager.inMemory()
        let ids = try Self.seed(db, count: 2)
        let repository = TrackTagRepository(database: db)
        _ = try await repository.apply(.text("A"), to: .genre, trackIDs: ids, queueFileWrites: true)
        let first = try #require(try await repository.pendingWrite(trackID: ids[0]))
        try await repository.recordFailure(trackID: ids[0], revision: first.revision, reason: "the file is missing", blocked: false)
        try await repository.recordFailure(trackID: ids[1], revision: 1, reason: "WAV isn’t supported", blocked: true)
        let missing = try #require(try await repository.pendingWrite(trackID: ids[0]))
        #expect(missing.attempts == 1 && missing.lastError == "the file is missing" && !missing.blocked)
        #expect(try await repository.pendingWrites(limit: 10).map(\.trackID) == [ids[0]], "blocked rows are skipped")
        #expect(try await repository.pendingCount() == 1)
        _ = try await repository.apply(.text("B"), to: .genre, trackIDs: [ids[1]], queueFileWrites: true)
        let retried = try #require(try await repository.pendingWrite(trackID: ids[1]))
        #expect(!retried.blocked && retried.attempts == 0 && retried.lastError == nil)
        #expect(try await repository.pendingWrites(limit: 10, afterTrackID: ids[0]).map(\.trackID) == [ids[1]])
    }

    @Test func orphanedRowsAreNeverReadAndAreRemoved() async throws {
        let db = try DatabaseManager.inMemory()
        let ids = try Self.seed(db, count: 3)
        let repository = TrackTagRepository(database: db)
        _ = try await repository.apply(.text("A"), to: .genre, trackIDs: ids, queueFileWrites: true)
        // Remove from Library deletes through TrackRepository, which doesn't know this table.
        try await TrackRepository(database: db).delete(ids: [ids[1]])
        #expect(try await repository.pendingWrites(limit: 10).map(\.trackID).sorted() == [ids[0], ids[2]])
        #expect(try await repository.pendingCount() == 2)
        #expect(try await repository.removeOrphanedPendingWrites() == 2, "its pending row and its field row")
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tag_write_fields WHERE track_id = ?", arguments: [ids[1]]) } == 0)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pending_tag_writes") } == 2)
    }

    @Test func settingFailsClosedAndIsStoredPerLibrary() async throws {
        let db = try DatabaseManager.inMemory()
        let config = ConfigRepository(database: db)
        #expect(await TagWriteSetting.isEnabled(config) == false, "absent = off until explicitly turned on")
        #expect(await TagWriteSetting.isEnabled(nil) == false, "no library = off")
        try await config.set(key: "write_tags_to_files", value: "yes")
        #expect(await TagWriteSetting.isEnabled(config) == false, "only an explicit \"1\" is on")
        try await TagWriteSetting.setEnabled(true, config: config)
        #expect(await TagWriteSetting.isEnabled(config))
        #expect(try await config.get(key: "write_tags_to_files") == "1")
        try await TagWriteSetting.setEnabled(false, config: config)
        #expect(await TagWriteSetting.isEnabled(config) == false)
        // An unreadable config fails closed too.
        try await db.write { try $0.execute(sql: "DROP TABLE app_config") }
        #expect(await TagWriteSetting.isEnabled(config) == false)
    }

    // MARK: Fields

    @Test func parsingAndFormText() {
        #expect(TrackTagField.title.parse("  ") == .failure(.init(message: "A track needs a title. Press Esc to restore the old one.")))
        #expect(TrackTagField.year.parse("19x9") == .failure(.init(message: "Year is a number, like 2019.")))
        #expect(TrackTagField.year.parse("20190") == .failure(.init(message: "Year is a number, like 2019.")))
        #expect(TrackTagField.year.parse(" 2019 ") == .success(.number(2019)))
        #expect(TrackTagField.bpm.parse("") == .success(.number(nil)))
        #expect(TrackTagField.bpm.parse("0") == .failure(.init(message: "BPM is a number, like 128.")))
        #expect(TrackTagField.genre.parse(" ") == .success(.text(nil)))
        #expect(TrackTagField.album.parse(" ") == .success(.text("")))
        var track = Track(artist: "unknown", album: "soundcloud likes", title: "T", format: "mp3", originalPath: "/x")
        track.year = 0
        #expect(TrackTagField.album.text(of: track) == "", "a placeholder album shows as an empty field")
        #expect(TrackTagField.artist.text(of: track) == "")
        #expect(TrackTagField.year.text(of: track) == "")
        #expect(TrackTagField.genre.actionName == "Edit Genre")
        #expect(TrackTagField.albumArtist.actionName == "Edit Album Artist")
        #expect(TrackTagField.decode(TrackTagField.encode([.bpm, .title])) == [.title, .bpm])
    }
}
