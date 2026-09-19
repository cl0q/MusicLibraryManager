import Foundation
import Testing
import GRDB
@testable import MLM

@Suite("SoundCloudProviderImportTests")
@MainActor
struct SoundCloudProviderImportTests {

    // MARK: - Fakes

    private actor RoutingHTTPClient: SoundCloudHTTPRequesting {
        struct Route: Sendable {
            let matches: @Sendable (URL) -> Bool
            let handler: @Sendable (URLRequest) -> (statusCode: Int, data: Data)
        }

        private let routes: [Route]
        private var _requests: [URLRequest] = []

        init(_ routes: [Route]) {
            self.routes = routes
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            _requests.append(request)
            let url = request.url ?? URL(string: "https://api.soundcloud.com/")!
            for route in routes {
                if route.matches(url) {
                    let result = route.handler(request)
                    let http = HTTPURLResponse(
                        url: url,
                        statusCode: result.statusCode,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                    return (result.data, http)
                }
            }
            let http = HTTPURLResponse(
                url: url,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data("no route for \(url.path)".utf8), http)
        }

        func requests() -> [URLRequest] { _requests }
    }

    private final class TokenStoreSpy: SoundCloudTokenStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var creds: TokenStorage.Credentials?

        init(accessToken: String = "access-token") {
            creds = TokenStorage.Credentials(
                accessToken: accessToken,
                refreshToken: "refresh-token",
                expiryDate: nil
            )
        }

        func getCredentials(service: TokenStorage.Service) throws -> TokenStorage.Credentials? {
            lock.lock(); defer { lock.unlock() }
            return creds
        }
        func saveTokens(service: TokenStorage.Service, accessToken: String, refreshToken: String?, expiresIn: Int?) throws {
            lock.lock(); defer { lock.unlock() }
            creds = TokenStorage.Credentials(
                accessToken: accessToken,
                refreshToken: refreshToken ?? creds?.refreshToken,
                expiryDate: expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
            )
        }
        func updateAccessToken(service: TokenStorage.Service, accessToken: String, expiresIn: Int) throws {
            lock.lock(); defer { lock.unlock() }
            creds = TokenStorage.Credentials(
                accessToken: accessToken,
                refreshToken: creds?.refreshToken,
                expiryDate: Date().addingTimeInterval(TimeInterval(expiresIn))
            )
        }
        func deleteCredentials(service: TokenStorage.Service) throws {
            lock.lock(); defer { lock.unlock() }
            creds = nil
        }
    }

    private struct NoopRefresherBox: SoundCloudTokenRefreshing {
        func refresh(refreshToken: String) async throws -> OAuthManager.TokenResponse {
            fatalError("tests in this suite must not trigger a refresh")
        }
    }

    // MARK: - Helpers

    private nonisolated static let profileJSON = Data("""
    {
      "id": 42,
      "username": "tester",
      "avatar_url": null,
      "full_name": null,
      "permalink": "tester"
    }
    """.utf8)

    private nonisolated static func trackJSON(id: Int, title: String) -> String {
        """
        {
          "id": \(id),
          "title": "\(title)",
          "duration": 180000,
          "genre": "Electronic",
          "permalink_url": "https://soundcloud.com/tester/\(title.lowercased())",
          "stream_url": null,
          "artwork_url": null,
          "created_at": "2026/07/21 08:00:00 +0000",
          "user": {
            "id": 42,
            "username": "tester",
            "avatar_url": null,
            "full_name": null,
            "permalink": "tester"
          }
        }
        """
    }

