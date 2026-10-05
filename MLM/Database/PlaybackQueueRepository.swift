import Foundation
import GRDB

/// The saved playback queue of this library (`v43_playback_queue`, W2-D).
///
/// Two tables:
/// - `playback_queue_entries` — one row per queued item: `lane` (`play_next` · `context` ·
///   `cycle` · `history`), `position` in its lane, the entry's own `entry_id` (a UUID, so the
///   same track can be saved twice and keeps its identity across relaunches) and `track_id`.
/// - `playback_queue_state` — one row: the playing entry, its position, where the context came
///   from, when it was saved.
///
/// Foreign keys stay disabled: entries of deleted tracks are removed by `removeEntries(trackIDs:)`
/// (on `.libraryDidDeleteTracks`) and by the orphan cleanup in `load()`.
final class PlaybackQueueRepository: PlaybackQueueStoring, Sendable {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    enum Lane: String {
        case playNext = "play_next"
        case context
        case cycle
        case history
    }

    // MARK: Save

    func save(_ queue: SavedPlaybackQueue) async throws {
        try await database.write { db in try Self.write(queue, db) }
    }

    func saveNow(_ queue: SavedPlaybackQueue) throws {
        try database.write { db in try Self.write(queue, db) }
    }

    /// Replace everything in one transaction.
    static func write(_ queue: SavedPlaybackQueue, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM playback_queue_entries")
        func insert(_ entries: [(UUID, Int64)], lane: Lane) throws {
            for (position, entry) in entries.enumerated() {
                try db.execute(sql: """
                    INSERT INTO playback_queue_entries (lane, position, entry_id, track_id)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [lane.rawValue, position, entry.0.uuidString, entry.1])
            }
        }
        try insert(queue.playNext.map { ($0.id, $0.trackID) }, lane: .playNext)
        try insert(queue.context.map { ($0.id, $0.trackID) }, lane: .context)
        try insert(queue.cycle.map { ($0.id, $0.trackID) }, lane: .cycle)
        try insert(queue.history.map { ($0.id, $0.trackID) }, lane: .history)
        try db.execute(sql: """
            INSERT OR REPLACE INTO playback_queue_state (id, current_entry_id, position, origin, saved_at)
            VALUES (1, ?, ?, ?, ?)
            """, arguments: [
                queue.currentEntryID?.uuidString,
                queue.position,
                SavedPlaybackOrigin.encode(queue.origin),
                ISO8601DateFormatter().string(from: Date()),
            ])
    }

    // MARK: Load

    func load() async throws -> SavedPlaybackQueue? {
        try await database.write { db in
            try Self.removeOrphans(db)
            return try Self.read(db)
        }
    }

    /// Entries whose track no longer exists (deleted while MLM wasn't running, or by a path
    /// that posted nothing).
    static func removeOrphans(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM playback_queue_entries
            WHERE track_id NOT IN (SELECT id FROM tracks)
            """)
    }

    static func read(_ db: Database) throws -> SavedPlaybackQueue? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT lane, entry_id, track_id FROM playback_queue_entries ORDER BY lane, position
            """)
        let state = try Row.fetchOne(db, sql: """
            SELECT current_entry_id, position, origin FROM playback_queue_state WHERE id = 1
            """)
        guard !rows.isEmpty || state != nil else { return nil }
        var queue = SavedPlaybackQueue()
        for row in rows {
            let laneText: String = row["lane"]
            let trackID: Int64 = row["track_id"]
            let idText: String = row["entry_id"]
            guard let lane = Lane(rawValue: laneText) else { continue }
            let id = UUID(uuidString: idText) ?? UUID()
            switch lane {
            case .playNext: queue.playNext.append(.init(id: id, trackID: trackID))
            case .context: queue.context.append(.init(id: id, trackID: trackID))
            case .cycle: queue.cycle.append(.init(id: id, trackID: trackID))
            case .history: queue.history.append(.init(id: id, trackID: trackID))
            }
        }
        if let state {
            let current: String? = state["current_entry_id"]
            queue.currentEntryID = current.flatMap(UUID.init(uuidString:))
            queue.position = state["position"] ?? 0
            queue.origin = SavedPlaybackOrigin.decode(state["origin"])
        }
        return queue
    }

    // MARK: Cascade

    func removeEntries(trackIDs: Set<Int64>) async throws {
        guard !trackIDs.isEmpty else { return }
        try await database.write { db in
            let ids = Array(trackIDs)
            for chunk in stride(from: 0, to: ids.count, by: 500) {
                let part = Array(ids[chunk..<min(chunk + 500, ids.count)])
                let marks = databaseQuestionMarks(count: part.count)
                try db.execute(sql: "DELETE FROM playback_queue_entries WHERE track_id IN (\(marks))",
                               arguments: StatementArguments(part))
            }
        }
    }
}
