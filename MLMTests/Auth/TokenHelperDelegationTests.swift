import Foundation
import Testing
@testable import MLM

/// Fake mlm-auth runner: records invocations and replays scripted outcomes.
/// Never spawns a process or touches the keychain.
private final class FakeHelperRunner: TokenStorage.AuthHelperRunning, @unchecked Sendable {
    struct Outcome {
        var exitCode: Int32
        var stdout: Data = Data()
        var stderr: Data = Data()
    }

    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var queue: [Outcome]

    /// Returned once the scripted outcomes are exhausted (fail loudly).
    private let fallback: Outcome

    init(scripts: [Outcome], fallback: Outcome? = nil) {
        self.queue = scripts
        self.fallback = fallback ?? Outcome(exitCode: 3, stderr: Data("unexpected helper call".utf8))
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func run(_ arguments: [String]) throws -> TokenStorage.AuthHelperOutcome {
        lock.lock()
        _calls.append(arguments)
        let next = queue.isEmpty ? fallback : queue.removeFirst()
        lock.unlock()
        return TokenStorage.AuthHelperOutcome(
            exitCode: next.exitCode,
            stdout: next.stdout,
            stderr: next.stderr
        )
    }
}

@Suite("TokenStorage → mlm-auth delegation (exit-code mapping)")
struct TokenHelperDelegationTests {

    private static let blobJSON = """
    {"access_token":"tok-123","refresh_token":"ref-456","expiry_date":"2031-01-01T00:00:00Z"}
    """

