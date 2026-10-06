import Foundation
import GRDB

// MARK: - Import Playlist from Source: the commit (S-IMPORT step 3, DEC-026, WISH-13)

/// Where the imported tracks go.
enum PlaylistImportTarget: Hashable, Sendable {
    /// A new playlist named after the source playlist (numbered when the name is taken).
    case newPlaylist
    /// The playlist already linked to this source playlist: missing tracks are **added** at
    /// the end — nothing is removed or reordered (re-importing a part never truncates it).
    case existing(id: Int64, name: String)
}

/// Exactly what the user confirmed in the sheet.
struct PlaylistImportRequest: Sendable {
    let preview: RemotePlaylistPreview
    /// The rows the preview showed (`All · First n · Random n`), in that order.
    let tracks: [RemotePlaylistTrack]
    let source: LinkSource
    var target: PlaylistImportTarget = .newPlaylist
    /// Off = one-time import: an ordinary playlist without `source_id` / `external_id`.
    var keepLinked = true
    /// Off = the tracks are added as `Not downloaded`.
    var downloadNow = true
    /// Also download the tracks that were in the library but not downloaded (S-IMPORT.N15).
    var alsoDownloadKnown = false
}

/// What the import did.
struct PlaylistImportOutcome: Equatable, Sendable {
    let playlistID: Int64
    let playlistName: String
    /// Tracks that were new to the library.
    let addedToLibrary: Int
    /// Tracks that were already library tracks (only added to the playlist).
    let alreadyInLibrary: Int
    /// Rows appended to the playlist (0 when it already had them all).
    let addedToPlaylist: Int
    /// Tracks handed to the download lane.
    let downloadCount: Int
}

/// The import couldn't be written; the cause in plain words (no database text, UC-COPY).
enum PlaylistImportError: Error, PlainCauseError, Equatable {
    case libraryNotWritable
    case playlistGone

    var plainCause: String {
        switch self {
        case .libraryNotWritable: "the library database couldn’t be updated"
        case .playlistGone: "the playlist isn’t in the library any more"
        }
    }
}

/// One preview row's relation to the library (§15.4: `New`, `In library`; the mockup's
/// `Already downloaded` for a library track that has its file).
enum ImportPreviewMatch: Equatable, Sendable {
    case new
    case inLibrary(trackID: Int64)
    case downloaded(trackID: Int64)

    var word: String {
        switch self {
        case .new: "New"
        case .inLibrary: "In library"
        case .downloaded: "Already downloaded"
        }
    }

    var trackID: Int64? {
        switch self {
        case .new: nil
        case .inLibrary(let id), .downloaded(let id): id
        }
    }
}

/// The library side of an import (S-IMPORT.N18): which preview rows are already library
/// tracks — **the source id first, then the link, then artist + title + duration (± 2 s)
/// against local tracks** — and which source playlists are already imported. Reads only; the
/// `Database`-level functions are what the commit uses inside its own transaction.
struct ImportLibraryQueries: Sendable {
    let database: any DatabaseReader

    /// Matches keyed by `RemotePlaylistTrack.externalID`.
    func matches(for tracks: [RemotePlaylistTrack], source: LinkSource) async throws -> [String: ImportPreviewMatch] {
        guard !tracks.isEmpty else { return [:] }
        return try await database.read { db in try Self.matches(db, tracks: tracks, source: source) }
    }

    static func matches(_ db: Database, tracks: [RemotePlaylistTrack], source: LinkSource) throws -> [String: ImportPreviewMatch] {
        var matches: [String: ImportPreviewMatch] = [:]
        for track in tracks where matches[track.externalID] == nil {
            guard let id = try trackID(db, for: track, source: source) else {
                matches[track.externalID] = .new
                continue
            }
            let hasFile = try Bool.fetchOne(db, sql: "SELECT organized_path IS NOT NULL FROM tracks WHERE id = ?", arguments: [id]) ?? false
            matches[track.externalID] = hasFile ? .downloaded(trackID: id) : .inLibrary(trackID: id)
        }
        return matches
    }

