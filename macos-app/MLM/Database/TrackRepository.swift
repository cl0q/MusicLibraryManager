import Foundation
import GRDB

/// Repository for track CRUD, search, and filtering operations.
///
/// Encapsulates all SQL for the `tracks` domain, matching the
/// Tauri app's `src/database/tracks.rs` functionality.
final class TrackRepository: Sendable {
    private let database: DatabasePool

    init(database: DatabasePool) {
        self.database = database
    }

    // MARK: - Read

    /// Fetch all local tracks (organized_path IS NOT NULL).
    func fetchLocalTracks() async throws -> [Track] {
        try await database.read { db in
            try Track
                .filter(Track.Columns.organizedPath != nil)
                .order(Track.Columns.artist, Track.Columns.album, Track.Columns.title)
                .fetchAll(db)
        }
    }

    /// Fetch all remote tracks (organized_path IS NULL, has streaming source).
    func fetchRemoteTracks() async throws -> [Track] {
        try await database.read { db in
            try Track
                .filter(Track.Columns.organizedPath == nil)
                .order(Track.Columns.dateAdded.desc)
                .fetchAll(db)
        }
    }

    /// Fetch a single track by ID.
    func fetchTrack(id: Int64) async throws -> Track? {
        try await database.read { db in
            try Track.fetchOne(db, id: id)
        }
    }

    /// Fetch tracks by album ID.
    func fetchTracks(albumId: Int64) async throws -> [Track] {
        try await database.read { db in
            try Track
                .filter(Track.Columns.albumId == albumId)
                .order(Track.Columns.title)
                .fetchAll(db)
        }
    }

    /// Count local tracks.
    func countLocalTracks() async throws -> Int {
        try await database.read { db in
            try Track
                .filter(Track.Columns.organizedPath != nil)
                .fetchCount(db)
        }
    }

    /// Count remote tracks.
    func countRemoteTracks() async throws -> Int {
        try await database.read { db in
            try Track
                .filter(Track.Columns.organizedPath == nil)
                .fetchCount(db)
        }
    }

    /// Search tracks by title, artist, or album.
    func search(query: String) async throws -> [Track] {
        let pattern = "%\(query)%"
        return try await database.read { db in
            try Track
                .filter(
                    Track.Columns.title.like(pattern) ||
                    Track.Columns.artist.like(pattern) ||
                    Track.Columns.album.like(pattern)
                )
                .order(Track.Columns.artist, Track.Columns.title)
                .fetchAll(db)
        }
    }

    /// Fetch tracks in a folder (by organized_path prefix).
    func fetchTracks(folderPrefix: String) async throws -> [Track] {
        let pattern = "\(folderPrefix)%"
        return try await database.read { db in
            try Track
                .filter(Track.Columns.organizedPath.like(pattern))
                .order(Track.Columns.title)
                .fetchAll(db)
        }
    }

    /// Fetch distinct folder prefixes from organized_path.
    func fetchFolderPrefixes() async throws -> [String] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT
                    CASE
                        WHEN INSTR(organized_path, '/') > 0
                        THEN SUBSTR(organized_path, 1, INSTR(organized_path, '/') - 1)
                        ELSE organized_path
                    END as folder_prefix
                FROM tracks
                WHERE organized_path IS NOT NULL
                ORDER BY folder_prefix
            """)
            return rows.compactMap { $0["folder_prefix"] as? String }
        }
    }

    // MARK: - Write

    /// Insert a new track, returning the inserted track with its ID.
    @discardableResult
    func insert(_ track: Track) async throws -> Track {
        try await database.write { db in
            var track = track
            try track.insert(db)
            return track
        }
    }

    /// Update an existing track.
    func update(_ track: Track) async throws {
        try await database.write { db in
            try track.update(db)
        }
    }

    /// Delete a track by ID.
    func delete(id: Int64) async throws {
        _ = try await database.write { db in
            try Track.deleteOne(db, id: id)
        }
    }

    /// Delete multiple tracks by IDs.
    func delete(ids: [Int64]) async throws {
        try await database.write { db in
            try Track.deleteAll(db, ids: ids)
        }
    }

    /// Update download status for a track.
    func updateDownloadStatus(trackId: Int64, status: String?, organizedPath: String?) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE tracks SET download_status = ?, organized_path = ?
                    WHERE id = ?
                """,
                arguments: [status, organizedPath, trackId]
            )
        }
    }
}
