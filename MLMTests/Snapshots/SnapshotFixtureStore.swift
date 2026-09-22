import Foundation
import GRDB
@testable import MLM

/// Statically written fixture data for the macOS-only snapshot target.
///
/// This intentionally creates only repositories through
/// `DependencyContainer(snapshotDatabase:)`; it never invokes the application's
/// normal `initialize()` path or starts a service.
final class SnapshotFixtureStore {
    static let referenceDate = Date(timeIntervalSince1970: 1_704_164_645)
    static let downloadFailure = TrackDownloadFailure(
        reason: "Network error",
        date: referenceDate,
        attempts: 2
    )

    let database: DatabaseQueue
    let container: DependencyContainer

    private init(database: DatabaseQueue) {
        self.database = database
        self.container = DependencyContainer(snapshotDatabase: database)
    }

    static func makeSeeded() throws -> SnapshotFixtureStore {
        let store = SnapshotFixtureStore(database: try DatabaseManager.inMemory())
        try store.seed()
        return store
    }

    func tracks() throws -> [Track] {
        let tracks = try database.read { db in
            try Track.order(Column("id")).fetchAll(db)
        }
        guard tracks.count == 5 else {
            throw SnapshotFixtureStoreError.unexpectedCount(
                entity: "tracks",
                expected: 5,
                actual: tracks.count
            )
        }
        return tracks
    }

    func tracksForRendering() throws -> [Track] {
        try tracks()
    }

    func playlists() throws -> [Playlist] {
        let playlists = try database.read { db in
            try Playlist.order(Column("id")).fetchAll(db)
        }
        guard playlists.count == 2 else {
            throw SnapshotFixtureStoreError.unexpectedCount(
                entity: "playlists",
                expected: 2,
                actual: playlists.count
            )
        }
        return playlists
    }

    func playlistTracks(playlistID: Int64) throws -> [Track] {
        try database.read { db in
            try Track.fetchAll(db, sql: """
                SELECT t.*, pt.position AS playlist_position,
                       pt.added_at AS playlist_added_at
                FROM tracks t
                JOIN playlist_tracks pt ON pt.track_id = t.id
                WHERE pt.playlist_id = ?
                ORDER BY pt.position
                """, arguments: [playlistID])
        }
    }

    private func seed() throws {
        try database.write { db in
            var normal = Track(
                artist: "Björk",
                album: "Homogenic",
                title: "Jóga",
                format: "flac",
                originalPath: "/fixtures/normal.flac"
            )
            normal.organizedPath = "Björk/Homogenic/01 Jóga.flac"
            normal.duration = 310
            normal.bitrate = 1_024
            normal.energyBucket = 4
            normal.danceability = 0.78
            normal.dateAdded = "2024-01-02T03:04:05Z"
            normal.mlmUuid = "00000000-0000-4000-8000-000000000001"
            try normal.insert(db)

            var missingMetadata = Track(
                artist: "Unknown",
                album: "SoundCloud Likes",
                title: "Metadata pending",
                format: "soundcloud",
                originalPath: "soundcloud://fixture/missing-metadata"
            )
            missingMetadata.downloadStatus = "failed"
            try missingMetadata.setDownloadFailureRecord(Self.downloadFailure)
            missingMetadata.dateAdded = "2024-01-02T03:04:05Z"
            missingMetadata.mlmUuid = "00000000-0000-4000-8000-000000000002"
            try missingMetadata.insert(db)

            var missingFile = Track(
                artist: "The Missing",
                album: "Archive",
                title: "Offline File",
                format: "mp3",
                originalPath: "/fixtures/offline.mp3"
            )
            missingFile.organizedPath = "Archive/offline.mp3"
            missingFile.dateAdded = "2024-01-02T03:04:05Z"
            missingFile.mlmUuid = "00000000-0000-4000-8000-000000000003"
            try missingFile.insert(db)

            var remoteOnly = Track(
                artist: "Remote Artist",
                album: "Cloud",
                title: "Stream Only",
                format: "youtube",
                originalPath: "youtube://fixture/remote-only"
            )
            remoteOnly.downloadStatus = nil
            remoteOnly.dateAdded = "2024-01-02T03:04:05Z"
            remoteOnly.mlmUuid = "00000000-0000-4000-8000-000000000004"
            try remoteOnly.insert(db)

            var unicode = Track(
                artist: "長い名前 — Zoë",
                album: "Álbum 漢字",
                title: "A very long Unicode title — 𝄞 café naïve 東京",
                format: "aac",
                originalPath: "/fixtures/unicode.m4a"
            )
            unicode.organizedPath = "Unicode/long-title.m4a"
            unicode.dateAdded = "2024-01-02T03:04:05Z"
            unicode.mlmUuid = "00000000-0000-4000-8000-000000000005"
            try unicode.insert(db)

            var populated = Playlist(
                id: nil,
                name: "Snapshot Mix",
                description: "Deterministic populated fixture",
                category: "manual",
                isLiked: 0,
                isSmart: 0,
                isPinned: 1,
                coverImagePath: nil,
                coverImageUrl: nil,
                sourceId: nil,
                externalId: nil,
                dateCreated: "2024-01-02T03:04:05Z",
                mlmUuid: "00000000-0000-4000-8000-000000001001"
            )
            try populated.insert(db)

            var empty = Playlist(
                id: nil,
                name: "Empty Snapshot Playlist",
                description: nil,
                category: "manual",
                isLiked: 0,
                isSmart: 0,
                isPinned: 0,
                coverImagePath: nil,
                coverImageUrl: nil,
                sourceId: nil,
                externalId: nil,
                dateCreated: "2024-01-02T03:04:05Z",
                mlmUuid: "00000000-0000-4000-8000-000000001002"
            )
            try empty.insert(db)

            guard let playlistID = populated.id, let normalID = normal.id,
                  let remoteID = remoteOnly.id else {
                throw SnapshotFixtureStoreError.missingGeneratedIDs
            }

            try db.execute(
                sql: """
                INSERT INTO playlist_tracks (playlist_id, track_id, position, added_at)
                VALUES (?, ?, ?, ?), (?, ?, ?, ?)
                """,
                arguments: [
                    playlistID, normalID, "100000", "2024-01-02T03:04:05Z",
                    playlistID, remoteID, "200000", "2024-01-02T03:04:05Z",
                ]
            )
        }
    }

    enum SnapshotFixtureStoreError: LocalizedError {
        case unexpectedCount(entity: String, expected: Int, actual: Int)
        case missingGeneratedIDs

        var errorDescription: String? {
            switch self {
            case let .unexpectedCount(entity, expected, actual):
                "Expected \(expected) snapshot \(entity), found \(actual)."
            case .missingGeneratedIDs:
                "Snapshot seed inserts did not produce generated IDs."
            }
        }
    }
}
