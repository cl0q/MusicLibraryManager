import Foundation
import GRDB

/// Reads mlm-library.json into a local GRDB index for fast browsing.
///
/// Incremental by `generated_at`: if the manifest's generated_at matches the
/// last indexed value, the re-index is skipped.
final class LibraryIndexer {
    let dbQueue: DatabaseQueue

    /// Creates an indexer backed by a database at the given URL.
    /// Pass a temporary URL for testing.
    init(databaseURL: URL) throws {
        dbQueue = try DatabaseQueue(path: databaseURL.path)
        try migrator.migrate(dbQueue)
    }

    /// Convenience: indexer backed by the app's Application Support directory.
    static func makeDefault() throws -> LibraryIndexer {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dbDir = appSupport.appendingPathComponent("MLMMobile", isDirectory: true)
        try fm.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbURL = dbDir.appendingPathComponent("library.sqlite")
        return try LibraryIndexer(databaseURL: dbURL)
    }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_createTables") { db in
            try db.create(table: "indexed_tracks", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("album_artist", .text).notNull()
                t.column("album", .text).notNull()
                t.column("duration", .integer).notNull()
                t.column("path", .text).notNull()
                t.column("energy_bucket", .integer).notNull()
                t.column("lufs_i", .double).notNull()
            }
            try db.create(table: "indexed_playlists", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("file", .text).notNull()
            }
            try db.create(table: "index_state", ifNotExists: true) { t in
                t.column("id", .integer).primaryKey().defaults(to: 1)
                t.column("last_generated_at", .text)
            }
        }
        migrator.registerMigration("v2_playlistTables") { db in
            try db.create(table: "local_playlists", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("file", .text)
            }
            try db.create(table: "playlist_entries", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("playlist_id", .integer).notNull()
                    .references("local_playlists", onDelete: .cascade)
                t.column("track_uuid", .text).notNull()
                t.column("relative_path", .text).notNull()
                t.column("order_index", .integer).notNull()
                t.column("added_at", .datetime).notNull()
            }
            try db.create(table: "liked_tracks", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("track_uuid", .text).notNull().unique()
                t.column("liked_at", .datetime).notNull()
            }
            try db.create(table: "likes_playlist_state", ifNotExists: true) { t in
                t.column("id", .integer).primaryKey().defaults(to: 1)
                t.column("playlist_uuid", .text).notNull()
            }
        }
        return migrator
    }

    // MARK: - Indexing

    /// Index a manifest into the local database. Returns true if the index was updated.
    func index(manifest: LibraryManifest) throws -> Bool {
        // Check if we already indexed this generation.
        let lastGeneratedAt = try dbQueue.read { db -> String? in
            try IndexState.fetchOne(db, key: 1)?.lastGeneratedAt
        }
        if lastGeneratedAt == manifest.generatedAt {
            return false
        }

        try dbQueue.write { db in
            // Replace all tracks and playlists in a single transaction.
            try db.execute(sql: "DELETE FROM indexed_tracks")
            try db.execute(sql: "DELETE FROM indexed_playlists")

            for track in manifest.tracks {
                var indexed = IndexedTrack(
                    id: nil,
                    uuid: track.uuid,
                    title: track.title,
                    artist: track.artist,
                    albumArtist: track.albumArtist,
                    album: track.album,
                    duration: track.duration,
                    path: track.path,
                    energyBucket: track.energyBucket,
                    lufsI: track.lufsI
                )
                try indexed.insert(db)
            }

            for playlist in manifest.playlists {
                var indexed = IndexedPlaylist(
                    id: nil,
                    uuid: playlist.uuid,
                    name: playlist.name,
                    file: playlist.file
                )
                try indexed.insert(db)
            }

            // Update index state.
            var state = try IndexState.fetchOne(db, key: 1) ?? IndexState(id: 1, lastGeneratedAt: nil)
            state.lastGeneratedAt = manifest.generatedAt
            try state.save(db)
        }
        return true
    }

    // MARK: - Queries

    /// Fetch all indexed tracks, ordered by artist then title.
    func fetchAllTracks() throws -> [IndexedTrack] {
        try dbQueue.read { db in
            try IndexedTrack
                .order(IndexedTrack.Columns.artist, IndexedTrack.Columns.title)
                .fetchAll(db)
        }
    }

    /// Fetch tracks matching a search query (title or artist contains the term).
    func searchTracks(query: String) throws -> [IndexedTrack] {
        guard !query.isEmpty else { return try fetchAllTracks() }
        let pattern = "%\(query)%"
        return try dbQueue.read { db in
            try IndexedTrack
                .filter(
                    IndexedTrack.Columns.title.like(pattern) ||
                    IndexedTrack.Columns.artist.like(pattern) ||
                    IndexedTrack.Columns.album.like(pattern)
                )
                .order(IndexedTrack.Columns.artist, IndexedTrack.Columns.title)
                .fetchAll(db)
        }
    }

    /// Fetch tracks filtered by energy bucket (1-5).
    func fetchTracks(energyBucket: Int) throws -> [IndexedTrack] {
        try dbQueue.read { db in
            try IndexedTrack
                .filter(IndexedTrack.Columns.energyBucket == energyBucket)
                .order(IndexedTrack.Columns.artist, IndexedTrack.Columns.title)
                .fetchAll(db)
        }
    }

    /// Fetch all indexed playlists, ordered by name.
    func fetchAllPlaylists() throws -> [IndexedPlaylist] {
        try dbQueue.read { db in
            try IndexedPlaylist
                .order(IndexedPlaylist.Columns.name)
                .fetchAll(db)
        }
    }

    /// Returns the last indexed `generated_at` value, or nil if never indexed.
    func lastIndexedGeneration() throws -> String? {
        try dbQueue.read { db in
            try IndexState.fetchOne(db, key: 1)?.lastGeneratedAt
        }
    }

    /// Delete all indexed data.
    func clearIndex() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM indexed_tracks")
            try db.execute(sql: "DELETE FROM indexed_playlists")
            try db.execute(sql: "DELETE FROM index_state")
        }
    }
}