    /// The library track a remote track already is.
    static func trackID(_ db: Database, for track: RemotePlaylistTrack, source: LinkSource) throws -> Int64? {
        let name = source.storedName
        let external = track.externalID.trimmingCharacters(in: .whitespacesAndNewlines)
        // 1. The source's own id.
        if !external.isEmpty, let id = try Int64.fetchOne(db, sql: """
            SELECT ts.track_id FROM track_sources ts JOIN sources s ON s.id = ts.source_id
            JOIN tracks t ON t.id = ts.track_id
            WHERE s.name = ? AND ts.external_id = ? LIMIT 1
            """, arguments: [name, external]) {
            return id
        }
        // 2. The link (as the importers and search store it).
        var paths = ["\(name)://\(external)"]
        if track.originalPath.hasPrefix("http") {
            paths.append(track.originalPath)
            if source == .soundcloud { paths.append(SoundCloudLink.canonical(track.originalPath)) }
        }
        if source == .soundcloud, !external.isEmpty { paths.append("https://api.soundcloud.com/tracks/\(external)") }
        let placeholders = paths.map { _ in "?" }.joined(separator: ", ")
        if let id = try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE original_path IN (\(placeholders)) LIMIT 1",
                                       arguments: StatementArguments(paths)) {
            return id
        }
        if source == .youtube, !external.isEmpty, let id = try Int64.fetchOne(db, sql: """
            SELECT id FROM tracks WHERE (original_path LIKE ? OR original_path LIKE ?) LIMIT 1
            """, arguments: ["%youtube.com/watch?v=\(external)%", "%youtu.be/\(external)%"]) {
            return id
        }
        // 3. A local track with the same artist and title, within 2 s.
        return try localMatch(db, artist: track.artist, title: track.title, duration: track.durationSeconds)
    }

    /// Artist + title (normalised: case, diacritics, spacing) + duration ± 2 s, local tracks only.
    static func localMatch(_ db: Database, artist: String, title: String, duration: Int?) throws -> Int64? {
        guard let duration, !normalized(title).isEmpty, !normalized(artist).isEmpty else { return nil }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, artist, title FROM tracks
            WHERE organized_path IS NOT NULL AND duration BETWEEN ? AND ?
            ORDER BY id
            """, arguments: [duration - 2, duration + 2])
        let wantedTitle = normalized(title)
        let wantedArtist = normalized(artist)
        for row in rows {
            let candidateTitle: String = row["title"] ?? ""
            let candidateArtist: String = row["artist"] ?? ""
            if normalized(candidateTitle) == wantedTitle, normalized(candidateArtist) == wantedArtist {
                return row["id"]
            }
        }
        return nil
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The playlist already linked to this source playlist (`Already imported`), if any.
    func linkedPlaylist(source: LinkSource, externalID: String) async throws -> (id: Int64, name: String)? {
        try await database.read { db in
            guard let playlist = try Self.linkedPlaylist(db, sourceName: source.storedName, externalID: externalID),
                  let id = playlist.id else { return nil }
            return (id, playlist.name)
        }
    }

    static func linkedPlaylist(_ db: Database, sourceName: String, externalID: String) throws -> Playlist? {
        try Playlist.fetchOne(db, sql: """
            SELECT p.* FROM playlists p JOIN sources s ON s.id = p.source_id
            WHERE s.name = ? AND p.external_id = ? AND p.is_liked = 0
            ORDER BY p.id LIMIT 1
            """, arguments: [sourceName, externalID])
    }

    /// Every playlist linked to one of this source's playlists (not the Liked ones), with its
    /// source row — what `Refresh from Sources` refreshes.
    func linkedPlaylists(sourceName: String) async throws -> [(playlist: Playlist, source: Source)] {
        try await database.read { db in
            let playlists = try Playlist.fetchAll(db, sql: """
                SELECT p.* FROM playlists p JOIN sources s ON s.id = p.source_id
                WHERE s.name = ? AND p.is_liked = 0 AND p.external_id IS NOT NULL AND p.external_id != ''
                ORDER BY p.id
                """, arguments: [sourceName])
            return try playlists.compactMap { playlist in
                guard let sourceID = playlist.sourceId, let source = try Source.fetchOne(db, id: sourceID) else { return nil }
                return (playlist, source)
            }
        }
    }

    /// The Liked playlist of this source with its source row, if it has one — never created
    /// here (`Refresh from Sources` only appends to a Liked playlist that exists).
    func likedPlaylist(sourceName: String) async throws -> (playlist: Playlist, source: Source)? {
        try await database.read { db in
            guard let playlist = try Playlist.fetchOne(db, sql: """
                SELECT p.* FROM playlists p JOIN sources s ON s.id = p.source_id
                WHERE s.name = ? AND p.is_liked = 1 ORDER BY p.id LIMIT 1
                """, arguments: [sourceName]),
                  let sourceID = playlist.sourceId, let source = try Source.fetchOne(db, id: sourceID) else { return nil }
            return (playlist, source)
        }
    }

    /// Which of these paths (lower-cased A–Z, `LibraryFileCopier.pathKeys`) already are a
    /// track's `original_path`, compared case-insensitively (review H3).
    func knownOriginalPaths(_ keys: [String]) async -> Set<String> {
        guard !keys.isEmpty else { return [] }
        return (try? await database.read { db in
            var found = Set<String>()
            for start in stride(from: 0, to: keys.count, by: 400) {
                let chunk = Array(keys[start..<min(start + 400, keys.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                found.formUnion(try String.fetchAll(db, sql: """
                    SELECT LOWER(original_path) FROM tracks WHERE LOWER(original_path) IN (\(placeholders))
                    """, arguments: StatementArguments(chunk)))
            }
            return found
        }) ?? []
    }

    /// External ids of this source's playlists that are already imported (step 1's marker).
    func importedPlaylistIDs(source: LinkSource) async throws -> Set<String> {
        try await database.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT p.external_id FROM playlists p JOIN sources s ON s.id = p.source_id
                WHERE s.name = ? AND p.external_id IS NOT NULL AND p.is_liked = 0
                """, arguments: [source.storedName]))
        }
    }
}