    private nonisolated static func playlistsCollectionJSON(
        playlists: [(id: Int, title: String, sharing: String)],
        nextHref: String? = nil
    ) -> Data {
        let items = playlists.map { """
            {
              "id": \($0.id),
              "title": "\($0.title)",
              "track_count": 2,
              "description": null,
              "permalink_url": null,
              "artwork_url": null,
              "tracks": [],
              "sharing": "\($0.sharing)"
            }
            """ }.joined(separator: ",")
        let next = nextHref.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {
          "collection": [\(items)],
          "next_href": \(next)
        }
        """.utf8)
    }

    private nonisolated static func tracksCollectionJSON(tracks: [(id: Int, title: String)]) -> Data {
        let items = tracks.map { trackJSON(id: $0.id, title: $0.title) }.joined(separator: ",")
        return Data("""
        {
          "collection": [\(items)],
          "next_href": null
        }
        """.utf8)
    }

    private func makeClient(http: RoutingHTTPClient) throws -> SoundCloudClient {
        let database = try DatabaseManager.inMemory()
        return SoundCloudClient(
            tokenStorage: TokenStoreSpy(),
            oauthManager: OAuthManager(),
            trackRepository: TrackRepository(database: database),
            sourceRepository: SourceRepository(database: database),
            clientId: "client-id",
            clientSecret: "client-secret",
            http: http,
            refresher: NoopRefresherBox()
        )
    }

    private func makeProvider(
        http: RoutingHTTPClient
    ) throws -> (SoundCloudPlaylistProvider, DatabaseQueue, PlaylistRepository, TrackRepository) {
        let database = try DatabaseManager.inMemory()
        let trackRepo = TrackRepository(database: database)
        let sourceRepo = SourceRepository(database: database)
        let playlistRepo = PlaylistRepository(database: database)
        let client = SoundCloudClient(
            tokenStorage: TokenStoreSpy(),
            oauthManager: OAuthManager(),
            trackRepository: trackRepo,
            sourceRepository: sourceRepo,
            clientId: "client-id",
            clientSecret: "client-secret",
            http: http,
            refresher: NoopRefresherBox()
        )
        let provider = SoundCloudPlaylistProvider(
            client: client,
            trackRepository: trackRepo,
            sourceRepository: sourceRepo,
            playlistRepository: playlistRepo
        )
        return (provider, database, playlistRepo, trackRepo)
    }

    /// Standard routes for a playlist with id 42, title "My Set", 2 embedded tracks.
    private nonisolated static func standardRoutes(
        playlistId: Int = 42,
        playlistTitle: String = "My Set",
        sharing: String = "public",
        tracks: [(id: Int, title: String)] = [(1, "Track A"), (2, "Track B")]
    ) -> [RoutingHTTPClient.Route] {
        [
            RoutingHTTPClient.Route(
                matches: { url in url.path.hasSuffix("/me") },
                handler: { _ in (200, profileJSON) }
            ),
            RoutingHTTPClient.Route(
                matches: { url in url.path.hasSuffix("/me/playlists") },
                handler: { _ in
                    (200, playlistsCollectionJSON(
                        playlists: [(playlistId, playlistTitle, sharing)],
                        nextHref: nil
                    ))
                }
            ),
            RoutingHTTPClient.Route(
                matches: { url in url.path.hasSuffix("/resolve") },
                handler: { _ in
                    let trackItems = tracks.map { trackJSON(id: $0.id, title: $0.title) }.joined(separator: ",")
                    let data = Data("""
                    {
                      "kind": "playlist",
                      "id": \(playlistId),
                      "title": "\(playlistTitle)",
                      "track_count": \(tracks.count),
                      "sharing": "\(sharing)",
                      "tracks": [\(trackItems)]
                    }
                    """.utf8)
                    return (200, data)
                }
            ),
            RoutingHTTPClient.Route(
                matches: { url in url.path.contains("/playlists/") && url.path.hasSuffix("/tracks") },
                handler: { _ in
                    (200, tracksCollectionJSON(tracks: tracks))
                }
            ),
        ]
    }

    // MARK: - Tests

    @Test func soundCloudBrowseModeIsAccountPlaylistsAndURL() async throws {
        let http = RoutingHTTPClient(Self.standardRoutes())
        let (provider, _, _, _) = try makeProvider(http: http)

        #expect(provider.browseMode == .accountPlaylistsAndURL)
    }

    @Test func fetchPlaylistsSummariesCarryPrivacy() async throws {
        let http = RoutingHTTPClient([
            RoutingHTTPClient.Route(
                matches: { url in url.path.hasSuffix("/me/playlists") },
                handler: { _ in
                    (200, Self.playlistsCollectionJSON(
                        playlists: [(1, "Public Set", "public"), (2, "Private Set", "private")],
                        nextHref: nil
                    ))
                }
            ),
        ])
        let (provider, _, _, _) = try makeProvider(http: http)

        let summaries = try await provider.fetchPlaylists()

        #expect(summaries.count == 2)
        #expect(summaries[0].isPrivate == false)
        #expect(summaries[1].isPrivate == true)
    }

    @Test func urlImportStagesPreviewWithoutWritingToLibrary() async throws {
        let http = RoutingHTTPClient(Self.standardRoutes())
        let (provider, database, _, _) = try makeProvider(http: http)

        let preview = try await provider.fetchPreview(fromURL: "https://soundcloud.com/user/sets/my-set")

        #expect(preview.title == "My Set")
        #expect(preview.tracks.count == 2)

        // Track table must still be empty — previewing must never mutate the library.
        let trackCount = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks")
        }
        #expect(trackCount == 0)
    }

    @Test func urlImportUsesNumericPlaylistIdAsExternalID() async throws {
        let http = RoutingHTTPClient(Self.standardRoutes(playlistId: 42))
        let (provider, _, _, _) = try makeProvider(http: http)

        let preview = try await provider.fetchPreview(fromURL: "https://soundcloud.com/user/sets/my-set")

        #expect(preview.externalID == "42")
        #expect(preview.externalID != "https://soundcloud.com/user/sets/my-set")
    }

    @Test func urlImportAndAccountImportConvergeOnTheSameLocalPlaylist() async throws {
        let http = RoutingHTTPClient(Self.standardRoutes(playlistId: 42))
        let (provider, database, playlistRepo, _) = try makeProvider(http: http)

        // First: import via account list
        let summaries = try await provider.fetchPlaylists()
        let accountPreview = try await provider.fetchPreview(for: summaries[0])
        let first = try await provider.persist(
            preview: accountPreview,
            selectedTracks: accountPreview.tracks
        )

        // Second: import via URL of the same playlist
        let urlPreview = try await provider.fetchPreview(fromURL: "https://soundcloud.com/user/sets/my-set")
        let second = try await provider.persist(
            preview: urlPreview,
            selectedTracks: urlPreview.tracks
        )

        #expect(first.playlistID == second.playlistID)

        let allPlaylists = try await playlistRepo.fetchAll()
        let synced = allPlaylists.filter { $0.category == "synced" }
        #expect(synced.count == 1)
    }

    @Test func persistCreatesSuffixedCopyWhenNameAlreadyTaken() async throws {
        let http = RoutingHTTPClient(Self.standardRoutes(playlistId: 42, playlistTitle: "My Set"))
        let (provider, _, playlistRepo, _) = try makeProvider(http: http)

        // Pre-create a local playlist with the same name
        let original = try await playlistRepo.create(name: "My Set")

        let preview = try await provider.fetchPreview(fromURL: "https://soundcloud.com/user/sets/my-set")
        let result = try await provider.persist(
            preview: preview,
            selectedTracks: preview.tracks
        )

        let imported = try await playlistRepo.fetch(id: result.playlistID)
        #expect(imported?.name == "My Set 2")

        // Original is untouched
        let originalAfter = try await playlistRepo.fetch(id: original.id!)
        #expect(originalAfter?.id == original.id)
        #expect(originalAfter?.name == "My Set")
    }

    @Test func persistIsIdempotentForSameExternalId() async throws {
        let http = RoutingHTTPClient(Self.standardRoutes(playlistId: 42, playlistTitle: "My Set"))
        let (provider, _, playlistRepo, _) = try makeProvider(http: http)

        let preview = try await provider.fetchPreview(fromURL: "https://soundcloud.com/user/sets/my-set")

        let first = try await provider.persist(
            preview: preview,
            selectedTracks: preview.tracks
        )
        let second = try await provider.persist(
            preview: preview,
            selectedTracks: preview.tracks
        )

        #expect(first.playlistID == second.playlistID)

        let allPlaylists = try await playlistRepo.fetchAll()
        let synced = allPlaylists.filter { $0.category == "synced" && $0.name.contains("My Set") }
        #expect(synced.count == 1)
        #expect(!allPlaylists.contains(where: { $0.name == "My Set 2" }))
    }

    @Test func persistLinksEverySelectedTrackInOrder() async throws {
        let tracks = [(1, "Track A"), (2, "Track B"), (3, "Track C")]
        let http = RoutingHTTPClient(Self.standardRoutes(playlistId: 42, tracks: tracks))
        let (provider, _, playlistRepo, _) = try makeProvider(http: http)

        let preview = try await provider.fetchPreview(fromURL: "https://soundcloud.com/user/sets/my-set")
        let selected = Array(preview.tracks.prefix(2))
        let result = try await provider.persist(
            preview: preview,
            selectedTracks: selected
        )

        let persistedTracks = try await playlistRepo.fetchTracks(playlistId: result.playlistID)
        #expect(persistedTracks.count == 2)
        #expect(persistedTracks[0].title == "Track A")
        #expect(persistedTracks[1].title == "Track B")
    }

    @Test func urlImportSurfacesNotAPlaylistError() async throws {
        let http = RoutingHTTPClient([
            RoutingHTTPClient.Route(
                matches: { url in url.path.hasSuffix("/resolve") },
                handler: { _ in
                    let data = Data("""
                    {
                      "kind": "track",
                      "id": 99,
                      "title": "Some Track"
                    }
                    """.utf8)
                    return (200, data)
                }
            ),
        ])
        let (provider, _, _, _) = try makeProvider(http: http)

        // Direct provider call throws
        await #expect(throws: RemotePlaylistProviderError.self) {
            _ = try await provider.fetchPreview(fromURL: "https://soundcloud.com/user/some-track")
        }

        // Through the ViewModel, the error message is user-facing
        let preview = RemotePlaylistPreview(
            sourceName: "SoundCloud",
            externalID: "placeholder",
            title: "placeholder",
            tracks: []
        )
        let vm = RemotePlaylistsViewModel(
            provider: provider,
            downloadViewModel: DownloadViewModel()
        )
        await vm.importFromURL("https://soundcloud.com/user/some-track")

        #expect(vm.errorMessage == "That link is not a SoundCloud playlist")
    }
}
