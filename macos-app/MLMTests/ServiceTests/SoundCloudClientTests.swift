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
}
