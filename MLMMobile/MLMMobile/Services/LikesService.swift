import Foundation
import GRDB

/// Manages track likes (hearts) and materializes `Liked.m3u8` in the `.ios` dialect.
///
/// Design decision: when likes are empty, `Liked.m3u8` is still written with the
/// header only (no entries). This ensures the stable playlist UUID is always
/// available for MLM to adopt, and avoids create/delete churn on the sync folder.
final class LikesService {
    private let dbQueue: DatabaseQueue
    private let engine: PlaylistEngine

    init(dbQueue: DatabaseQueue, engine: PlaylistEngine) {
        self.dbQueue = dbQueue
        self.engine = engine
    }

    // MARK: - Like state

    /// Check if a track is liked.
    func isLiked(trackUUID: String) throws -> Bool {
        try dbQueue.read { db in
            try LikedTrack
                .filter(LikedTrack.Columns.trackUUID == trackUUID)
                .fetchOne(db) != nil
        }
    }

    /// Toggle the like state for a track. Returns the new state (true = now liked).
    func toggleLike(trackUUID: String) throws -> Bool {
        try dbQueue.write { db in
            if let existing = try LikedTrack
                .filter(LikedTrack.Columns.trackUUID == trackUUID)
                .fetchOne(db) {
                try db.execute(sql: "DELETE FROM liked_tracks WHERE id = ?", arguments: [existing.id!])
                return false
            } else {
                var liked = LikedTrack(id: nil, trackUUID: trackUUID, likedAt: Date())
                try liked.insert(db)
                return true
            }
        }
    }

    /// Fetch the set of all liked track UUIDs.
    func fetchLikedUUIDs() throws -> Set<String> {
        try dbQueue.read { db in
            let rows = try LikedTrack.fetchAll(db)
            return Set(rows.map { $0.trackUUID })
        }
    }

    /// Fetch liked tracks ordered by liked_at descending.
    func fetchLikedTracks() throws -> [LikedTrack] {
        try dbQueue.read { db in
            try LikedTrack
                .order(LikedTrack.Columns.likedAt.desc)
                .fetchAll(db)
        }
    }

    // MARK: - Materialize Liked.m3u8

    /// Write `Liked.m3u8` to the playlists directory.
    ///
    /// Always writes the file (even when empty) with the stable playlist UUID header.
    /// This ensures MLM can always adopt the playlist via `#EXTMLM-PLAYLIST`.
    func materializeLikedPlaylist(
        to directory: URL,
        tracksByUUID: [String: IndexedTrack]
    ) throws {
        let playlistUUID = try getOrCreateLikesPlaylistUUID()
        let likedTracks = try fetchLikedTracks()

        var entries: [ParsedEntry] = []
        for liked in likedTracks {
            let track = tracksByUUID[liked.trackUUID]
            let extinf: String?
            let path: String
            if let track = track {
                extinf = "#EXTINF:\(track.duration),\(track.artist) - \(track.title)"
                path = track.path
            } else {
                extinf = nil
                path = ""
            }
            entries.append(ParsedEntry(
                extinfLine: extinf,
                trackUUID: liked.trackUUID,
                path: path,
                precedingComments: []
            ))
        }

        let parsed = ParsedPlaylist(
            playlistUUID: playlistUUID,
            headerComments: [],
            entries: entries
        )

        let fileURL = directory.appendingPathComponent("Liked.m3u8")
        try engine.write(parsed, to: fileURL)
    }

    // MARK: - Private

    /// Get or create the stable UUID for the Liked.m3u8 playlist.
    private func getOrCreateLikesPlaylistUUID() throws -> String {
        try dbQueue.write { db -> String in
            if let state = try LikesPlaylistState.fetchOne(db, key: 1) {
                return state.playlistUUID
            }
            let uuid = UUID().uuidString.uppercased()
            var state = LikesPlaylistState(id: 1, playlistUUID: uuid)
            try state.insert(db)
            return uuid
        }
    }
}
