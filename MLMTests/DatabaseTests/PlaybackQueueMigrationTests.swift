import Foundation
import GRDB
import Testing
@testable import MLM

/// `v43_playback_queue` (W2-D) and `PlaybackQueueRepository`. Temporary databases only.
@Suite("PlaybackQueueMigrationTests")
struct PlaybackQueueMigrationTests {
    private static let v43 = "v43_playback_queue"
    private static let v53 = "v53_tag_write_originals"

    private static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = false
        return config
    }

    // MARK: Migration

    @Test func freshDatabaseHasBothTables() throws {
        let queue = try DatabaseManager.inMemory()
        let (entries, state, index) = try queue.read { db in
            (
                try db.columns(in: "playback_queue_entries").map(\.name),
                try db.columns(in: "playback_queue_state").map(\.name),
                try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'idx_playback_queue_entries_track'")
            )
        }
        #expect(entries == ["lane", "position", "entry_id", "track_id"])
        #expect(state == ["id", "current_entry_id", "position", "origin", "saved_at"])
        #expect(index?.contains("track_id") == true)
    }

    @Test func registeredOnceAfterTheLatestExistingMigration() throws {
        let migrations = DatabaseManager.buildMigrator().migrations
        #expect(migrations.filter { $0 == Self.v43 }.count == 1)
        let v53Index = try #require(migrations.firstIndex(of: Self.v53))
        let v43Index = try #require(migrations.firstIndex(of: Self.v43))
        #expect(v53Index < v43Index, "registered after v53 — an existing migration is never edited or reordered")
    }

    @Test func upgradeFromV53KeepsEveryRowAndAddsEmptyTables() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.v53)
        let hadTable = try queue.read { try $0.tableExists("playback_queue_entries") }
        #expect(!hadTable)
        try queue.write { db in
            for index in 0..<20 {
                try db.execute(sql: """
                    INSERT INTO tracks (artist, album_artist, album, title, format, original_path, is_duplicate, duration)
                    VALUES ('A', 'A', 'B', ?, 'm4a', ?, 0, 200)
                    """, arguments: ["T\(index)", "/orig/\(index).m4a"])
            }
        }
        let applied = try queue.read { try migrator.appliedIdentifiers($0) }
        #expect(BackupService.hasPendingMigrations(registered: Set(migrator.migrations), applied: applied),
                "the pre-migration backup sees v43 as pending")
        try migrator.migrate(queue)
        let (tracks, entries, states) = try queue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playback_queue_entries"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playback_queue_state")
            )
        }
        #expect(tracks == 20)
        #expect(entries == 0)
        #expect(states == 0)
    }

    @Test func idempotentWhenTheTablesAlreadyExist() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.v53)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE playback_queue_entries (lane TEXT NOT NULL, position INTEGER NOT NULL,
                    entry_id TEXT NOT NULL, track_id INTEGER NOT NULL, PRIMARY KEY (lane, position))
                """)
        }
        try migrator.migrate(queue)
        try migrator.migrate(queue)
        let exists = try queue.read { try $0.tableExists("playback_queue_state") }
        #expect(exists)
    }

    @Test func foreignKeysStayDisabled() throws {
        let queue = try DatabaseManager.inMemory()
        let enabled = try queue.read { try Bool.fetchOne($0, sql: "PRAGMA foreign_keys") }
        #expect(enabled == false)
    }

    // MARK: Repository

    private func insertTracks(_ db: DatabaseQueue, count: Int) throws -> [Int64] {
        try db.write { db in
            (0..<count).map { index in
                try? db.execute(sql: """
                    INSERT INTO tracks (artist, album_artist, album, title, format, original_path, is_duplicate, duration)
                    VALUES ('A', 'A', 'B', ?, 'm4a', ?, 0, 200)
                    """, arguments: ["T\(index)", "/orig/\(index).m4a"])
                return db.lastInsertedRowID
            }
        }
    }

    @Test func saveAndLoadRoundTripWithDuplicatesPositionsAndOrigin() async throws {
        let db = try DatabaseManager.inMemory()
        let ids = try insertTracks(db, count: 4)
        let repository = PlaybackQueueRepository(database: db)
        #expect(try await repository.load() == nil, "nothing saved yet")
        let twice = SavedPlaybackQueue.Entry(id: UUID(), trackID: ids[1])
        let current = SavedPlaybackQueue.Entry(id: UUID(), trackID: ids[0])
        let saved = SavedPlaybackQueue(
            playNext: [twice, .init(id: UUID(), trackID: ids[1])],
            context: [.init(id: UUID(), trackID: ids[2]), .init(id: UUID(), trackID: ids[3])],
            cycle: [ids[0], ids[2], ids[3]],
            history: [.init(id: UUID(), trackID: ids[3]), .init(id: UUID(), trackID: ids[3]), current],
            currentEntryID: current.id,
            position: 72.5,
            origin: PlaybackOrigin(place: .allPlaylists, path: [.playlist(7)], listKey: "playlist",
                                   container: .playlist(id: 7, name: "Warm-up"))
        )
        try await repository.save(saved)
        let loaded = try #require(try await repository.load())
        #expect(loaded == saved)
        // Saving again replaces everything.
        var smaller = saved
        smaller.playNext = []
        smaller.origin = nil
        try repository.saveNow(smaller)
        #expect(try await repository.load() == smaller)
    }

    @Test func entriesOfDeletedTracksGoOnLoadAndOnRequest() async throws {
        let db = try DatabaseManager.inMemory()
        let ids = try insertTracks(db, count: 3)
        let repository = PlaybackQueueRepository(database: db)
        let saved = SavedPlaybackQueue(
            context: ids.map { .init(id: UUID(), trackID: $0) },
            history: [.init(id: UUID(), trackID: ids[2])]
        )
        try await repository.save(saved)
        try await repository.removeEntries(trackIDs: [ids[0]])
        #expect(try await repository.load()?.context.map(\.trackID) == [ids[1], ids[2]])
        // Deleted while MLM wasn't listening: the orphan cleanup on load.
        try await db.write { db in try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [ids[2]]) }
        let loaded = try #require(try await repository.load())
        #expect(loaded.context.map(\.trackID) == [ids[1]])
        #expect(loaded.history.isEmpty)
        let left = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM playback_queue_entries") }
        #expect(left == 1)
    }

    @Test func eachLibraryDatabaseKeepsItsOwnQueue() async throws {
        let first = try DatabaseManager.inMemory()
        let second = try DatabaseManager.inMemory()
        let a = try insertTracks(first, count: 2)
        let b = try insertTracks(second, count: 1)
        try await PlaybackQueueRepository(database: first).save(SavedPlaybackQueue(context: a.map { .init(id: UUID(), trackID: $0) }))
        try await PlaybackQueueRepository(database: second).save(SavedPlaybackQueue(context: b.map { .init(id: UUID(), trackID: $0) }))
        #expect(try await PlaybackQueueRepository(database: first).load()?.context.count == 2)
        #expect(try await PlaybackQueueRepository(database: second).load()?.context.count == 1)
    }
}
