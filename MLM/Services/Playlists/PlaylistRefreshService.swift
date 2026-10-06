import Foundation

// MARK: - Refresh from ‹Source› (DEC-023, V-PLD.E08, UC-KEY-15)

/// Pulls the tracks that are new at a linked playlist's source — **add-only**: a refresh never
/// removes a track from the playlist and never reorders what is there (`playlists.html`
/// "Refreshed from SoundCloud — 3 new tracks, nothing removed"; B3-PLAN §5 question 5 — open,
/// add-only implemented). Offered for every linked playlist (was: YouTube URLs and Liked only).
///
/// - The Liked playlist (SoundCloud only — W3-PL review S3): the likes are synced into the
///   library and only the liked tracks the playlist doesn't hold yet are **appended**; existing
///   rows keep their position, `added_at` and row id (review S2 — the likes sync's own
///   replace-in-place never runs on this path).
/// - Other linked playlists: the source's list is read, entries not in the library become
///   not-downloaded tracks (no source name as album, DEC-013), and the playlist's missing
///   tracks are appended in the source's order.
///
/// One Activity operation per refresh, subject = the playlist (`Refresh “‹playlist›”`).
@MainActor
struct PlaylistRefreshService {
    /// The remote side, injectable for tests (no network in tests).
    struct Remote {
        /// The liked tracks that have a file, in the source's order, after syncing the likes
        /// into the library (never touching the playlist).
        var likedTracks: @MainActor (_ source: Source) async throws -> [Int64]
        /// The tracks of a linked playlist at its source, in the source's order.
        var listTracks: @MainActor (_ playlist: Playlist, _ source: Source) async throws -> [RemotePlaylistTrack]
    }

    enum RefreshError: Error, PlainCauseError, Equatable {
        case notLinked
        case sourceMissing
        case unsupported(String)
        case toolMissing(String)

        var plainCause: String {
            switch self {
            case .notLinked: "the playlist isn’t linked to a source"
            case .sourceMissing: "its source is no longer set up"
            case .unsupported(let source): "\(source) playlists can’t be refreshed"
            case .toolMissing(let tool): "\(tool) not found"
            }
        }
    }

    let playlists: PlaylistRepository
    let tracks: TrackRepository
    let sources: SourceRepository
    let remote: Remote

    /// Whether `Refresh from ‹Source›` can do something for the playlist (W3-PL review S3; a
    /// context menu never shows a dead item): a source row that exists (`sourceName` = its
    /// stored name; the device-ingest sentinel `-1` has none) and a provider that can refresh —
    /// SoundCloud likes, or a linked SoundCloud / YouTube / Spotify playlist.
    nonisolated static func canRefresh(_ playlist: Playlist, sourceName: String?) -> Bool {
        guard let sourceID = playlist.sourceId, sourceID > 0, let sourceName else { return false }
        let identity = PlaylistSourceIdentity(sourceName: sourceName)
        if playlist.isLiked == 1 { return identity == .soundcloud }
        guard !(playlist.externalId ?? "").isEmpty else { return false }
        switch identity {
        case .soundcloud, .youtube, .spotify: return true
        case .appleMusic, .other: return false
        }
    }

    /// Refreshes the playlist; returns how many tracks were added to it.
    func refresh(playlistID: Int64) async throws -> Int {
        guard let playlist = try await playlists.fetch(id: playlistID), let sourceID = playlist.sourceId else {
            throw RefreshError.notLinked
        }
        guard let source = try await sources.fetch(id: sourceID) else { throw RefreshError.sourceMissing }
        guard let before = try await playlists.snapshot(id: playlistID) else { throw PlaylistRepositoryError.playlistNotFound }
        let had = Set(before.entries.map(\.trackId))

        guard Self.canRefresh(playlist, sourceName: source.name) else {
            throw RefreshError.unsupported(source.playlistSourceIdentity.displayName)
        }

        if playlist.isLiked == 1 {
            // Add-only: append the liked tracks that aren't in it yet; nothing else changes.
            let liked = try await remote.likedTracks(source)
            _ = try await playlists.appendTracksReturningEntries(playlistId: playlistID, trackIds: liked)
        } else {
            let remoteTracks = try await remote.listTracks(playlist, source)
            var ids: [Int64] = []
            let sourceName = source.name.lowercased()
            for remoteTrack in remoteTracks {
                if let existing = try await tracks.fetchTrackByExternalId(remoteTrack.externalID, sourceName: sourceName),
                   let id = existing.id {
                    ids.append(id)
                    continue
                }
                let inserted = try await tracks.insert(remoteTrack.unresolvedTrack())
                guard let id = inserted.id else { continue }
                try await sources.linkTrackToSource(trackId: id, sourceId: sourceID, externalId: remoteTrack.externalID)
                ids.append(id)
            }
            _ = try await playlists.appendTracksReturningEntries(playlistId: playlistID, trackIds: ids)
        }
        let now = try await playlists.snapshot(id: playlistID)?.entries.map(\.trackId) ?? []
        return Set(now).subtracting(had).count
    }

