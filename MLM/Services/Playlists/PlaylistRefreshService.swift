import Foundation

// MARK: - Refresh from ‹Source› (DEC-023, V-PLD.E08, UC-KEY-15)

/// Pulls the tracks that are new at a linked playlist's source — **add-only**: a refresh never
/// removes a track from the playlist and never reorders what is there (`playlists.html`
/// "Refreshed from SoundCloud — 3 new tracks, nothing removed"; B3-PLAN §5 question 5 — open,
/// add-only implemented). Offered for every linked playlist (was: YouTube URLs and Liked only).
///
/// - Liked playlists use their source's likes sync, which rewrites the playlist in the
///   source's order and drops tracks; every row it dropped is put back exactly afterwards
///   (same position, `added_at` and row id), so the net effect is add-only.
/// - Other linked playlists: the source's list is read, entries not in the library become
///   not-downloaded tracks (no source name as album, DEC-013), and the playlist's missing
///   tracks are appended in the source's order.
///
/// One Activity operation per refresh, subject = the playlist (`Refresh “‹playlist›”`).
@MainActor
struct PlaylistRefreshService {
    /// The remote side, injectable for tests (no network in tests).
    struct Remote {
        /// The source's likes sync for a Liked playlist (rewrites its track list).
        var syncLiked: @MainActor (_ source: Source) async throws -> Void
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

    /// Whether a playlist can be refreshed at all (`Refresh from ‹Source›` is offered).
    static func canRefresh(_ playlist: Playlist) -> Bool {
        playlist.sourceId != nil && (playlist.isLiked == 1 || !(playlist.externalId ?? "").isEmpty)
    }

    /// Refreshes the playlist; returns how many tracks were added to it.
    func refresh(playlistID: Int64) async throws -> Int {
        guard let playlist = try await playlists.fetch(id: playlistID), let sourceID = playlist.sourceId else {
            throw RefreshError.notLinked
        }
        guard let source = try await sources.fetch(id: sourceID) else { throw RefreshError.sourceMissing }
        guard let before = try await playlists.snapshot(id: playlistID) else { throw PlaylistRepositoryError.playlistNotFound }
        let had = Set(before.entries.map(\.trackId))

        if playlist.isLiked == 1 {
            try await remote.syncLiked(source)
            // Add-only: put back every row the sync dropped, exactly.
            if let after = try await playlists.snapshot(id: playlistID) {
                let kept = Set(after.entries.map(\.trackId))
                let dropped = before.entries.filter { !kept.contains($0.trackId) }
                if !dropped.isEmpty { _ = try await playlists.restoreEntries(dropped) }
            }
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
            syncLiked: { source in
                guard let tokenStorage = container.tokenStorage, let trackRepo = container.trackRepository,
                      let sourceRepo = container.sourceRepository else { throw PlaylistRefreshService.RefreshError.sourceMissing }
                switch source.sourceType {
                case .soundcloud:
                    guard let oauth = container.oauthManager else { throw PlaylistRefreshService.RefreshError.sourceMissing }
                    _ = try await SoundCloudClient(tokenStorage: tokenStorage, oauthManager: oauth, trackRepository: trackRepo,
                                                   sourceRepository: sourceRepo, playlistRepository: container.playlistRepository)
                        .syncLikes()
                case .spotify:
                    guard let oauth = container.oauthManager else { throw PlaylistRefreshService.RefreshError.sourceMissing }
                    _ = try await SpotifyClient(tokenStorage: tokenStorage, oauthManager: oauth, trackRepository: trackRepo,
                                                sourceRepository: sourceRepo).syncLikedSongs()
                case .appleMusic:
                    _ = try await AppleMusicClient(tokenStorage: tokenStorage, trackRepository: trackRepo,
                                                   sourceRepository: sourceRepo).syncLibrary()
                case .unknown:
                    throw PlaylistRefreshService.RefreshError.unsupported(source.playlistSourceIdentity.displayName)
                }
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
