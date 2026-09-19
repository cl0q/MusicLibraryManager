import Foundation
import Testing
@testable import MLM

@Suite("SoundCloudClient authentication")
struct SoundCloudClientTests {
    private enum TestError: Error {
        case refreshFailed
    }

    private actor ScriptedHTTPClient: SoundCloudHTTPRequesting {
        struct Response: Sendable {
            let statusCode: Int
            let data: Data
        }

        private var responses: [Response]
        private var requests: [URLRequest] = []

        init(_ responses: [Response]) {
            self.responses = responses
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let response = responses.removeFirst()
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response.data, http)
        }

        func requestCount() -> Int {
            requests.count
        }
    }

    private actor ScriptedRefresher: SoundCloudTokenRefreshing {
        private let response: OAuthManager.TokenResponse?
        private let error: Error?
        private var calls = 0

        init(response: OAuthManager.TokenResponse) {
            self.response = response
            self.error = nil
        }

        init(error: Error) {
            self.response = nil
            self.error = error
        }

        func refresh(refreshToken: String) async throws -> OAuthManager.TokenResponse {
            calls += 1
            if let error {
                throw error
            }
            return response!
        }

        func callCount() -> Int {
            calls
        }
    }

    private final class TokenStoreSpy: SoundCloudTokenStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var storedCredentials: TokenStorage.Credentials?
        private var deletionCalls = 0

        init(accessToken: String = "old-access", refreshToken: String? = "refresh-token") {
            storedCredentials = TokenStorage.Credentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiryDate: nil
            )
        }

        func getCredentials(service: TokenStorage.Service) throws -> TokenStorage.Credentials? {
            lock.lock()
            defer { lock.unlock() }
            return storedCredentials
        }

        func saveTokens(
            service: TokenStorage.Service,
            accessToken: String,
            refreshToken: String?,
            expiresIn: Int?
        ) throws {
            lock.lock()
            defer { lock.unlock() }
            storedCredentials = TokenStorage.Credentials(
                accessToken: accessToken,
                refreshToken: refreshToken ?? storedCredentials?.refreshToken,
                expiryDate: expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
            )
        }

        func updateAccessToken(
            service: TokenStorage.Service,
            accessToken: String,
            expiresIn: Int
        ) throws {
            lock.lock()
            defer { lock.unlock() }
            storedCredentials = TokenStorage.Credentials(
                accessToken: accessToken,
                refreshToken: storedCredentials?.refreshToken,
                expiryDate: Date().addingTimeInterval(TimeInterval(expiresIn))
            )
        }

        func deleteCredentials(service: TokenStorage.Service) throws {
            lock.lock()
            defer { lock.unlock() }
            deletionCalls += 1
            storedCredentials = nil
        }

        func snapshot() -> (accessToken: String?, deletionCalls: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (storedCredentials?.accessToken, deletionCalls)
        }
    }

    private static let profileData = Data(
        """
        {
          "id": 42,
          "username": "tester",
          "avatar_url": null,
          "full_name": null,
          "permalink": "tester"
        }
        """.utf8
    )

    private static func likesData(artworkURL: String?) -> Data {
        let artworkValue = artworkURL.map { "\"\($0)\"" } ?? "null"
        return Data(
            """
            {
              "collection": [
                {
                  "id": 9001,
                  "title": "Cover Test",
                  "duration": 180000,
                  "genre": "Electronic",
                  "permalink_url": "https://soundcloud.com/tester/cover-test",
                  "stream_url": null,
                  "artwork_url": \(artworkValue),
                  "created_at": "2026/07/21 08:00:00 +0000",
                  "user": {
                    "id": 42,
                    "username": "tester",
                    "avatar_url": null,
                    "full_name": null,
                    "permalink": "tester"
                  }
                }
              ],
              "next_href": null
            }
            """.utf8
        )
    }

    private func makeClient(
        tokenStore: TokenStoreSpy,
        http: ScriptedHTTPClient,
        refresher: ScriptedRefresher
    ) throws -> SoundCloudClient {
        let database = try DatabaseManager.inMemory()
        return SoundCloudClient(
            tokenStorage: tokenStore,
            oauthManager: OAuthManager(),
            trackRepository: TrackRepository(database: database),
            sourceRepository: SourceRepository(database: database),
            clientId: "client-id",
            clientSecret: "client-secret",
            http: http,
            refresher: refresher
        )
    }

    @Test
    func transient401RefreshesOnceAndRetriesOnce() async throws {
        let tokenStore = TokenStoreSpy()
        let http = ScriptedHTTPClient([
            .init(statusCode: 401, data: Data()),
            .init(statusCode: 200, data: Self.profileData),
        ])
        let refresher = ScriptedRefresher(
            response: OAuthManager.TokenResponse(
                accessToken: "new-access",
                refreshToken: "new-refresh",
                expiresIn: 3600,
                tokenType: "bearer",
                scope: nil
            )
        )
        let client = try makeClient(tokenStore: tokenStore, http: http, refresher: refresher)

        let profile = try await client.fetchProfile()

        #expect(profile.username == "tester")
        #expect(await http.requestCount() == 2)
        #expect(await refresher.callCount() == 1)
        let snapshot = tokenStore.snapshot()
        #expect(snapshot.accessToken == "new-access")
        #expect(snapshot.deletionCalls == 0)
    }

    @Test
    func refreshFailureKeepsStoredCredentials() async throws {
        let tokenStore = TokenStoreSpy()
        let http = ScriptedHTTPClient([.init(statusCode: 401, data: Data())])
        let refresher = ScriptedRefresher(error: TestError.refreshFailed)
        let client = try makeClient(tokenStore: tokenStore, http: http, refresher: refresher)

        var receivedTokenExpired = false
        do {
            _ = try await client.fetchProfile()
        } catch SoundCloudClient.SoundCloudError.tokenExpired {
            receivedTokenExpired = true
        }

        #expect(receivedTokenExpired)
        #expect(await http.requestCount() == 1)
        #expect(await refresher.callCount() == 1)
        #expect(tokenStore.snapshot().deletionCalls == 0)
    }

    @Test
    func second401DoesNotRefreshAgainOrDeleteCredentials() async throws {
        let tokenStore = TokenStoreSpy()
        let http = ScriptedHTTPClient([
            .init(statusCode: 401, data: Data()),
            .init(statusCode: 401, data: Data()),
        ])
        let refresher = ScriptedRefresher(
            response: OAuthManager.TokenResponse(
                accessToken: "new-access",
                refreshToken: nil,
                expiresIn: 3600,
                tokenType: "bearer",
                scope: nil
            )
        )
        let client = try makeClient(tokenStore: tokenStore, http: http, refresher: refresher)

        var receivedTokenExpired = false
        do {
            _ = try await client.fetchProfile()
        } catch SoundCloudClient.SoundCloudError.tokenExpired {
            receivedTokenExpired = true
        }

        #expect(receivedTokenExpired)
        #expect(await http.requestCount() == 2)
        #expect(await refresher.callCount() == 1)
        #expect(tokenStore.snapshot().deletionCalls == 0)
    }

    @Test
    func successfulFirstRequestDoesNotRefreshOrRetry() async throws {
        let tokenStore = TokenStoreSpy()
        let http = ScriptedHTTPClient([.init(statusCode: 200, data: Self.profileData)])
        let refresher = ScriptedRefresher(error: TestError.refreshFailed)
        let client = try makeClient(tokenStore: tokenStore, http: http, refresher: refresher)

        _ = try await client.fetchProfile()

        #expect(await http.requestCount() == 1)
        #expect(await refresher.callCount() == 0)
        #expect(tokenStore.snapshot().deletionCalls == 0)
    }

    @Test
    func syncLikesRetainsSoundCloudArtworkURL() async throws {
        let database = try DatabaseManager.inMemory()
        let tokenStore = TokenStoreSpy()
        let expectedURL = "https://i1.sndcdn.com/artworks-cover-large.jpg"
        let http = ScriptedHTTPClient([
            .init(statusCode: 200, data: Self.profileData),
            .init(statusCode: 200, data: Self.likesData(artworkURL: expectedURL)),
        ])
        let client = SoundCloudClient(
            tokenStorage: tokenStore,
            oauthManager: OAuthManager(),
            trackRepository: TrackRepository(database: database),
            sourceRepository: SourceRepository(database: database),
            clientId: "client-id",
            clientSecret: "client-secret",
            http: http,
            refresher: ScriptedRefresher(error: TestError.refreshFailed)
        )

        _ = try await client.syncLikes()

        let trackId = try await database.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE title = 'Cover Test'")!
        }
        let retainedURL = try await AnalysisRepository(database: database)
            .remoteArtworkURL(trackId: trackId)
        #expect(retainedURL == expectedURL)
    }

    @Test
    func syncLikesDoesNotCreateArtworkRowForMissingURL() async throws {
        let database = try DatabaseManager.inMemory()
        let tokenStore = TokenStoreSpy()
        let http = ScriptedHTTPClient([
            .init(statusCode: 200, data: Self.profileData),
            .init(statusCode: 200, data: Self.likesData(artworkURL: nil)),
        ])
        let client = SoundCloudClient(
            tokenStorage: tokenStore,
            oauthManager: OAuthManager(),
            trackRepository: TrackRepository(database: database),
            sourceRepository: SourceRepository(database: database),
            clientId: "client-id",
            clientSecret: "client-secret",
            http: http,
            refresher: ScriptedRefresher(error: TestError.refreshFailed)
        )

        _ = try await client.syncLikes()

        let artworkRows = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artwork")
        }
        #expect(artworkRows == 0)
    }
}