    /// `Refresh finished — 3 new tracks` / `No new tracks` (the result Activity keeps; the
    /// status bar shows it as `Refresh finished — …`).
    static func resultText(newTracks: Int) -> String {
        newTracks == 0 ? "No new tracks" : StatusBarText.count(newTracks, "new track", "new tracks")
    }
}

extension PlaylistRefreshService.Remote {
    /// The real sources: SoundCloud / Spotify / Apple Music likes; SoundCloud, Spotify and
    /// YouTube playlists.
    @MainActor
    static func live(_ container: DependencyContainer) -> Self {
        Self(
            likedTracks: { source in
                guard let tokenStorage = container.tokenStorage, let trackRepo = container.trackRepository,
                      let sourceRepo = container.sourceRepository, let oauth = container.oauthManager
                else { throw PlaylistRefreshService.RefreshError.sourceMissing }
                guard source.sourceType == .soundcloud else {
                    throw PlaylistRefreshService.RefreshError.unsupported(source.playlistSourceIdentity.displayName)
                }
                return try await SoundCloudClient(tokenStorage: tokenStorage, oauthManager: oauth, trackRepository: trackRepo,
                                                  sourceRepository: sourceRepo, playlistRepository: container.playlistRepository)
                    .likedPlayableTrackIDs()
            },
            listTracks: { playlist, source in
                guard let externalID = playlist.externalId else { throw PlaylistRefreshService.RefreshError.notLinked }
                switch source.playlistSourceIdentity {
                case .youtube:
                    let downloader = YouTubeDownloader()
                    guard downloader.isAvailable else { throw PlaylistRefreshService.RefreshError.toolMissing("yt-dlp") }
                    return try await downloader.listPlaylist(url: externalID).entries.map { entry in
                        RemotePlaylistTrack(externalID: entry.id, title: entry.title, artist: entry.uploader ?? "Unknown",
                                            album: "", durationSeconds: entry.durationSeconds, format: "youtube",
                                            originalPath: entry.url)
                    }
                case .soundcloud:
                    guard let tokenStorage = container.tokenStorage, let oauth = container.oauthManager,
                          let trackRepo = container.trackRepository, let sourceRepo = container.sourceRepository
                    else { throw PlaylistRefreshService.RefreshError.sourceMissing }
                    let client = SoundCloudClient(tokenStorage: tokenStorage, oauthManager: oauth, trackRepository: trackRepo,
                                                  sourceRepository: sourceRepo, playlistRepository: container.playlistRepository)
                    let soundCloudTracks: [SoundCloudTrack]
                    if let numeric = Int(externalID) {
                        soundCloudTracks = try await client.fetchPlaylistTracks(playlistId: numeric)
                    } else {
                        let resolved = try await client.resolvePlaylist(url: externalID)
                        if let embedded = resolved.tracks, !embedded.isEmpty {
                            soundCloudTracks = embedded
                        } else {
                            soundCloudTracks = try await client.fetchPlaylistTracks(playlistId: resolved.id)
                        }
                    }
                    return soundCloudTracks.map { track in
                        RemotePlaylistTrack(externalID: String(track.id), title: track.title,
                                            artist: track.user?.username ?? "Unknown", album: "",
                                            durationSeconds: track.duration.map { $0 / 1000 }, format: "soundcloud",
                                            originalPath: track.permalinkUrl ?? "soundcloud://\(track.id)")
                    }
                case .spotify:
                    guard let tokenStorage = container.tokenStorage, let oauth = container.oauthManager,
                          let trackRepo = container.trackRepository, let sourceRepo = container.sourceRepository
                    else { throw PlaylistRefreshService.RefreshError.sourceMissing }
                    let client = SpotifyClient(tokenStorage: tokenStorage, oauthManager: oauth, trackRepository: trackRepo,
                                               sourceRepository: sourceRepo)
                    return try await client.fetchPlaylistTracks(playlistId: externalID).map { track in
                        RemotePlaylistTrack(externalID: track.id, title: track.name, artist: track.artists.first?.name ?? "Unknown",
                                            album: track.album?.name ?? "", durationSeconds: track.durationMs / 1000,
                                            format: "spotify", originalPath: "spotify://track/\(track.id)")
                    }
                case .appleMusic, .other:
                    throw PlaylistRefreshService.RefreshError.unsupported(source.playlistSourceIdentity.displayName)
                }
            }
        )
    }
}
