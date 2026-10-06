import Foundation
import GRDB

/// Durable storage for the Reels identification queue.
final class ReelRepository: Sendable {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func fetchAll() async throws -> [ImportedReelRecord] {
        try await database.read { db in
            try ImportedReelRecord
                .order(ImportedReelRecord.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    func save(_ reel: ImportedReelRecord) async throws {
        try await database.write { db in
            try reel.save(db)
        }
    }

    func delete(id: String) async throws {
        _ = try await database.write { db in
            try ImportedReelRecord.deleteOne(db, key: id)
        }
    }

    /// Sets the state. `done` stamps `done_at`; any other state clears it. Never changes
    /// artist, title or guesses.
    func setState(id: String, _ state: ReelState, at date: Date = Date()) async throws {
        try await database.write { db in
            let doneAt = state == .done ? ISO8601DateFormatter().string(from: date) : nil
            try db.execute(
                sql: "UPDATE imported_reels SET state = ?, done_at = ?, updated_at = ? WHERE id = ?",
                arguments: [state.rawValue, doneAt, date, id])
        }
    }

    /// Saves artist and title and derives the state: a reel that is `done` stays `done` unless
    /// both fields were cleared (nothing else regresses a reel from Done).
    @discardableResult
    func setFields(id: String, artist: String, title: String, at date: Date = Date()) async throws -> ReelState? {
        try await database.write { db in
            guard let current = try ImportedReelRecord.fetchOne(db, key: id) else { return nil }
            let derived = ReelState.derived(artist: artist, title: title)
            let bothEmpty = artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let state: ReelState = current.state == .done && !bothEmpty ? .done : derived
            let doneAt = state == .done ? current.doneAt : nil
            try db.execute(
                sql: "UPDATE imported_reels SET artist = ?, title = ?, state = ?, done_at = ?, updated_at = ? WHERE id = ?",
                arguments: [artist, title, state.rawValue, doneAt, date, id])
            return state
        }
    }

    /// Stores the guesses JSON (nil clears it).
    func setGuesses(id: String, json: String?, at date: Date = Date()) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE imported_reels SET guesses_json = ?, updated_at = ? WHERE id = ?",
                arguments: [json, date, id])
        }
    }

    /// Reels not `Done` — the Discover scope count and the sidebar badge's share.
    func notDoneCount() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM imported_reels WHERE state <> 'done'") ?? 0
        }
    }
}
