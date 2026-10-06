import Foundation
import GRDB
import Testing
@testable import MLM

/// `v55_reel_state` (W3-DISC-B, IMP-059). Temporary databases only; foreign keys off.
@Suite("ReelStateMigrationTests")
struct ReelStateMigrationTests {
    private static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = false
        return config
    }

    private func insert(_ queue: DatabaseQueue, id: String, artist: String, title: String) throws {
        try queue.write { db in
            try db.execute(sql: "INSERT INTO imported_reels (id, file_path, artist, title) VALUES (?, ?, ?, ?)",
                           arguments: [id, "/r/\(id).mp4", artist, title])
        }
    }

    @Test func backfillMarksReelsWithBothFieldsIdentified() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: "v54_review_hidden")
        try insert(queue, id: "both", artist: "Overmono", title: "So U Kno")
        try insert(queue, id: "artist-only", artist: "Overmono", title: "")
        try insert(queue, id: "none", artist: "", title: "")
        try migrator.migrate(queue)
        let rows = try queue.read { try Row.fetchAll($0, sql: "SELECT id, state, done_at, guesses_json FROM imported_reels") }
        var states: [String: String] = [:]
        for row in rows { states[row["id"]] = row["state"] }
        #expect(states["both"] == "identified")
        #expect(states["artist-only"] == "new")
        #expect(states["none"] == "new")
        for row in rows {
            let doneAt: String? = row["done_at"]
            let guesses: String? = row["guesses_json"]
            #expect(doneAt == nil && guesses == nil)
        }
    }

    @Test func partiallyAppliedColumnsMigrateCleanly() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: "v54_review_hidden")
        try queue.write { db in
            try db.execute(sql: "ALTER TABLE imported_reels ADD COLUMN state TEXT NOT NULL DEFAULT 'new'")
            try db.execute(sql: "ALTER TABLE imported_reels ADD COLUMN done_at TEXT")
        }
        try insert(queue, id: "a", artist: "A", title: "B")
        try migrator.migrate(queue)
        let columns = try queue.read { try $0.columns(in: "imported_reels").map(\.name) }
        #expect(columns.contains("state") && columns.contains("guesses_json") && columns.contains("done_at"))
        #expect(try queue.read { try String.fetchOne($0, sql: "SELECT state FROM imported_reels WHERE id = 'a'") } == "identified")
    }

    @Test func v55IsRegisteredAfterTheLatestMigration() {
        let names = DatabaseManager.buildMigrator().migrations
        // Registered right after v54; the album migrations (v50, v51, W4-1) follow it.
        #expect(names.firstIndex(of: "v55_reel_state") == names.firstIndex(of: "v54_review_hidden").map { $0 + 1 })
        #expect(names.firstIndex(of: "v50_album_tracks") == names.firstIndex(of: "v55_reel_state").map { $0 + 1 })
    }
}