@Suite("SoundCloudTrack DRM / downloadability")
struct SoundCloudTrackDRMTests {

    // MARK: - Helpers

    private func trackJSON(
        monetizationModel: String? = nil,
        policy: String? = nil,
        downloadable: Bool? = nil,
        includeFields: Bool = true
    ) -> String {
        var fields: [String] = [
            "\"id\": 1",
            "\"title\": \"Test Track\"",
            "\"permalink_url\": \"https://soundcloud.com/test/test-track\"",
        ]
        if includeFields {
            if let v = monetizationModel {
                fields.append("\"monetization_model\": \"\(v)\"")
            } else {
                fields.append("\"monetization_model\": null")
            }
            if let v = policy {
                fields.append("\"policy\": \"\(v)\"")
            } else {
                fields.append("\"policy\": null")
            }
            if let v = downloadable {
                fields.append("\"downloadable\": \(v)")
            } else {
                fields.append("\"downloadable\": null")
            }
        }
        return "{ \(fields.joined(separator: ", ")) }"
    }

    private func decodeTrack(_ json: String) throws -> SoundCloudTrack {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(SoundCloudTrack.self, from: data)
    }

    // MARK: - Decoding

    @Test
    func decodesMonetizationModelPolicyAndDownloadable() throws {
        let json = trackJSON(
            monetizationModel: "SUB_HIGH_TIER",
            policy: "BLOCK",
            downloadable: false
        )
        let track = try decodeTrack(json)
        #expect(track.monetizationModel == "SUB_HIGH_TIER")
        #expect(track.policy == "BLOCK")
        #expect(track.downloadable == false)
    }

