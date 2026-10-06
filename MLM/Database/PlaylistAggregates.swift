import Foundation
import GRDB

/// What one playlist holds, from one SQL aggregate (UC-TABLE-21): counts per availability state
/// (persisted, never a disk probe — UC-TABLE-20), total duration and when a track was last added
/// to it. The sidebar's second lines, the cards' subtitles, the grid's scopes, the detail's facts
/// line and `Add to Playlist ▸ Recent` all read these — one query for every playlist.
struct PlaylistSummary: Equatable, Sendable {
    let playlistID: Int64
    var totalTracks = 0
    var localTracks = 0
    var fileMissingTracks = 0
    var downloadingTracks = 0
    var failedTracks = 0
    var notDownloadedTracks = 0
    /// Sum of the known track durations, seconds.
    var totalSeconds = 0
    /// `playlist_tracks.added_at` of the newest row (`yyyy-MM-dd HH:mm:ss`, UTC).
    var lastAddedAt: String?

    /// Tracks that have a file (local or flagged missing) — never download candidates.
    var withFile: Int { localTracks + fileMissingTracks }

    /// The older aggregate shape (`PlaylistDownloadStatus`) for callers that use it.
    var downloadStatus: PlaylistDownloadStatus {
        PlaylistDownloadStatus(
            playlistID: playlistID,
            totalTracks: totalTracks,
            localTracks: withFile,
            downloadingTracks: downloadingTracks,
            failedTracks: failedTracks,
            notDownloadedTracks: notDownloadedTracks
        )
    }
}

extension PlaylistRepository {
    /// Every playlist's summary in one query, keyed by playlist id. Playlists without tracks
    /// are absent (read them as empty).
    func fetchSummaries() async throws -> [Int64: PlaylistSummary] {
        try await database.read { db in try Self.summaries(db, playlistID: nil) }
    }

    /// One playlist's summary (the detail header's facts line); empty when it has no tracks.
    func fetchSummary(playlistID: Int64) async throws -> PlaylistSummary {
        try await database.read { db in
            try Self.summaries(db, playlistID: playlistID)[playlistID] ?? PlaylistSummary(playlistID: playlistID)
        }
    }

    static func summaries(_ db: Database, playlistID: Int64?) throws -> [Int64: PlaylistSummary] {
        let filter = playlistID == nil ? "" : "WHERE pt.playlist_id = ?"
        let rows = try Row.fetchAll(db, sql: """
            SELECT
                pt.playlist_id AS playlist_id,
                COUNT(*) AS total,
                SUM(CASE WHEN \(TrackAvailabilitySQL.local) THEN 1 ELSE 0 END) AS local,
                SUM(CASE WHEN \(TrackAvailabilitySQL.fileMissing) THEN 1 ELSE 0 END) AS missing,
                SUM(CASE WHEN \(TrackAvailabilitySQL.downloading) THEN 1 ELSE 0 END) AS downloading,
                SUM(CASE WHEN \(TrackAvailabilitySQL.failed) THEN 1 ELSE 0 END) AS failed,
                SUM(CASE WHEN \(TrackAvailabilitySQL.noFile) AND NOT \(TrackAvailabilitySQL.downloadingStatus)
                         AND NOT \(TrackAvailabilitySQL.failureRecorded) THEN 1 ELSE 0 END) AS not_downloaded,
                SUM(COALESCE(t.duration, 0)) AS seconds,
                MAX(pt.added_at) AS last_added
            FROM playlist_tracks pt
            INNER JOIN tracks t ON t.id = pt.track_id
            \(filter)
            GROUP BY pt.playlist_id
        """, arguments: playlistID.map { [$0] } ?? [])
        var result: [Int64: PlaylistSummary] = [:]
        for row in rows {
            guard let id: Int64 = row["playlist_id"] else { continue }
            result[id] = PlaylistSummary(
                playlistID: id,
                totalTracks: row["total"] ?? 0,
                localTracks: row["local"] ?? 0,
                fileMissingTracks: row["missing"] ?? 0,
                downloadingTracks: row["downloading"] ?? 0,
                failedTracks: row["failed"] ?? 0,
                notDownloadedTracks: row["not_downloaded"] ?? 0,
                totalSeconds: row["seconds"] ?? 0,
                lastAddedAt: row["last_added"]
            )
        }
        return result
    }
}
