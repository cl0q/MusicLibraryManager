import Foundation
import Testing
@testable import MLM

@Suite("SoundCloud refresh single-flight")
struct SoundCloudRefreshSingleFlightTests {
    private enum TestError: Error {
        case refreshFailed
    }

    // MARK: - Test doubles

    /// Returns 401 for requests with the old token, 200 for the new token.
    /// This is deterministic regardless of call timing or ordering.
    private actor TokenAwareHTTPClient: SoundCloudHTTPRequesting {
        private let successData: Data
        private let oldTokenPrefix: String

        init(successData: Data, oldTokenPrefix: String = "old-access") {
            self.successData = successData
            self.oldTokenPrefix = oldTokenPrefix
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let authHeader = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let hasOldToken = authHeader.contains(oldTokenPrefix)
            let statusCode = hasOldToken ? 401 : 200
            let data = hasOldToken ? Data() : successData
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, http)
        }
    }

    /// Counts refresh calls and returns a rotating refresh token each time.
    private actor CountingRefresher: SoundCloudTokenRefreshing {
        private var _callCount = 0
        private let rotatingTokens: [String]

        init(rotatingTokens: [String]) {
            self.rotatingTokens = rotatingTokens
        }

        func refresh(refreshToken: String) async throws -> OAuthManager.TokenResponse {
            _callCount += 1
            let idx = min(_callCount - 1, rotatingTokens.count - 1)
            return OAuthManager.TokenResponse(
                accessToken: "new-access-\(_callCount)",
                refreshToken: rotatingTokens[idx],
                expiresIn: 3600,
                tokenType: "bearer",
                scope: nil
            )
        }

        func callCount() -> Int { _callCount }
    }

    /// Refresh always throws.
    private actor FailingRefresher: SoundCloudTokenRefreshing {
        private var _callCount = 0

        func refresh(refreshToken: String) async throws -> OAuthManager.TokenResponse {
            _callCount += 1
            throw TestError.refreshFailed
        }

        func callCount() -> Int { _callCount }
    }

    private final class TokenStoreSpy: SoundCloudTokenStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var storedCredentials: TokenStorage.Credentials?
        private var _deletionCalls = 0

        init(accessToken: String = "old-access", refreshToken: String? = "initial-refresh") {
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
            _deletionCalls += 1
            storedCredentials = nil
        }

        var deletionCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return _deletionCalls
        }

        var storedRefreshToken: String? {
            lock.lock()
            defer { lock.unlock() }
            return storedCredentials?.refreshToken
        }
    }

    // MARK: - Helpers

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
        http: some SoundCloudHTTPRequesting,
        refresher: some SoundCloudTokenRefreshing
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

    // MARK: - Tests

    /// Two concurrent 401s must trigger exactly ONE network refresh.
    /// Before the single-flight fix both callers spend the same rotating
    /// refresh token and the second one fails.
    @Test
    func concurrent401sTriggerOnlyOneRefresh() async throws {
        let tokenStore = TokenStoreSpy()
        let http = TokenAwareHTTPClient(successData: Self.profileData)
        let refresher = CountingRefresher(rotatingTokens: ["rotated-refresh-1", "rotated-refresh-2"])
        let client = try makeClient(tokenStore: tokenStore, http: http, refresher: refresher)

        let work = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = try? await client.fetchProfile() }
                group.addTask { _ = try? await client.fetchProfile() }
            }
        }

        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            work.cancel()
        }

        await work.value
        watchdog.cancel()

        #expect(await refresher.callCount() == 1)
        #expect(tokenStore.storedRefreshToken == "rotated-refresh-1")
    }

    /// The second caller must succeed (not throw tokenExpired) even though
    /// it did NOT perform a network refresh.  This distinguishes
    /// single-flight-with-revalidation from a bare mutex.
    @Test
    func secondCallerSucceedsWithoutRefreshing() async throws {
        let tokenStore = TokenStoreSpy()
        let http = TokenAwareHTTPClient(successData: Self.profileData)
        let refresher = CountingRefresher(rotatingTokens: ["rotated-refresh-1"])
        let client = try makeClient(tokenStore: tokenStore, http: http, refresher: refresher)

        let work = Task {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    do { _ = try await client.fetchProfile(); return true }
                    catch { return false }
                }
                group.addTask {
                    do { _ = try await client.fetchProfile(); return true }
                    catch { return false }
                }
                var results: [Bool] = []
                for await r in group { results.append(r) }
                return results
            }
        }

        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            work.cancel()
        }

        let results = await work.value
        watchdog.cancel()

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0 })
        #expect(await refresher.callCount() == 1)
    }

    /// When refresh throws, credentials must NOT be deleted and
    /// tokenExpired must be thrown (existing invariant).
    @Test
    func refreshFailureDoesNotDeleteCredentials() async throws {
        let tokenStore = TokenStoreSpy()
        let http = TokenAwareHTTPClient(successData: Self.profileData)
        let refresher = FailingRefresher()
        let client = try makeClient(tokenStore: tokenStore, http: http, refresher: refresher)

        var receivedTokenExpired = false
        do {
            _ = try await client.fetchProfile()
        } catch SoundCloudClient.SoundCloudError.tokenExpired {
            receivedTokenExpired = true
        }

        #expect(receivedTokenExpired)
        #expect(tokenStore.deletionCalls == 0)
    }

    /// When the stored token equals the captured token (single caller,
    /// no concurrent refresh), a refresh MUST happen.
    @Test
    func unchangedTokenPathStillRefreshes() async throws {
        let tokenStore = TokenStoreSpy()
        let http = TokenAwareHTTPClient(successData: Self.profileData)
        let refresher = CountingRefresher(rotatingTokens: ["rotated-refresh-1"])
        let client = try makeClient(tokenStore: tokenStore, http: http, refresher: refresher)

        let profile = try await client.fetchProfile()

        #expect(profile.username == "tester")
        #expect(await refresher.callCount() == 1)
        #expect(tokenStore.storedRefreshToken == "rotated-refresh-1")
    }
}