/// Hands the import's downloads to the download lane as **one** Activity operation whose
/// subject is the playlist (`Import “‹playlist›”`, echoed `Importing · 12 of 44` on the
/// playlist). A second import queues behind a running one (PP-ACTIVITY-05).
@MainActor
protocol PlaylistDownloadStarting: AnyObject {
    /// Registers and runs the operation; returns at once (the downloads go on).
    func startDownloads(_ tracks: [Track], preferredSource: DownloadOrchestrator.PreferredSource,
                        playlistID: Int64, playlistName: String)
}

/// The app's starter: `DownloadViewModel.downloadTracks` with the playlist context.
@MainActor
final class LivePlaylistDownloadStarter: PlaylistDownloadStarting {
    private let downloads: DownloadViewModel

    init(downloads: DownloadViewModel) {
        self.downloads = downloads
    }

    func startDownloads(_ tracks: [Track], preferredSource: DownloadOrchestrator.PreferredSource,
                        playlistID: Int64, playlistName: String) {
        let downloads = self.downloads
        Task { @MainActor in
            await downloads.downloadTracks(tracks, preferredSource: preferredSource,
                                           context: .playlist(playlistID, name: playlistName))
        }
    }
}

/// Commits an import in **one database transaction** — matching, new tracks (album left empty
/// unless the source has a real one, never the source name, DEC-013), their `track_sources`
/// rows and the playlist rows — so two imports serialise and a failure leaves nothing
/// half-done. The playlist is new, or the linked one that only gets what it misses; it is
/// linked only when `keepLinked`. Then the downloads. Independent of the sheet: it runs to the
/// end when the sheet closes (DEC-044).
@MainActor
final class PlaylistImporter {
    private let database: any DatabaseWriter
    private let downloads: any PlaylistDownloadStarting
    private let notificationCenter: NotificationCenter

    init(database: any DatabaseWriter, downloads: any PlaylistDownloadStarting,
         notificationCenter: NotificationCenter = .default) {
        self.database = database
        self.downloads = downloads
        self.notificationCenter = notificationCenter
    }

