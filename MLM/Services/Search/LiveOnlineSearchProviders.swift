import Foundation

// MARK: - The real sources behind the Online scope (ported from the old search pane)

/// Builds the providers for the connected sources: SoundCloud and Spotify when signed in,
/// YouTube always (it says `yt-dlp not found` when the tool is missing), DAB when token
/// storage exists. The clients only search; none of them writes to the library here.
enum LiveOnlineSearchProviders {
    @MainActor
    static func make(_ container: DependencyContainer = .shared) -> [any OnlineSearchProviding] {
        var providers: [any OnlineSearchProviding] = []
        if let tokens = container.tokenStorage, let oauth = container.oauthManager,
           let trackRepository = container.trackRepository, let sourceRepository = container.sourceRepository {
            if tokens.hasCredentials(service: .soundcloud) {
                let client = SoundCloudClient(tokenStorage: tokens, oauthManager: oauth, trackRepository: trackRepository,
                                              sourceRepository: sourceRepository, playlistRepository: container.playlistRepository)
                providers.append(SoundCloudSearch(client: client))
            }
            if tokens.hasCredentials(service: .spotify) {
                let client = SpotifyClient(tokenStorage: tokens, oauthManager: oauth, trackRepository: trackRepository,
                                           sourceRepository: sourceRepository, playlistRepository: container.playlistRepository)
                providers.append(SpotifySearch(client: client))
            }
        }
        providers.append(YouTubeSearch())
        if let tokens = container.tokenStorage {
            providers.append(DABSearch(client: DABClient(tokenStorage: tokens)))
        }
        return providers
    }

    /// Plain-words cause of a client error (UC-COPY-11).
    static func failure(_ error: Error) -> OnlineSourceFailure {
        if let failure = error as? OnlineSourceFailure { return failure }
        if let url = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(url.code) {
            return .offline
        }
        if let soundCloud = error as? SoundCloudClient.SoundCloudError {
            switch soundCloud {
            case .notAuthenticated, .tokenExpired: return .signInExpired
            case .apiError(let status, _) where status == 401: return .signInExpired
            default: break
            }
        }
        if let spotify = error as? SpotifyClient.SpotifyError {
            switch spotify {
            case .notAuthenticated: return .signInExpired
            case .apiError(let status, _) where status == 401: return .signInExpired
            default: break
            }
        }
        return .noAnswer(details: error.localizedDescription)
    }

    static let resultLimit = 10
}

private struct SoundCloudSearch: OnlineSearchProviding, @unchecked Sendable {
    let client: SoundCloudClient
    let source = OnlineSource.soundcloud
    var unavailableReason: OnlineSourceFailure? { nil }

    func search(_ query: String) async throws -> [RemoteSearchResult] {
        do { return try await client.search(query: query, limit: LiveOnlineSearchProviders.resultLimit) } catch {
            throw LiveOnlineSearchProviders.failure(error)
        }
    }
}

private struct SpotifySearch: OnlineSearchProviding, @unchecked Sendable {
    let client: SpotifyClient
    let source = OnlineSource.spotify
    var unavailableReason: OnlineSourceFailure? { nil }

    func search(_ query: String) async throws -> [RemoteSearchResult] {
        do { return try await client.search(query: query, limit: LiveOnlineSearchProviders.resultLimit) } catch {
            throw LiveOnlineSearchProviders.failure(error)
        }
    }
}

private struct YouTubeSearch: OnlineSearchProviding, @unchecked Sendable {
    let downloader = YouTubeDownloader()
    let source = OnlineSource.youtube
    var unavailableReason: OnlineSourceFailure? { downloader.isAvailable ? nil : .toolMissing }

    func search(_ query: String) async throws -> [RemoteSearchResult] {
        do {
            return try await downloader.search(query: query, limit: LiveOnlineSearchProviders.resultLimit).map { entry in
                RemoteSearchResult(
                    id: "yt-\(entry.id)",
                    source: .youtube,
                    artist: entry.uploader ?? "",
                    title: entry.title,
                    durationSeconds: entry.durationSeconds,
                    externalId: entry.id,
                    sourceURL: entry.url
                )
            }
        } catch {
            throw LiveOnlineSearchProviders.failure(error)
        }
    }
}

private struct DABSearch: OnlineSearchProviding, @unchecked Sendable {
    let client: DABClient
    let source = OnlineSource.dab
    var unavailableReason: OnlineSourceFailure? { nil }

    func search(_ query: String) async throws -> [RemoteSearchResult] {
        do {
            return try await client.searchTracks(query: query, limit: LiveOnlineSearchProviders.resultLimit).map { track in
                RemoteSearchResult(
                    id: "dab-\(track.id)",
                    source: .dab,
                    artist: track.artist,
                    title: track.title,
                    durationSeconds: track.duration.map { Int($0) },
                    externalId: String(track.id),
                    sourceURL: nil
                )
            }
        } catch {
            throw LiveOnlineSearchProviders.failure(error)
        }
    }
}
