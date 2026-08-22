import Foundation

/// Metadata fetched from a remote playlist before the user commits it to the
/// local library. These values deliberately have no database IDs.
struct RemotePlaylistPreview: Identifiable, Hashable {
    let sourceName: String
    let externalID: String
    let title: String
    let tracks: [RemotePlaylistTrack]

    var id: String { "\(sourceName):\(externalID)" }
}

/// A remote track reference that can be reviewed before becoming a `Track`
/// record. `externalID` is the source-specific identity used at commit time.
struct RemotePlaylistTrack: Identifiable, Hashable {
    let externalID: String
    let title: String
    let artist: String
    let album: String
    let durationSeconds: Int?
    let format: String
    let originalPath: String

    var id: String { externalID }

    func unresolvedTrack() -> Track {
        var track = Track(
            artist: artist,
            album: album,
            title: title,
            format: format,
            originalPath: originalPath
        )
        track.duration = durationSeconds
        return track
    }
}

/// The durable playlist and track records created by an explicit import action.
struct RemotePlaylistPersistence {
    let playlistID: Int64
    let tracks: [Track]
}

/// The state presented after an explicit save or completed download.
struct RemotePlaylistImportResult: Equatable {
    let playlistID: Int64
    let selectedTrackCount: Int
    let downloadedCount: Int
    let failedCount: Int
    let didDownload: Bool
}