    /// Words that sources (or older imports) put into `album` and that are not albums. A real
    /// album the source delivers is kept, even one called “Unknown”; providers give "" when
    /// they have none.
    nonisolated static let placeholderAlbums: Set<String> = ["soundcloud", "youtube", "spotify", "dab", "qobuz",
                                                            "unknown album", "soundcloud likes"]

    /// The album a new track gets: the source's real album name, else empty (DEC-013).
    nonisolated static func album(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return placeholderAlbums.contains(trimmed.lowercased()) ? "" : trimmed
    }

    /// What one transaction wrote.
    struct Committed: Sendable {
        var playlistID: Int64
        var playlistName: String
        var inserted: [Track] = []
        var known: [Track] = []
        var appended = 0
    }

    /// - Parameter sourceRowID: the `sources` row the tracks (and a linked playlist) belong to
    ///   (`RemotePlaylistProvider.sourceRowForLinking()`; may ask the network, so it runs
    ///   before the transaction).
    func run(_ request: PlaylistImportRequest, sourceRowID: () async throws -> Int64) async throws -> PlaylistImportOutcome {
        let sourceID = try await sourceRowID()
        let committed: Committed
        do {
            committed = try await database.write { db in try Self.commit(db, request, sourceID: sourceID) }
        } catch let error as PlaylistImportError {
            throw error
        } catch {
            AppLogger.shared.error("Importing “\(request.preview.title)” failed: \(error)", source: "Import")
            throw PlaylistImportError.libraryNotWritable
        }

        notificationCenter.post(name: .playlistDidChange, object: nil, userInfo: ["playlistId": committed.playlistID])
        if !committed.inserted.isEmpty {
            notificationCenter.post(name: .libraryDidImport, object: nil,
                                    userInfo: ["succeeded": committed.inserted.count, "skipped": committed.known.count])
        }
        var toDownload: [Track] = []
        if request.downloadNow {
            toDownload = committed.inserted + (request.alsoDownloadKnown ? committed.known.filter(\.isRemote) : [])
            if !toDownload.isEmpty {
                downloads.startDownloads(toDownload, preferredSource: request.source.preferredDownloadSource,
                                         playlistID: committed.playlistID, playlistName: committed.playlistName)
            }
        }
        return PlaylistImportOutcome(playlistID: committed.playlistID, playlistName: committed.playlistName,
                                     addedToLibrary: committed.inserted.count, alreadyInLibrary: committed.known.count,
                                     addedToPlaylist: committed.appended, downloadCount: toDownload.count)
    }

