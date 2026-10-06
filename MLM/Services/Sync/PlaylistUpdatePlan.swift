import Foundation
import GRDB

/// What a profile playlist holds now and what the device file listed when MLM last wrote it
/// (`playlist_sync_snapshots`) — the input of the plan's `‹n› playlists to update` count
/// (IMP-105).
struct PlaylistUpdateState: Equatable, Sendable {
    let playlistID: Int64
    /// Current members in playlist order.
    let members: [Int64]
    /// Track ids the last written file listed, in order; `nil` = MLM never wrote this playlist.
    let snapshot: [Int64]?

    /// The playlist file needs rewriting: it was never written, or the tracks that will be on
    /// the device (members that are synced or planned to be copied — skipped tracks are not in
    /// the file) differ from the snapshot in members or order.
    func needsUpdate(onDevice: Set<Int64>) -> Bool {
        guard let snapshot else { return true }
        return members.filter(onDevice.contains) != snapshot
    }

    /// A stable fragment for the plan's input hash (a reorder alone must invalidate a cached plan).
    var hashComponent: String {
        "pl\(playlistID):\(members.map(String.init).joined(separator: ","))|"
            + (snapshot.map { $0.map(String.init).joined(separator: ",") } ?? "none")
    }

    static func count(_ states: [PlaylistUpdateState], onDevice: Set<Int64>) -> Int {
        states.filter { $0.needsUpdate(onDevice: onDevice) }.count
    }

    /// The states of all playlists of a profile.
    static func fetch(_ db: Database, profileID: Int64) throws -> [PlaylistUpdateState] {
        let ids = try Int64.fetchAll(db, sql: """
            SELECT p.id FROM playlists p
            INNER JOIN sync_profile_playlists spp ON spp.playlist_id = p.id
            WHERE spp.profile_id = ? ORDER BY p.id
            """, arguments: [profileID])
        return try ids.map { id in
            let members = try Int64.fetchAll(db, sql: """
                SELECT track_id FROM playlist_tracks WHERE playlist_id = ? ORDER BY position, added_at
                """, arguments: [id])
            let json = try String.fetchOne(db, sql: """
                SELECT snapshot_json FROM playlist_sync_snapshots WHERE profile_id = ? AND playlist_id = ?
                """, arguments: [profileID, id])
            return PlaylistUpdateState(playlistID: id, members: members, snapshot: json.map(Self.trackIDs(fromSnapshot:)))
        }
    }

    static func trackIDs(fromSnapshot json: String) -> [Int64] {
        guard let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries.compactMap { ($0["track_id"] as? NSNumber)?.int64Value }
    }
}
