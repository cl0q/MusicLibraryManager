import Foundation
import Testing
@testable import MLM

@Suite("SoundCloudPlaylist fetch / resolve")
struct SoundCloudPlaylistFetchTests {

    // MARK: - Fakes

    /// A fake HTTP seam that routes responses by inspecting the request URL
    /// (path + query). Lets one fake serve `me/playlists` page 1, page 2,
    /// `resolve`, etc. from a single scripted table.
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
            // No matching route — 500 so tests fail loudly instead of silently.
            let http = HTTPURLResponse(
                url: url,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data("no route".utf8), http)
        }

        func requests() -> [URLRequest] { _requests }
        func requestCount() -> Int { _requests.count }
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

    // MARK: - Helpers

    private func playlistCollectionJSON(
        playlists: [(id: Int, title: String)],
        nextHref: String?
    ) -> Data {
        let items = playlists.map { """
            {
              "id": \($0.id),
              "title": "\($0.title)",
              "track_count": 0,
              "description": null,
              "permalink_url": null,
              "artwork_url": null,
              "tracks": []
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

    // MARK: - fetchPlaylists pagination

    @Test
    func fetchPlaylists_followsNextHrefUntilExhausted() async throws {
        let page2URL = "https://api.soundcloud.com/me/playlists?next=page2&limit=50&linked_partitioning=1"
        let http = RoutingHTTPClient([
            // page 1
            .init(
                matches: { url in url.path.hasSuffix("/me/playlists") && url.query?.contains("next=") == false },
                handler: { _ in
                    (200, self.playlistCollectionJSON(
                        playlists: [(1, "Alpha"), (2, "Beta")],
                        nextHref: page2URL
                    ))
                }
            ),
            // page 2
            .init(
                matches: { url in url.query?.contains("next=page2") == true },
                handler: { _ in
                    (200, self.playlistCollectionJSON(
                        playlists: [(3, "Gamma")],
                        nextHref: nil
                    ))
                }
            ),
        ])
        let client = try makeClient(http: http)

        let result = try await client.fetchPlaylists()

        #expect(result.count == 3)
        #expect(result.map(\.title) == ["Alpha", "Beta", "Gamma"])
        #expect(await http.requestCount() == 2)
    }

    @Test
    func fetchPlaylists_stopsAtPageCapWithoutHanging() async throws {
        // Every page returns another next_href — without a cap this would loop forever.
        let http = RoutingHTTPClient([
            .init(
                matches: { _ in true },
                handler: { request in
                    let nextURL = "https://api.soundcloud.com/me/playlists?next=forever&limit=50&linked_partitioning=1"
                    return (200, self.playlistCollectionJSON(
                        playlists: [(1, "Repeating")],
                        nextHref: nextURL
                    ))
                }
            ),
        ])
        let client = try makeClient(http: http)

        let result = try await client.fetchPlaylists()

        // Must terminate and make at most 40 requests (the hard cap).
        let count = await http.requestCount()
        #expect(count <= 40)
        #expect(count >= 1)
        #expect(result.count >= 1)
    }

    @Test
    func fetchPlaylists_singlePageStillWorks() async throws {
        let http = RoutingHTTPClient([
            .init(
                matches: { _ in true },
                handler: { _ in
                    (200, self.playlistCollectionJSON(
                        playlists: [(7, "Solo")],
                        nextHref: nil
                    ))
                }
            ),
        ])
        let client = try makeClient(http: http)

        let result = try await client.fetchPlaylists()

        #expect(result.count == 1)
        #expect(result.first?.title == "Solo")
        #expect(await http.requestCount() == 1)
    }

    // MARK: - SoundCloudPlaylist.sharing / isPrivate

    @Test
    func playlist_decodesSharingAsPrivate() throws {
        let json = Data("""
        {
          "id": 1,
          "title": "Secret",
          "track_count": 0,
          "description": null,
          "permalink_url": null,
          "artwork_url": null,
          "tracks": [],
          "sharing": "private"
        }
        """.utf8)
        let playlist = try JSONDecoder().decode(SoundCloudPlaylist.self, from: json)
        #expect(playlist.isPrivate == true)
    }

    @Test
    func playlist_decodesSharingAsPublic() throws {
        let json = Data("""
        {
          "id": 1,
          "title": "Public",
          "track_count": 0,
          "description": null,
          "permalink_url": null,
          "artwork_url": null,
          "tracks": [],
          "sharing": "public"
        }
        """.utf8)
        let playlist = try JSONDecoder().decode(SoundCloudPlaylist.self, from: json)
        #expect(playlist.isPrivate == false)
    }

    @Test
    func playlist_missingSharingIsNotPrivate() throws {
        let json = Data("""
        {
          "id": 1,
          "title": "Legacy",
          "track_count": 0,
          "description": null,
          "permalink_url": null,
          "artwork_url": null,
          "tracks": []
        }
        """.utf8)
        let playlist = try JSONDecoder().decode(SoundCloudPlaylist.self, from: json)
        #expect(playlist.isPrivate == false)
    }

    // MARK: - resolvePlaylist

    @Test
    func resolvePlaylist_returnsPlaylistForSetsURL() async throws {
        let http = RoutingHTTPClient([
            .init(
                matches: { url in url.path.hasSuffix("/resolve") },
                handler: { _ in
                    let data = Data("""
                    {
                      "kind": "playlist",
                      "id": 42,
                      "title": "My Set",
                      "track_count": 3,
                      "permalink_url": "https://soundcloud.com/user/sets/my-set",
                      "tracks": []
                    }
                    """.utf8)
                    return (200, data)
                }
            ),
        ])
        let client = try makeClient(http: http)

        let playlist = try await client.resolvePlaylist(url: "https://soundcloud.com/user/sets/my-set")

        #expect(playlist.id == 42)
        #expect(playlist.title == "My Set")
        #expect(playlist.trackCount == 3)
    }

    @Test
    func resolvePlaylist_rejectsTrackURL() async throws {
        let http = RoutingHTTPClient([
            .init(
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
        let client = try makeClient(http: http)

        await #expect(throws: SoundCloudClient.SoundCloudError.self) {
            _ = try await client.resolvePlaylist(url: "https://soundcloud.com/user/some-track")
        }
    }

    @Test
    func resolvePlaylist_rejectsMissingId() async throws {
        let http = RoutingHTTPClient([
            .init(
                matches: { url in url.path.hasSuffix("/resolve") },
                handler: { _ in
                    let data = Data("""
                    {
                      "kind": "playlist",
                      "title": "No ID"
                    }
                    """.utf8)
                    return (200, data)
                }
            ),
        ])
        let client = try makeClient(http: http)

        await #expect(throws: SoundCloudClient.SoundCloudError.self) {
            _ = try await client.resolvePlaylist(url: "https://soundcloud.com/user/sets/no-id")
        }
    }

    @Test
    func resolvePlaylist_preservesSecretTokenQuery() async throws {
        let http = RoutingHTTPClient([
            .init(
                matches: { url in url.path.hasSuffix("/resolve") },
                handler: { request in
                    // Capture the outgoing request's `url` query-item value.
                    let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                    let passedURL = components.queryItems?.first(where: { $0.name == "url" })?.value ?? ""
                    // Stash it in a thread-local-ish via a global — we use a lock-protected box instead.
                    CaptureBox.shared.set(passedURL)
                    let data = Data("""
                    {
                      "kind": "playlist",
                      "id": 7,
                      "title": "Secret Set"
                    }
                    """.utf8)
                    return (200, data)
                }
            ),
        ])
        let client = try makeClient(http: http)

        _ = try await client.resolvePlaylist(url: "https://soundcloud.com/user/sets/private-set?si=abc123")

        let captured = CaptureBox.shared.get()
        #expect(captured?.contains("si=abc123") == true)
    }

    @Test
    func resolvePlaylist_addsMissingScheme() async throws {
        let http = RoutingHTTPClient([
            .init(
                matches: { url in url.path.hasSuffix("/resolve") },
                handler: { request in
                    let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                    let passedURL = components.queryItems?.first(where: { $0.name == "url" })?.value ?? ""
                    CaptureBox.shared.set(passedURL)
                    let data = Data("""
                    {
                      "kind": "playlist",
                      "id": 1,
                      "title": "T"
                    }
                    """.utf8)
                    return (200, data)
                }
            ),
        ])
        let client = try makeClient(http: http)

        _ = try await client.resolvePlaylist(url: "soundcloud.com/user/sets/my-set")

        let captured = CaptureBox.shared.get()
        #expect(captured?.hasPrefix("https://") == true)
    }

    @Test
    func resolvePlaylist_rejectsBlankInput() async throws {
        let http = RoutingHTTPClient([
            .init(
                matches: { _ in true },
                handler: { _ in (200, Data("{}".utf8)) }
            ),
        ])
        let client = try makeClient(http: http)

        await #expect(throws: SoundCloudClient.SoundCloudError.self) {
            _ = try await client.resolvePlaylist(url: "   ")
        }

        // No network request should have been issued for blank input.
        #expect(await http.requestCount() == 0)
    }

    @Test
    func resolvePlaylist_preservesSharingFromResolveResponse() async throws {
        let http = RoutingHTTPClient([
            .init(
                matches: { url in url.path.hasSuffix("/resolve") },
                handler: { _ in
                    let data = Data("""
                    {
                      "kind": "playlist",
                      "id": 42,
                      "title": "Secret Set",
                      "sharing": "private"
                    }
                    """.utf8)
                    return (200, data)
                }
            ),
        ])
        let client = try makeClient(http: http)

        let playlist = try await client.resolvePlaylist(url: "https://soundcloud.com/user/sets/secret?si=abc")
        #expect(playlist.isPrivate == true)
    }

    @Test
    func resolvePlaylist_publicSharingYieldsNotPrivate() async throws {
        let http = RoutingHTTPClient([
            .init(
                matches: { url in url.path.hasSuffix("/resolve") },
                handler: { _ in
                    let data = Data("""
                    {
                      "kind": "playlist",
                      "id": 42,
                      "title": "Public Set",
                      "sharing": "public"
                    }
                    """.utf8)
                    return (200, data)
                }
            ),
        ])
        let client = try makeClient(http: http)

        let playlist = try await client.resolvePlaylist(url: "https://soundcloud.com/user/sets/public")
        #expect(playlist.isPrivate == false)
    }
}

/// Tiny lock-protected box so a fake's closure can hand a captured value
/// back to the test without needing mutable actor state plumbing.
private final class CaptureBox: @unchecked Sendable {
    static let shared = CaptureBox()
    private let lock = NSLock()
    private var value: String?
    func set(_ v: String) { lock.lock(); defer { lock.unlock() }; value = v }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func reset() { lock.lock(); defer { lock.unlock() }; value = nil }
}