    @Test
    func decodesWhenFieldsAbsent() throws {
        // Minimal payload with no DRM fields at all — must still decode.
        let json = """
        {
          "id": 2,
          "title": "Plain Track",
          "permalink_url": "https://soundcloud.com/x/y"
        }
        """
        let track = try decodeTrack(json)
        #expect(track.monetizationModel == nil)
        #expect(track.policy == nil)
        #expect(track.downloadable == nil)
    }

    @Test
    func decodesWhenFieldsPresentButNull() throws {
        let json = trackJSON(monetizationModel: nil, policy: nil, downloadable: nil, includeFields: true)
        let track = try decodeTrack(json)
        #expect(track.monetizationModel == nil)
        #expect(track.policy == nil)
        #expect(track.downloadable == nil)
    }

    @Test
    func decodesUnknownMonetizationModelWithoutCrashing() throws {
        let json = trackJSON(
            monetizationModel: "FUTURE_PREMIUM_TIER_XYZ",
            policy: "ALLOW",
            downloadable: true
        )
        let track = try decodeTrack(json)
        #expect(track.monetizationModel == "FUTURE_PREMIUM_TIER_XYZ")
        #expect(track.policy == "ALLOW")
        #expect(track.downloadable == true)
    }

    @Test
    func decodesUnknownPolicyWithoutCrashing() throws {
        let json = trackJSON(
            monetizationModel: "AD_SUPPORTED",
            policy: "SOME_NEW_POLICY",
            downloadable: nil
        )
        let track = try decodeTrack(json)
        #expect(track.policy == "SOME_NEW_POLICY")
    }

    // MARK: - isDownloadBlocked

    @Test
    func subHighTierWithBlockPolicyIsBlocked() throws {
        let json = trackJSON(
            monetizationModel: "SUB_HIGH_TIER",
            policy: "BLOCK",
            downloadable: false
        )
        let track = try decodeTrack(json)
        #expect(track.isDownloadBlocked == true)
    }

