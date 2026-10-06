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
    /// Tracks handed to the download lane.
    let downloadCount: Int
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

/// The library side of an import: which preview rows are already library tracks (the same
/// identity matching as online search, `TrackSearchQueries.libraryTrackIDs`: source id first,
/// then the link), and which source playlists are already imported. Reads only.
struct ImportLibraryQueries: Sendable {
    let database: any DatabaseReader

    /// Matches keyed by `RemotePlaylistTrack.externalID`.
    func matches(for tracks: [RemotePlaylistTrack], source: LinkSource) async throws -> [String: ImportPreviewMatch] {
        guard !tracks.isEmpty else { return [:] }
        let results = tracks.map { Self.searchResult(for: $0, source: source) }
        let ids = try await TrackSearchQueries(database: database).libraryTrackIDs(for: results)
        guard !ids.isEmpty else {
            // A track can be listed twice in a source playlist.
            return Dictionary(tracks.map { ($0.externalID, ImportPreviewMatch.new) }, uniquingKeysWith: { first, _ in first })
        }
        let remoteIDs: Set<Int64> = try await database.read { db in
            let list = Array(Set(ids.values))
            let placeholders = list.map { _ in "?" }.joined(separator: ",")
            return Set(try Int64.fetchAll(db, sql: "SELECT id FROM tracks WHERE id IN (\(placeholders)) AND organized_path IS NULL",
                                          arguments: StatementArguments(list)))
        }
        var matches: [String: ImportPreviewMatch] = [:]
        for track in tracks {
            if let id = ids[track.externalID] {
                matches[track.externalID] = remoteIDs.contains(id) ? .inLibrary(trackID: id) : .downloaded(trackID: id)
            } else {
                matches[track.externalID] = .new
            }
        }
        return matches
    }

