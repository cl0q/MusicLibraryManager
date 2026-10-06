import Foundation
import GRDB

// Use a Track from the Library… (CM-ALBD-ABSENT, IMP-095): a track of the library takes the place
// of a `Track ‹n›` gap in an album. The data and words of the picker sheet and the undo step.

enum AlbumPlacement {
    /// The disc and number of a `Not in library` row (`album-absent://‹album›/‹disc›/‹number›`,
    /// `AlbumLayout.rows`); nil for any other row.
    static func position(of row: TrackRow) -> (disc: Int, number: Int)? {
        position(ofPath: row.track.originalPath)
    }

    static func position(ofPath path: String) -> (disc: Int, number: Int)? {
        let prefix = "album-absent://"
        guard path.hasPrefix(prefix) else { return nil }
        let parts = path.dropFirst(prefix.count).split(separator: "/")
        guard parts.count == 3, let disc = Int(parts[1]), let number = Int(parts[2]) else { return nil }
        return (disc, number)
    }

    /// `The chosen track becomes track 3 of “Low Season”.` — `track 3 on disc 2 of …` for an album
    /// with several discs.
    static func sentence(album: String, disc: Int, number: Int, hasDiscs: Bool) -> String {
        let place = hasDiscs ? "track \(number) on disc \(disc)" : "track \(number)"
        return "The chosen track becomes \(place) of “\(album)”."
    }

    static let footnote = "The track’s own tags are not changed."
    static let title = "Use a Track from the Library"
    static let button = "Use"
    static let searchPrompt = "Search the library"
    static let nothingFound = "No track matches the search."

    static func couldntUse(_ title: String) -> String { "Couldn’t use “\(title)” — the library database didn’t answer. Nothing was changed." }
}

extension AlbumTrackRepository {
    /// The listed tracks that are not on the album and match the search (title, artist, album,
    /// genre … — the search field's SQL), by title. At most `limit`.
    func libraryTracks(notOn albumID: Int64, matching filter: SearchFilter, limit: Int = 300) async throws -> [Track] {
        let (predicate, arguments) = TrackSearchSQL.predicate(for: filter)
        var all = StatementArguments([albumID])
        all += arguments
        all += [limit]
        return try await database.read { db in
            try Track.fetchAll(db, sql: """
                SELECT * FROM tracks
                WHERE \(TrackVisibility.listedSQL)
                  AND NOT EXISTS (SELECT 1 FROM album_tracks WHERE album_tracks.album_id = ? AND album_tracks.track_id = tracks.id)
                  AND \(predicate)
                ORDER BY title COLLATE NOCASE, artist COLLATE NOCASE, id
                LIMIT ?
                """, arguments: all)
        }
    }
}

extension ShellEdits {
    /// `Use`: the track joins the album and takes the gap's disc and number — one undo step,
    /// `Add to “‹album›”`, the same as adding tracks. No tag is written: the track keeps its own
    /// album tag. Returns nil when the track was already a member.
    @discardableResult
    func useTrack(_ trackID: Int64, inAlbum albumID: Int64, disc: Int, number: Int) async throws -> AlbumEditResult? {
        try await addTracks(toAlbum: albumID, trackIDs: [trackID], target: (disc, number))
    }
}