    @Test
    func subLowTierWithSnipPolicyIsBlocked() throws {
        let json = trackJSON(
            monetizationModel: "SUB_LOW_TIER",
            policy: "SNIP",
            downloadable: false
        )
        let track = try decodeTrack(json)
        #expect(track.isDownloadBlocked == true)
    }

    @Test
    func adSupportedWithAllowPolicyIsNotBlocked() throws {
        let json = trackJSON(
            monetizationModel: "AD_SUPPORTED",
            policy: "ALLOW",
            downloadable: true
        )
        let track = try decodeTrack(json)
        #expect(track.isDownloadBlocked == false)
    }

    @Test
    func allNilFieldsIsNotBlocked() throws {
        let json = """
        {
          "id": 3,
          "title": "Normal Track",
          "permalink_url": "https://soundcloud.com/x/y"
        }
        """
        let track = try decodeTrack(json)
        #expect(track.isDownloadBlocked == false)
    }

    @Test
    func nullFieldsIsNotBlocked() throws {
        let json = trackJSON(monetizationModel: nil, policy: nil, downloadable: nil, includeFields: true)
        let track = try decodeTrack(json)
        #expect(track.isDownloadBlocked == false)
    }

    @Test
    func unknownMonetizationModelIsNotBlocked() throws {
        // Conservative: unknown monetization_model must NOT be treated as blocked.
        let json = trackJSON(
            monetizationModel: "BRAND_NEW_TIER",
            policy: nil,
            downloadable: nil
        )
        let track = try decodeTrack(json)
        #expect(track.isDownloadBlocked == false)
    }

    @Test
    func unknownPolicyIsNotBlocked() throws {
        // Conservative: unknown policy must NOT be treated as blocked.
        let json = trackJSON(
            monetizationModel: nil,
            policy: "FUTURE_POLICY",
            downloadable: nil
        )
        let track = try decodeTrack(json)
        #expect(track.isDownloadBlocked == false)
    }

    @Test
    func downloadableFalseAloneIsNotBlocked() throws {
        // downloadable: false without a blocking policy/monetization_model
        // is ambiguous — be conservative and do NOT report as blocked.
        let json = trackJSON(
            monetizationModel: nil,
            policy: nil,
            downloadable: false
        )
        let track = try decodeTrack(json)
        #expect(track.isDownloadBlocked == false)
    }

    // MARK: - Round-trip

    @Test
    func roundTripPreservesNewFields() throws {
        let json = trackJSON(
            monetizationModel: "SUB_HIGH_TIER",
            policy: "BLOCK",
            downloadable: false
        )
        let original = try decodeTrack(json)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SoundCloudTrack.self, from: encoded)
        #expect(decoded.monetizationModel == "SUB_HIGH_TIER")
        #expect(decoded.policy == "BLOCK")
        #expect(decoded.downloadable == false)
    }

    // MARK: - Full realistic payload

    @Test
    func fullRealisticPayloadDecodesAllPreExistingFields() throws {
        let json = """
        {
          "id": 424242,
          "title": "Full Track",
          "duration": 240000,
          "genre": "Electronic",
          "permalink_url": "https://soundcloud.com/artist/full-track",
          "stream_url": "https://api.soundcloud.com/stream/424242",
          "artwork_url": "https://i1.sndcdn.com/artworks-full.jpg",
          "created_at": "2026/01/01 12:00:00 +0000",
          "user": {
            "id": 7,
            "username": "artist",
            "avatar_url": "https://i1.sndcdn.com/avatars.jpg",
            "full_name": "The Artist",
            "permalink": "artist"
          },
          "monetization_model": "AD_SUPPORTED",
          "policy": "ALLOW",
          "downloadable": true
        }
        """
        let track = try decodeTrack(json)
        #expect(track.id == 424242)
        #expect(track.title == "Full Track")
        #expect(track.duration == 240000)
        #expect(track.genre == "Electronic")
        #expect(track.permalinkUrl == "https://soundcloud.com/artist/full-track")
        #expect(track.streamUrl == "https://api.soundcloud.com/stream/424242")
        #expect(track.artworkUrl == "https://i1.sndcdn.com/artworks-full.jpg")
        #expect(track.createdAt == "2026/01/01 12:00:00 +0000")
        #expect(track.user?.username == "artist")
        #expect(track.monetizationModel == "AD_SUPPORTED")
        #expect(track.policy == "ALLOW")
        #expect(track.downloadable == true)
        #expect(track.isDownloadBlocked == false)
    }
}