    /// The playlist already linked to this source playlist (`Already imported`), if any.
    func linkedPlaylist(source: LinkSource, externalID: String) async throws -> (id: Int64, name: String)? {
        try await database.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT p.id, p.name FROM playlists p JOIN sources s ON s.id = p.source_id
                WHERE s.name = ? AND p.external_id = ? AND p.is_liked = 0
                ORDER BY p.id LIMIT 1
                """, arguments: [source.storedName, externalID])
            guard let row, let id: Int64 = row["id"] else { return nil }
            return (id, row["name"] ?? "")
        }
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

    static func searchResult(for track: RemotePlaylistTrack, source: LinkSource) -> RemoteSearchResult {
        let kind: RemoteSearchResult.Source = switch source {
        case .soundcloud: .soundcloud
        case .spotify: .spotify
        case .youtube: .youtube
        }
        let link = track.originalPath.hasPrefix("http") ? track.originalPath : nil
        return RemoteSearchResult(id: track.externalID, source: kind, artist: track.artist, title: track.title,
                                  durationSeconds: track.durationSeconds, externalId: track.externalID, sourceURL: link)
    }
}

/// Hands the import's downloads to the download lane as **one** Activity operation whose
/// subject is the playlist (`Import “‹playlist›”`, echoed `Importing · 12 of 44` on the
/// playlist). A second import queues behind a running one (PP-ACTIVITY-05).
@MainActor
protocol PlaylistDownloadStarting: AnyObject {
    /// A download operation is running or queued (a new one will queue behind it).
    var hasActiveDownloads: Bool { get }
    /// Registers and runs the operation; returns once it is registered (the downloads go on).
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

    var hasActiveDownloads: Bool {
        downloads.activity.activeOperations.contains { [.download, .recommendationDownload, .reelsDownload].contains($0.kind) }
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

/// Commits an import: tracks into the library (album left empty unless the source has a real
/// one — never the source name, DEC-013), the playlist (new, or add-only into the linked one;
/// linked only when `keepLinked`), then the downloads. Independent of the sheet: it runs to the
/// end when the sheet closes (DEC-044).
@MainActor
final class PlaylistImporter {
    private let trackRepository: TrackRepository
    private let sourceRepository: SourceRepository
    private let playlistRepository: PlaylistRepository
    private let queries: ImportLibraryQueries
    private let downloads: any PlaylistDownloadStarting
    private let notificationCenter: NotificationCenter

    init(trackRepository: TrackRepository, sourceRepository: SourceRepository, playlistRepository: PlaylistRepository,
         queries: ImportLibraryQueries, downloads: any PlaylistDownloadStarting,
         notificationCenter: NotificationCenter = .default) {
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
        self.playlistRepository = playlistRepository
        self.queries = queries
        self.downloads = downloads
        self.notificationCenter = notificationCenter
    }

    /// Words that sources (or older imports) put into `album` and that are not albums.
    nonisolated static let placeholderAlbums: Set<String> = ["soundcloud", "youtube", "spotify", "dab", "qobuz", "unknown", "unknown album"]

    /// The album a new track gets: the source's real album name, else empty (DEC-013).
    nonisolated static func album(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return placeholderAlbums.contains(trimmed.lowercased()) ? "" : trimmed
    }

    /// - Parameter sourceRowID: the `sources` row the tracks (and a linked playlist) belong to
    ///   (`RemotePlaylistProvider.sourceRowForLinking()`).
    func run(_ request: PlaylistImportRequest, sourceRowID: () async throws -> Int64) async throws -> PlaylistImportOutcome {
        let sourceID = try await sourceRowID()
        // Matched again at commit time: the library may have changed since the preview.
        let matches = try await queries.matches(for: request.tracks, source: request.source)

        var orderedIDs: [Int64] = []
        var seen = Set<Int64>()
        var inserted: [Track] = []
        var known: [Track] = []
        // A track listed twice in the source playlist becomes one library track.
        var insertedByExternalID: [String: Int64] = [:]
        for remote in request.tracks {
            if insertedByExternalID[remote.externalID] != nil { continue }
            if let id = matches[remote.externalID]?.trackID, let existing = try await trackRepository.fetchTrack(id: id) {
                if seen.insert(id).inserted {
                    orderedIDs.append(id)
                    known.append(existing)
                }
                continue
            }
            var track = remote.unresolvedTrack()
            track.album = Self.album(remote.album)
            let row = try await trackRepository.insert(track)
            guard let id = row.id else { continue }
            try await sourceRepository.linkTrackToSource(trackId: id, sourceId: sourceID, externalId: remote.externalID)
            insertedByExternalID[remote.externalID] = id
            if seen.insert(id).inserted {
                orderedIDs.append(id)
                inserted.append(row)
            }
        }

        let playlistID: Int64
        let playlistName: String
        switch request.target {
        case .existing(let id, let name):
            // Add-only: what is missing goes to the end; nothing is removed or reordered.
            try await playlistRepository.appendTracks(playlistId: id, trackIds: orderedIDs)
            playlistID = id
            playlistName = name
        case .newPlaylist where request.keepLinked:
            let playlist = try await playlistRepository.createSourcePlaylistPreservingExisting(
                name: request.preview.title, sourceId: sourceID, externalId: request.preview.externalID)
            guard let id = playlist.id else { throw RemotePlaylistProviderError.previewUnavailable }
            try await playlistRepository.appendTracks(playlistId: id, trackIds: orderedIDs)
            playlistID = id
            playlistName = playlist.name
        case .newPlaylist:
            // One-time import (WISH-13): an ordinary playlist, no link columns.
            let playlist = try await playlistRepository.createNumbered(baseName: request.preview.title, trackIds: orderedIDs)
            guard let id = playlist.id else { throw RemotePlaylistProviderError.previewUnavailable }
            playlistID = id
            playlistName = playlist.name
        }
        notificationCenter.post(name: .playlistDidChange, object: nil, userInfo: ["playlistId": playlistID])
        if !inserted.isEmpty {
            notificationCenter.post(name: .libraryDidImport, object: nil,
                                    userInfo: ["succeeded": inserted.count, "skipped": known.count])
        }

        var toDownload: [Track] = []
        if request.downloadNow {
            toDownload = inserted + (request.alsoDownloadKnown ? known.filter(\.isRemote) : [])
            if !toDownload.isEmpty {
                downloads.startDownloads(toDownload, preferredSource: request.source.preferredDownloadSource,
                                         playlistID: playlistID, playlistName: playlistName)
            }
        }
        return PlaylistImportOutcome(playlistID: playlistID, playlistName: playlistName,
                                     addedToLibrary: inserted.count, alreadyInLibrary: known.count,
                                     downloadCount: toDownload.count)
    }
}