    private static func utf8(_ string: String) -> Data {
        Data(string.utf8)
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    @Test func getExit0ReturnsCredentialsAndCaches() throws {
        let runner = FakeHelperRunner(scripts: [
            .init(exitCode: 0, stdout: Self.utf8(Self.blobJSON)),
        ])
        let storage = TokenStorage(runner: runner)

        let credentials = try storage.getCredentials(service: .soundcloud)
        #expect(credentials?.accessToken == "tok-123")
        #expect(credentials?.refreshToken == "ref-456")
        #expect(credentials?.expiryDate != nil)
        #expect(runner.calls == [["get", "soundcloud"]])

        // Second read is served from the in-memory cache — no new spawn.
        _ = try storage.getCredentials(service: .soundcloud)
        #expect(runner.calls.count == 1)
    }

    @Test func getExit2MapsToItemInaccessibleAndCachesNegative() throws {
        let runner = FakeHelperRunner(scripts: [
            .init(exitCode: 2, stderr: Self.json(["error": "denied", "status": -25308])),
        ])
        let storage = TokenStorage(runner: runner)

        do {
            _ = try storage.getCredentials(service: .spotify)
            #expect(false, "expected itemInaccessible")
        } catch TokenStorage.KeychainError.itemInaccessible(let status) {
            #expect(status == -25308)
        }

        // Second read within the negative TTL comes from the cache (no spawn),
        // and still reports inaccessibility.
        do {
            _ = try storage.getCredentials(service: .spotify)
            #expect(false, "expected itemInaccessible")
        } catch TokenStorage.KeychainError.itemInaccessible {
            // expected
        }
        #expect(runner.calls.count == 1)
    }

    @Test func getExit2WithoutStatusFallsBackToAuthFailed() throws {
        let runner = FakeHelperRunner(scripts: [
            .init(exitCode: 2, stderr: Self.json(["error": "denied"])),
        ])
        let storage = TokenStorage(runner: runner)

        do {
            _ = try storage.getCredentials(service: .spotify)
            #expect(false, "expected itemInaccessible")
        } catch TokenStorage.KeychainError.itemInaccessible(let status) {
            // errSecAuthFailed fallback.
            #expect(status == -25308)
        }
    }

    @Test func getAbsentWithNoLegacyReturnsNilAndStopsProbing() throws {
        let runner = FakeHelperRunner(scripts: [
            .init(exitCode: 1),
            .init(exitCode: 0, stdout: Self.json(["migrated": false, "reason": "no-legacy-items", "accounts": []])),
        ])
        let storage = TokenStorage(runner: runner)

        #expect(try storage.getCredentials(service: .appleMusic) == nil)

        // Legacy layout was probed this process — the second read is served
        // from the cached "absent" result without spawning the helper.
        #expect(try storage.getCredentials(service: .appleMusic) == nil)
        #expect(runner.calls.count == 2)
        #expect(runner.calls.map { $0.first } == ["get", "migrate"])
    }

    @Test func getAbsentMigratesLegacyThenReturnsCredentials() throws {
        let runner = FakeHelperRunner(scripts: [
            .init(exitCode: 1),
            .init(exitCode: 0, stdout: Self.json(["migrated": true, "accounts": ["access_token", "refresh_token"]])),
            .init(exitCode: 0, stdout: Self.utf8(Self.blobJSON)),
        ])
        let storage = TokenStorage(runner: runner)

        let credentials = try storage.getCredentials(service: .soundcloud)
        #expect(credentials?.accessToken == "tok-123")
        #expect(runner.calls.map { $0.first } == ["get", "migrate", "get"])
    }

    @Test func migrateExit2SurfacesItemInaccessible() throws {
        let runner = FakeHelperRunner(scripts: [
            .init(exitCode: 1),
            .init(exitCode: 2, stdout: Self.json(["migrated": false, "reason": "inaccessible", "accounts": ["access_token"], "status": -25323])),
        ])
        let storage = TokenStorage(runner: runner)

        do {
            _ = try storage.getCredentials(service: .soundcloud)
            #expect(false, "expected itemInaccessible")
        } catch TokenStorage.KeychainError.itemInaccessible(let status) {
            #expect(status == -25323)
        }

        // A failed migration may be retried on the next access.
        _ = runner.calls
    }

    @Test func saveExit0StoresCredentialsInCache() throws {
        let runner = FakeHelperRunner(scripts: [
            .init(exitCode: 0),
        ])
        let storage = TokenStorage(runner: runner)

        try storage.saveTokens(service: .soundcloud, accessToken: "a", refreshToken: "r", expiresIn: 3600)

        let setCall = try #require(runner.calls.first)
        #expect(setCall[0] == "set")
        #expect(setCall[1] == "soundcloud")
        let payload = try #require(JSONSerialization.jsonObject(with: Data(setCall[2].utf8)) as? [String: Any])
        #expect(payload["access_token"] as? String == "a")
        #expect(payload["refresh_token"] as? String == "r")

        // Cached — a subsequent read does not spawn the helper.
        let credentials = try storage.getCredentials(service: .soundcloud)
        #expect(credentials?.accessToken == "a")
        #expect(credentials?.refreshToken == "r")
        #expect(runner.calls.count == 1)
    }

    @Test func saveExit2MapsToItemInaccessible() throws {
        let runner = FakeHelperRunner(scripts: [
            .init(exitCode: 2, stderr: Self.json(["error": "denied", "status": -25323])),
        ])
        let storage = TokenStorage(runner: runner)

        do {
            try storage.saveTokens(service: .spotify, accessToken: "a", refreshToken: nil, expiresIn: nil)
            #expect(false, "expected itemInaccessible")
        } catch TokenStorage.KeychainError.itemInaccessible(let status) {
            #expect(status == -25323)
        }
    }

    @Test func deleteExit0ClearsPresence() throws {
        let runner = FakeHelperRunner(scripts: [
            .init(exitCode: 0),  // set
            .init(exitCode: 0),  // delete
        ])
        let storage = TokenStorage(runner: runner)

        try storage.saveTokens(service: .soundcloud, accessToken: "a", refreshToken: nil, expiresIn: nil)
        try storage.deleteCredentials(service: .soundcloud)

        // The cached "absent" result answers hasCredentials without a spawn.
        #expect(storage.hasCredentials(service: .soundcloud) == false)
        #expect(runner.calls.map { $0.first } == ["set", "delete"])
    }

    @Test func hasExit0ReportsPresent() throws {
        let runner = FakeHelperRunner(scripts: [
            .init(exitCode: 0),
        ])
        let storage = TokenStorage(runner: runner)

        #expect(storage.hasCredentials(service: .soundcloud) == true)
        #expect(runner.calls == [["has", "soundcloud"]])
    }

    @Test func hasExit2ReportsPresentButInaccessible() throws {
        let runner = FakeHelperRunner(scripts: [
            .init(exitCode: 2, stderr: Self.json(["error": "denied", "status": -25308])),
        ])
        let storage = TokenStorage(runner: runner)

        #expect(storage.hasCredentials(service: .soundcloud) == true)
    }

    @Test func missingHelperThrowsTypedError() throws {
        struct ThrowingRunner: TokenStorage.AuthHelperRunning {
            func run(_ arguments: [String]) throws -> TokenStorage.AuthHelperOutcome {
                throw TokenStorage.KeychainError.helperUnavailable("no helper here")
            }
        }
        let storage = TokenStorage(runner: ThrowingRunner())

        do {
            _ = try storage.getCredentials(service: .spotify)
            #expect(false, "expected helperUnavailable")
        } catch TokenStorage.KeychainError.helperUnavailable {
            // expected
        }
        #expect(storage.hasCredentials(service: .spotify) == false)
    }
}
