import Foundation
import GRDB

/// Repository for music sources and track-source relationships.
final class SourceRepository: Sendable {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    // MARK: - Sources

    /// Fetch a source by ID.
    func fetch(id: Int64) async throws -> Source? {
        try await database.read { db in
            try Source.fetchOne(db, id: id)
        }
    }

    /// Fetch all sources.
    func fetchAll() async throws -> [Source] {
        try await database.read { db in
            try Source.order(Source.Columns.name).fetchAll(db)
        }
    }

    /// Fetch a source by name and user ID.
    func fetch(name: String, userId: String) async throws -> Source? {
        try await database.read { db in
            try Source
                .filter(Source.Columns.name == name && Source.Columns.userId == userId)
                .fetchOne(db)
        }
    }

    /// Create or update a source.
    ///
    /// IMPORTANT — do not "simplify" this back into a single insert-then-branch.
    /// GRDB's `didInsert` fires even when `INSERT OR IGNORE` is ignored by the
    /// unique-key constraint, and assigns `id = db.lastInsertedRowID`, which on
    /// an ignored insert is the rowid of whatever was last inserted on this
    /// connection — not the source row. That stale rowid then propagates into
    /// every caller (`findOrCreateSourcePlaylist`, `linkTrackToSource`, …) and
    /// breaks idempotency: re-importing the same remote playlist stacks
    /// duplicates because each call sees a different `sourceId`.
    ///
    /// The safe shape is: fetch inside the same write transaction (GRDB
    /// serialises writers, so this is race-free), insert only if absent, and
    /// always return the fetched row — never trust the post-insert `source.id`.
    @discardableResult
    func upsert(name: String, userId: String) async throws -> Source {
        try await database.write { db in
            if let existing = try Source
                .filter(Source.Columns.name == name && Source.Columns.userId == userId)
                .fetchOne(db) {
                return existing
            }
            var source = Source(id: nil, name: name, userId: userId, enabled: 1)
            try source.insert(db, onConflict: .ignore)
            guard let fetched = try Source
                .filter(Source.Columns.name == name && Source.Columns.userId == userId)
                .fetchOne(db) else {
                throw SourceRepositoryError.upsertRefetchFailed(name: name, userId: userId)
            }
            return fetched
        }
    }

    /// Toggle source enabled state.
    func toggleEnabled(id: Int64) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE sources SET enabled = CASE WHEN enabled = 1 THEN 0 ELSE 1 END WHERE id = ?",
                arguments: [id]
            )
        }
    }

    // MARK: - Track Sources

    /// Fetch sources for a track.
    func fetchTrackSources(trackId: Int64) async throws -> [TrackSource] {
        try await database.read { db in
            try TrackSource
                .filter(TrackSource.Columns.trackId == trackId)
                .fetchAll(db)
        }
    }

    /// Link a track to a source.
    func linkTrackToSource(trackId: Int64, sourceId: Int64, externalId: String, addedAt: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO track_sources (track_id, source_id, external_id, added_at)
                    VALUES (?, ?, ?, ?)
                """,
                arguments: [trackId, sourceId, externalId, addedAt]
            )
        }
    }

    // MARK: - Sync Timestamps

    /// Get last sync timestamp for a source.
    func getLastSyncTimestamp(userId: String, source: String) async throws -> String? {
        try await database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT timestamp FROM last_sync_timestamps
                WHERE user_id = ? AND source = ?
            """, arguments: [userId, source])?["timestamp"]
        }
    }

    /// Update last sync timestamp.
    func setLastSyncTimestamp(userId: String, source: String, timestamp: String) async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO last_sync_timestamps (user_id, source, timestamp)
                VALUES (?, ?, ?)
            """, arguments: [userId, source, timestamp])
        }
    }

    /// Count tracks linked to a source.
    func countTracks(sourceId: Int64) async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM track_sources ts
                INNER JOIN tracks t ON t.id = ts.track_id
                WHERE ts.source_id = ?
            """, arguments: [sourceId]) ?? 0
        }
    }

    /// Get last sync timestamp by source ID and sync type.
    func getLastSync(sourceId: Int64, syncType: String) async throws -> String? {
        try await database.read { db in
            guard let source = try Source.fetchOne(db, id: sourceId) else { return nil }
            let key = "\(source.name)_\(syncType)"
            return try Row.fetchOne(db, sql: """
                SELECT timestamp FROM last_sync_timestamps
                WHERE source = ? ORDER BY timestamp DESC LIMIT 1
            """, arguments: [key])?["timestamp"]
        }
    }

    /// Update last sync timestamp by source ID and sync type.
    func updateLastSync(sourceId: Int64, syncType: String, timestamp: String) async throws {
        try await database.write { db in
            guard let source = try Source.fetchOne(db, id: sourceId) else { return }
            let key = "\(source.name)_\(syncType)"
            try db.execute(sql: """
                INSERT OR REPLACE INTO last_sync_timestamps (user_id, source, timestamp)
                VALUES ('default', ?, ?)
            """, arguments: [key, timestamp])
        }
    }

    /// Link a track to a source (without addedAt parameter — uses current time).
    func linkTrackToSource(trackId: Int64, sourceId: Int64, externalId: String) async throws {
        try await linkTrackToSource(
            trackId: trackId,
            sourceId: sourceId,
            externalId: externalId,
            addedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    /// Batch-fetch external IDs for a set of track IDs in one query.
    ///
    /// Used by the "Link Source" diff in PlaylistDetailViewModel: tier-1 match
    /// of the diff needs each local track's external IDs, and issuing one
    /// `fetchTrackSources` per track would be O(N) round-trips. A single
    /// `WHERE track_id IN (…)` query returns every (track_id, external_id)
    /// pair, grouped into `[trackId: [externalId]]`.
    ///
    /// Empty input returns `[:]` without hitting the database.
    func fetchExternalIDs(trackIds: Set<Int64>) async throws -> [Int64: [String]] {
        guard !trackIds.isEmpty else { return [:] }
        let placeholders = trackIds.map { _ in "?" }.joined(separator: ",")
        let args = trackIds.map { $0 as DatabaseValueConvertible }
        return try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT track_id, external_id FROM track_sources
                WHERE track_id IN (\(placeholders))
            """, arguments: StatementArguments(args))
            var result: [Int64: [String]] = [:]
            for row in rows {
                guard let trackId: Int64 = row["track_id"],
                      let externalId: String = row["external_id"] else { continue }
                result[trackId, default: []].append(externalId)
            }
            return result
        }
    }

    /// Exposes the shared writer for repositories that need cross-repo access.
    var databaseWriter: any DatabaseWriter { database }
}

enum SourceRepositoryError: Error, CustomStringConvertible {
    case upsertRefetchFailed(name: String, userId: String)

    var description: String {
        switch self {
        case .upsertRefetchFailed(let name, let userId):
            return "SourceRepository.upsert(\(name), \(userId)): row not found after insert"
        }
    }
}
