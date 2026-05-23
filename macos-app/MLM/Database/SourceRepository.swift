import Foundation
import GRDB

/// Repository for music sources and track-source relationships.
final class SourceRepository: Sendable {
    private let database: DatabasePool

    init(database: DatabasePool) {
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
    @discardableResult
    func upsert(name: String, userId: String) async throws -> Source {
        try await database.write { db in
            var source = Source(id: nil, name: name, userId: userId, enabled: 1)
            try source.insert(db, onConflict: .ignore)
            // Refetch to get the ID (insert might have been ignored)
            if source.id == nil {
                source = try Source
                    .filter(Source.Columns.name == name && Source.Columns.userId == userId)
                    .fetchOne(db)!
            }
            return source
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
            try TrackSource
                .filter(TrackSource.Columns.sourceId == sourceId)
                .fetchCount(db)
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

    /// Expose the database pool for repositories that need cross-repo access.
    var databasePool: DatabasePool { database }
}