    /// The whole commit, inside the caller's write transaction.
    nonisolated static func commit(_ db: Database, _ request: PlaylistImportRequest, sourceID: Int64) throws -> Committed {
        let now = ISO8601DateFormatter().string(from: Date())
        var orderedIDs: [Int64] = []
        var seen = Set<Int64>()
        var inserted: [Track] = []
        var known: [Track] = []
        // A track listed twice in the source playlist becomes one library track.
        var byExternalID: [String: Int64] = [:]

        for remote in request.tracks {
            if byExternalID[remote.externalID] != nil { continue }
            // Matched inside the transaction: a concurrent import's tracks are seen.
            if let id = try ImportLibraryQueries.trackID(db, for: remote, source: request.source),
               let existing = try Track.fetchOne(db, id: id) {
                byExternalID[remote.externalID] = id
                if seen.insert(id).inserted { orderedIDs.append(id); known.append(existing) }
                continue
            }
            var track = remote.unresolvedTrack()
            track.album = album(remote.album)
            if request.source == .soundcloud, track.originalPath.hasPrefix("http") {
                track.originalPath = SoundCloudLink.canonical(track.originalPath)
            }
            track.searchText = DatabaseManager.foldedSearchText(track.rawSearchText)
            do {
                try track.insert(db)
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                // The link is already a library track under another identity: reuse that row.
                guard let existing = try Track.filter(Track.Columns.originalPath == track.originalPath).fetchOne(db),
                      let id = existing.id else { throw error }
                byExternalID[remote.externalID] = id
                if seen.insert(id).inserted { orderedIDs.append(id); known.append(existing) }
                continue
            }
            guard let id = track.id else { continue }
            AlbumTrackRepository.linkNewTrack(db, track)   // W4-3: a real album from the source joins its album
            try db.execute(sql: """
                INSERT OR IGNORE INTO track_sources (track_id, source_id, external_id, added_at) VALUES (?, ?, ?, ?)
                """, arguments: [id, sourceID, remote.externalID, now])
            byExternalID[remote.externalID] = id
            if seen.insert(id).inserted { orderedIDs.append(id); inserted.append(track) }
        }

        var committed: Committed
        switch request.target {
        case .existing(let id, let name):
            guard try Playlist.fetchOne(db, id: id) != nil else { throw PlaylistImportError.playlistGone }
            committed = Committed(playlistID: id, playlistName: name)
        case .newPlaylist where request.keepLinked:
            let sourceName = try String.fetchOne(db, sql: "SELECT name FROM sources WHERE id = ?", arguments: [sourceID]) ?? ""
            if let linked = try ImportLibraryQueries.linkedPlaylist(db, sourceName: sourceName, externalID: request.preview.externalID),
               let id = linked.id {
                // This source playlist is linked already: it is the target (one link each).
                committed = Committed(playlistID: id, playlistName: linked.name)
            } else {
                var playlist = try newPlaylist(db, name: request.preview.title)
                playlist.category = "synced"
                playlist.sourceId = sourceID
                playlist.externalId = request.preview.externalID
                playlist.dateCreated = now
                try playlist.insert(db)
                committed = Committed(playlistID: playlist.id ?? 0, playlistName: playlist.name)
            }
        case .newPlaylist:
            // One-time import (WISH-13): an ordinary playlist, no link columns.
            var playlist = try newPlaylist(db, name: request.preview.title)
            try playlist.insert(db)
            committed = Committed(playlistID: playlist.id ?? 0, playlistName: playlist.name)
        }
        committed.appended = try appendMissing(db, playlistID: committed.playlistID, trackIDs: orderedIDs)
        committed.inserted = inserted
        committed.known = known
        return committed
    }

    /// A native playlist row named `name` (numbered when taken, one name space) at the top of
    /// the sidebar's Playlists section — as `PlaylistRepository.createNumbered` places one.
    nonisolated private static func newPlaylist(_ db: Database, name: String) throws -> Playlist {
        let taken = Set(try String.fetchAll(db, sql: "SELECT name FROM playlists").map { $0.lowercased() })
        var playlist = Playlist.createNative(name: PlaylistRepository.numberedName(base: name, taken: taken))
        playlist.dateCreated = playlistTimestamp()
        playlist.position = try PlaylistFolderRepository.firstPosition(db, folderID: nil)
        return playlist
    }

    /// Add-only: appends the tracks the playlist doesn't have, in order. Returns how many.
    nonisolated private static func appendMissing(_ db: Database, playlistID: Int64, trackIDs: [Int64]) throws -> Int {
        let existing = Set(try Int64.fetchAll(db, sql: "SELECT track_id FROM playlist_tracks WHERE playlist_id = ?",
                                              arguments: [playlistID]))
        var tail = try String.fetchOne(db, sql: """
            SELECT position FROM playlist_tracks WHERE playlist_id = ? ORDER BY position DESC, added_at DESC LIMIT 1
            """, arguments: [playlistID])
        var count = 0
        for id in trackIDs where !existing.contains(id) {
            let position = FractionalIndexer.positionBetween(left: tail, right: nil)
            var entry = PlaylistTrack(id: nil, playlistId: playlistID, trackId: id, position: position,
                                      addedAt: playlistTimestamp())
            try entry.insert(db)
            tail = position
            count += 1
        }
        return count
    }

    /// `playlist_tracks.added_at` format (SQLite `CURRENT_TIMESTAMP`, UTC).
    nonisolated private static func playlistTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}
