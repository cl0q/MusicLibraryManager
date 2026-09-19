import Foundation

/// Keychain-based secure token storage for OAuth credentials.
///
/// Shared by all source integrations (Spotify, SoundCloud, Apple Music).
/// Each service uses a unique `service` key to namespace its tokens.
///
/// Layout: ONE keychain item per service — account `token` holds a JSON blob
/// (access token, refresh token, expiry date). An in-memory cache keeps the
/// 60s background refresh loop from re-reading on every tick; negative
/// results (absent / inaccessible) are cached for a short TTL so a failing
/// service never spawns the helper in a tight loop.
///
/// ## Why the mlm-auth helper?
///
/// All keychain I/O is delegated to the `mlm-auth` helper binary (the ONLY
/// component in this package that imports Security), spawned via
/// Foundation.Process. The helper is signed with a stable self-signed
/// identity ("MLM Dev" — see scripts/setup-dev-signing.sh), so a single
/// keychain "Always Allow" consent survives app rebuilds; and its reads run
/// non-interactively (`kSecUseNoAuthenticationUI`), so a background read can
/// never trigger a password prompt — an item whose ACL does not match fails
/// fast with helper exit code 2 and surfaces here as a thrown
/// `KeychainError.itemInaccessible`. `getCredentials(service:interactive:)`
/// is the interactive variant for explicit user-initiated reconnects.
///
/// The legacy layout stored three items per service (accounts
/// `access_token` / `refresh_token` / `expiry_date`). On first access, when
/// the single item is absent, the helper's `migrate` command performs the
/// one-time conversion (read-all → write → verify → delete-legacy, inside
/// the helper) so no Security calls are needed in the app target.
///
/// ## Usage
/// ```swift
/// let storage = TokenStorage()
///
/// // Save tokens
/// try storage.saveTokens(
///     service: .spotify,
///     accessToken: "abc123",
///     refreshToken: "def456",
///     expiresIn: 3600
/// )
///
/// // Read tokens
/// if let cred = try storage.getCredentials(service: .spotify) {
///     print(cred.accessToken)
///     print(cred.isExpired)
/// }
///
/// // Delete tokens (disconnect)
/// try storage.deleteCredentials(service: .spotify)
/// ```
final class TokenStorage: @unchecked Sendable {

    // MARK: - Service identifiers

    /// OAuth service identifiers for Keychain namespacing.
    enum Service: String, CaseIterable, Sendable {
        case spotify = "com.mlm.oauth.spotify"
        case soundcloud = "com.mlm.oauth.soundcloud"
        case appleMusic = "com.mlm.oauth.applemusic"

        var displayName: String {
            switch self {
            case .spotify: "Spotify"
            case .soundcloud: "SoundCloud"
            case .appleMusic: "Apple Music"
            }
        }

        /// Name accepted by the mlm-auth helper CLI (raw value without the
        /// "com.mlm.oauth." prefix).
        var helperName: String {
            switch self {
            case .spotify: "spotify"
            case .soundcloud: "soundcloud"
            case .appleMusic: "applemusic"
            }
        }
    }

    // MARK: - Credential model

    /// OAuth credentials retrieved from the Keychain.
    struct Credentials: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiryDate: Date?

        /// Whether the access token has expired (with 60s buffer).
        var isExpired: Bool {
            guard let expiryDate else { return false }
            return Date().addingTimeInterval(60) >= expiryDate
        }

        /// Whether the access token needs refreshing soon (within 5 minutes).
        var needsRefresh: Bool {
            guard let expiryDate else { return false }
            return Date().addingTimeInterval(300) >= expiryDate
        }
    }

    // MARK: - Token blob (single-item format)

    /// JSON blob stored as the one keychain item per service.
    struct TokenBlob: Codable, Sendable, Equatable {
        var accessToken: String
        var refreshToken: String?
        /// ISO8601 expiry date string; nil when the provider gave no lifetime.
        var expiryDate: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiryDate = "expiry_date"
        }
    }

    /// Keychain account holding the single token blob per service.
    static let tokenAccount = "token"

    /// ISO8601 formatter for expiry dates — matches the legacy storage format.
    static let iso8601Formatter = ISO8601DateFormatter()

    // MARK: - Helper runner (delegation seam)

    /// Outcome of one mlm-auth helper invocation.
    struct AuthHelperOutcome: Sendable {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    /// Runs the mlm-auth helper. Seam so tests can map helper exit codes
    /// without spawning the real helper or touching the real keychain.
    protocol AuthHelperRunning: Sendable {
        func run(_ arguments: [String]) throws -> AuthHelperOutcome
    }

    /// Production runner — spawns the helper via Foundation.Process.
    struct ProcessAuthHelperRunner: AuthHelperRunning {
        let helperURL: URL

        func run(_ arguments: [String]) throws -> AuthHelperOutcome {
            let process = Process()
            process.executableURL = helperURL
            process.arguments = arguments
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            try process.run()
            let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return AuthHelperOutcome(
                exitCode: process.terminationStatus,
                stdout: stdout,
                stderr: stderr
            )
        }
    }

    /// Runner used when the helper binary cannot be located — every call
    /// fails with a typed error instead of silently corrupting state.
    private struct MissingHelperRunner: AuthHelperRunning {
        let reason: String

        func run(_ arguments: [String]) throws -> AuthHelperOutcome {
            throw KeychainError.helperUnavailable(reason)
        }
    }

    /// Helper binary name (the SPM product of the MLMAuthHelper target).
    static let helperExecutableName = "mlm-auth"

    /// Locate the mlm-auth helper:
    ///  1. as an auxiliary executable of the running bundle — run.sh
    ///     installs it into `Contents/MacOS/` of the .app bundle,
    ///  2. next to the running executable — SPM dev runs put MLM and
    ///     mlm-auth as siblings in `.build/<triple>/<config>/`,
    ///  3. in the SPM build dir — found by walking up from the executable's
    ///     directory looking for `.build/<triple>/<config>/mlm-auth`.
    static func resolveHelperURL() -> URL? { resolvedHelperURL }

    /// Resolved once per process — every `TokenStorage` init used to re-walk
    /// the filesystem, which spun and ballooned under concurrent test load.
    private static let resolvedHelperURL: URL? = computeHelperURL()

    private static func computeHelperURL() -> URL? {
        let name = helperExecutableName
        let fileManager = FileManager.default

        if let auxiliary = Bundle.main.url(forAuxiliaryExecutable: name),
           fileManager.isExecutableFile(atPath: auxiliary.path)
        {
            return auxiliary
        }
        guard let executableURL = Bundle.main.executableURL else {
            return nil
        }
        let executableDir = executableURL.deletingLastPathComponent()

        let sibling = executableDir.appendingPathComponent(name)
        if fileManager.isExecutableFile(atPath: sibling.path) {
            return sibling
        }

        var directory: URL? = executableDir
        var hops = 0
        while let current = directory {
            let buildRoot = current.appendingPathComponent(".build")
            if let buildDirs = try? fileManager.contentsOfDirectory(
                at: buildRoot,
                includingPropertiesForKeys: nil
            ) {
                for buildDir in buildDirs where buildDir.lastPathComponent.contains("apple-macosx") {
                    for configuration in ["debug", "release"] {
                        let candidate = buildDir
                            .appendingPathComponent(configuration)
                            .appendingPathComponent(name)
                        if fileManager.isExecutableFile(atPath: candidate.path) {
                            return candidate
                        }
                    }
                }
            }
            let parent = current.deletingLastPathComponent()
            hops += 1
            directory = (parent.path == current.path || hops > 16) ? nil : parent
        }
        return nil
    }

    /// mlm-auth exit codes (see the header comment in MLMAuthHelper/main.swift).
    private enum HelperExit {
        static let ok: Int32 = 0
        static let absent: Int32 = 1
        static let inaccessible: Int32 = 2
    }

    /// errSecAuthFailed — fallback when the helper's error JSON carries no
    /// status field (the constant lives in Security, which this target no
    /// longer imports, so it is spelled out here).
    private static let defaultInaccessibleStatus: OSStatus = -25308

    // MARK: - In-memory cache

    private enum CacheValue: Sendable {
        case credentials(Credentials)
        /// No single item and the legacy probe found nothing to migrate.
        case absent
        /// Item exists but requires user interaction to read (helper exit 2).
        case inaccessible(OSStatus)
    }

    private struct CacheEntry {
        let value: CacheValue
        let storedAt: Date
    }

    /// Positive results are re-verified periodically: a token can
    /// legitimately change (refresh in this process, another app instance),
    /// and a re-read costs one cheap helper spawn.
    static let credentialsTTL: TimeInterval = 300

    /// Negative results get a short TTL so a failing service never spawns
    /// the helper on every tick (the refresh loop also backs off on
    /// inaccessibility — see TokenRefreshService).
    static let negativeTTL: TimeInterval = 60

    private let lock = NSLock()
    private var cache: [Service: CacheEntry] = [:]
    /// Services whose legacy 3-item layout has already been probed this run.
    private var legacyProbed: Set<Service> = []

    private let runner: AuthHelperRunning

    init(runner: AuthHelperRunning? = nil) {
        if let runner {
            self.runner = runner
        } else if let helperURL = Self.resolveHelperURL() {
            self.runner = ProcessAuthHelperRunner(helperURL: helperURL)
        } else {
            let reason = "mlm-auth helper not found (checked the app bundle, the executable directory and the SPM build dir)"
            AppLogger.shared.error("Token storage unavailable: \(reason)", source: "TokenStorage")
            self.runner = MissingHelperRunner(reason: reason)
        }
    }

    // MARK: - Token Operations

    /// Save OAuth tokens to the Keychain (single blob item).
    ///
    /// - Parameters:
    ///   - service: The OAuth service (Spotify, SoundCloud, Apple Music).
    ///   - accessToken: The OAuth access token.
    ///   - refreshToken: The OAuth refresh token (optional for some flows).
    ///   - expiresIn: Token lifetime in seconds (used to compute expiry date).
    ///   - interactive: When true, the system may prompt for keychain access
    ///     (use only for explicit user-initiated connects).
    func saveTokens(
        service: Service,
        accessToken: String,
        refreshToken: String? = nil,
        expiresIn: Int? = nil
    ) throws {
        try saveTokens(
            service: service,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: expiresIn,
            interactive: false
        )
    }

    /// User-initiated save — the system may prompt once for keychain access
    /// (e.g. the first write after a rebuild changed the app's identity).
    func saveTokens(
        service: Service,
        accessToken: String,
        refreshToken: String?,
        expiresIn: Int?,
        interactive: Bool
    ) throws {
        let credentials = Credentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiryDate: expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
        try writeCredentials(service: service, credentials: credentials, interactive: interactive)
        store(.credentials(credentials), for: service)
        markLegacyProbed(service)
    }

    /// Update just the access token (after a refresh).
    ///
    /// - Parameters:
    ///   - service: The OAuth service.
    ///   - accessToken: The new access token.
    ///   - expiresIn: New token lifetime in seconds.
    func updateAccessToken(
        service: Service,
        accessToken: String,
        expiresIn: Int
    ) throws {
        // Preserve the refresh token from the current credentials.
        let current: Credentials?
        if let value = freshCacheValue(for: service), case .credentials(let credentials) = value {
            current = credentials
        } else {
            current = try getCredentials(service: service)
        }
        try saveTokens(
            service: service,
            accessToken: accessToken,
            refreshToken: current?.refreshToken,
            expiresIn: expiresIn
        )
    }

    /// Retrieve stored credentials for a service.
    ///
    /// Serves from the in-memory cache when possible; otherwise reads the
    /// single keychain item via the helper, non-interactively (never prompts).
    ///
    /// - Parameters:
    ///   - service: The OAuth service.
    ///   - interactive: When true, the system may prompt for keychain access
    ///     (use only for explicit user-initiated reconnects).
    /// - Returns: Credentials if found, nil if no tokens stored.
    /// - Throws: `KeychainError.itemInaccessible` when the item exists but
    ///   cannot be read without user interaction (distinct from "absent").
    func getCredentials(service: Service) throws -> Credentials? {
        try getCredentials(service: service, interactive: false)
    }

    /// Interactive variant — the system may prompt once for keychain access.
    /// Use only for explicit user-initiated reconnects.
    func getCredentials(service: Service, interactive: Bool) throws -> Credentials? {
        if let value = freshCacheValue(for: service) {
            if interactive {
                // An explicit user action deserves a fresh read — never
                // serve a stale absent/inaccessible result for it.
                switch value {
                case .credentials(let credentials):
                    return credentials
                case .absent, .inaccessible:
                    break
                }
            } else {
                switch value {
                case .credentials(let credentials):
                    return credentials
                case .absent:
                    return nil
                case .inaccessible(let status):
                    throw KeychainError.itemInaccessible(status: status)
                }
            }
        }

        let outcome = try runHelper(["get", service.helperName] + Self.interactiveFlag(interactive))
        return try handleGetOutcome(outcome, service: service, interactive: interactive)
    }

    /// Delete all stored credentials for a service.
    ///
    /// Used when the user disconnects a source. The helper removes the single
    /// blob item plus any leftover legacy items (best effort).
    /// - Parameter service: The OAuth service.
    func deleteCredentials(service: Service) throws {
        try runAndCheck(["delete", service.helperName], command: "delete", service: service)
        store(.absent, for: service)
        markLegacyProbed(service)
    }

    /// Check if credentials exist for a service (without reading them).
    ///
    /// Non-interactive; an item that exists but is not readable without user
    /// interaction still counts as present.
    func hasCredentials(service: Service) -> Bool {
        if let value = freshCacheValue(for: service) {
            switch value {
            case .credentials, .inaccessible:
                return true
            case .absent:
                return false
            }
        }

        guard let outcome = try? runHelper(["has", service.helperName]) else {
            return false
        }
        switch outcome.exitCode {
        case HelperExit.ok:
            // Present — readability is unknown to `has`, so nothing is
            // cached; `get` decides.
            return true
        case HelperExit.inaccessible:
            store(.inaccessible(Self.parseStatus(from: [outcome.stderr])), for: service)
            return true
        case HelperExit.absent:
            // Single item absent — probe the legacy layout once per process.
            guard !hasProbedLegacy(service) else {
                store(.absent, for: service)
                return false
            }
            markLegacyProbed(service)
            do {
                let result = try runMigrate(service: service, interactive: false)
                return result.migrated || !result.legacyAccounts.isEmpty
            } catch let error as KeychainError {
                if case .itemInaccessible(let status) = error {
                    store(.inaccessible(status), for: service)
                    return true
                }
                unmarkLegacyProbed(service)
                return false
            } catch {
                unmarkLegacyProbed(service)
                return false
            }
        default:
            return false
        }
    }

    /// Get all connected services.
    func connectedServices() -> [Service] {
        Service.allCases.filter { hasCredentials(service: $0) }
    }

    // MARK: - Blob encoding

    /// Encode a blob to JSON data.
    static func encodeBlob(_ blob: TokenBlob) throws -> Data {
        do {
            return try JSONEncoder().encode(blob)
        } catch {
            throw KeychainError.encodingFailed
        }
    }

    /// Decode blob JSON data; nil when the data is not a valid blob.
    static func decodeBlob(_ data: Data) -> TokenBlob? {
        try? JSONDecoder().decode(TokenBlob.self, from: data)
    }

    /// Build credentials from a blob (tolerates an unparseable expiry string).
    static func credentials(from blob: TokenBlob) -> Credentials {
        let expiryDate = blob.expiryDate.flatMap { iso8601Formatter.date(from: $0) }
        return Credentials(
            accessToken: blob.accessToken,
            refreshToken: blob.refreshToken,
            expiryDate: expiryDate
        )
    }

    // MARK: - Errors

    /// Errors from Keychain operations (via the mlm-auth helper).
    enum KeychainError: LocalizedError {
        case unhandledError(status: OSStatus)
        /// The item exists but requires user interaction to read or update
        /// (e.g. its ACL no longer matches the helper's signing identity).
        /// Distinct from "absent" (`errSecItemNotFound` / helper exit 1).
        case itemInaccessible(status: OSStatus)
        case encodingFailed
        case decodingFailed
        case migrationFailed
        /// The mlm-auth helper binary could not be located or executed.
        case helperUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .unhandledError(let status):
                return "Keychain/helper error (status \(status))"
            case .itemInaccessible(let status):
                return "Keychain item exists but is not accessible without user interaction (status \(status))"
            case .encodingFailed:
                return "Failed to encode data for Keychain"
            case .decodingFailed:
                return "Failed to decode stored token data"
            case .migrationFailed:
                return "Failed to migrate legacy keychain items"
            case .helperUnavailable(let reason):
                return "Token storage helper unavailable: \(reason)"
            }
        }
    }

    // MARK: - Helper delegation

    /// Run the helper, mapping spawn failures to a typed error.
    private func runHelper(_ arguments: [String]) throws -> AuthHelperOutcome {
        do {
            return try runner.run(arguments)
        } catch let error as KeychainError {
            throw error
        } catch {
            throw KeychainError.helperUnavailable(error.localizedDescription)
        }
    }

    @inline(__always)
    private static func interactiveFlag(_ interactive: Bool) -> [String] {
        interactive ? ["--interactive"] : []
    }

    /// Decode a non-empty token blob from helper stdout.
    private func parseBlob(from data: Data, service: Service) throws -> TokenBlob {
        guard let blob = Self.decodeBlob(data), !blob.accessToken.isEmpty else {
            AppLogger.shared.error(
                "\(service.displayName) stored token blob is unreadable — reconnect to restore it",
                source: "TokenStorage"
            )
            throw KeychainError.decodingFailed
        }
        return blob
    }

    /// Handle the outcome of `mlm-auth get`.
    private func handleGetOutcome(
        _ outcome: AuthHelperOutcome,
        service: Service,
        interactive: Bool
    ) throws -> Credentials? {
        switch outcome.exitCode {
        case HelperExit.ok:
            let blob = try parseBlob(from: outcome.stdout, service: service)
            let credentials = Self.credentials(from: blob)
            store(.credentials(credentials), for: service)
            return credentials

        case HelperExit.inaccessible:
            let status = Self.parseStatus(from: [outcome.stderr])
            store(.inaccessible(status), for: service)
            throw KeychainError.itemInaccessible(status: status)

        case HelperExit.absent:
            // Single item absent — probe the legacy 3-item layout once per
            // process (the helper performs the actual migration).
            guard !hasProbedLegacy(service) else {
                store(.absent, for: service)
                return nil
            }
            markLegacyProbed(service)
            do {
                let result = try runMigrate(service: service, interactive: interactive)
                if result.migrated {
                    // Re-read the single item the migration just wrote.
                    let reRead = try runHelper(["get", service.helperName] + Self.interactiveFlag(interactive))
                    return try handleGetOutcome(reRead, service: service, interactive: interactive)
                }
                store(.absent, for: service)
                return nil
            } catch {
                // Failed mid-migration — allow the next access to retry.
                unmarkLegacyProbed(service)
                throw error
            }

        default:
            AppLogger.shared.error(
                "mlm-auth 'get \(service.helperName)' failed with exit \(outcome.exitCode): \(Self.describe(outcome.stderr))",
                source: "TokenStorage"
            )
            throw KeychainError.unhandledError(status: outcome.exitCode)
        }
    }

    /// Result of `mlm-auth migrate` (always a JSON object on stdout).
    private struct MigrateResult {
        let migrated: Bool
        /// Legacy accounts the helper saw present.
        let legacyAccounts: Set<String>
    }

    private static func parseMigrateResult(from data: Data) -> MigrateResult? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let migrated = json["migrated"] as? Bool ?? false
        let accounts = (json["accounts"] as? [String]) ?? []
        return MigrateResult(migrated: migrated, legacyAccounts: Set(accounts))
    }

    /// Run the helper's one-time legacy migration.
    /// - Returns: The parsed migration result.
    /// - Throws: `KeychainError.itemInaccessible` when legacy items exist but
    ///   cannot be read without user interaction; `migrationFailed` otherwise.
    private func runMigrate(service: Service, interactive: Bool) throws -> MigrateResult {
        let outcome = try runHelper(["migrate", service.helperName] + Self.interactiveFlag(interactive))
        switch outcome.exitCode {
        case HelperExit.ok:
            guard let result = Self.parseMigrateResult(from: outcome.stdout) else {
                throw KeychainError.migrationFailed
            }
            return result
        case HelperExit.inaccessible:
            throw KeychainError.itemInaccessible(status: Self.parseStatus(from: [outcome.stdout, outcome.stderr]))
        default:
            AppLogger.shared.error(
                "mlm-auth 'migrate \(service.helperName)' failed with exit \(outcome.exitCode): \(Self.describe(outcome.stdout))",
                source: "TokenStorage"
            )
            throw KeychainError.migrationFailed
        }
    }

    /// Shared success/inaccessible/other mapping for mutating helper
    /// commands (`set` / `delete`).
    private func runAndCheck(_ arguments: [String], command: String, service: Service) throws {
        let outcome = try runHelper(arguments)
        switch outcome.exitCode {
        case HelperExit.ok:
            return
        case HelperExit.inaccessible:
            throw KeychainError.itemInaccessible(status: Self.parseStatus(from: [outcome.stderr]))
        default:
            AppLogger.shared.error(
                "mlm-auth '\(command) \(service.helperName)' failed with exit \(outcome.exitCode): \(Self.describe(outcome.stderr))",
                source: "TokenStorage"
            )
            throw KeychainError.unhandledError(status: outcome.exitCode)
        }
    }

    /// Write the credentials blob via `mlm-auth set`.
    private func writeCredentials(service: Service, credentials: Credentials, interactive: Bool) throws {
        let blob = TokenBlob(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            expiryDate: credentials.expiryDate.map { Self.iso8601Formatter.string(from: $0) }
        )
        let data = try Self.encodeBlob(blob)
        guard let json = String(data: data, encoding: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try runAndCheck(
            ["set", service.helperName, json] + Self.interactiveFlag(interactive),
            command: "set",
            service: service
        )
    }

    /// The helper reports the keychain OSStatus in its error JSON
    /// ({"error": ..., "status": N}); fall back to errSecAuthFailed.
    private static func parseStatus(from candidates: [Data]) -> OSStatus {
        for data in candidates {
            if
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let raw = json["status"] as? Int
            {
                return OSStatus(raw)
            }
        }
        return defaultInaccessibleStatus
    }

    private static func describe(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return "<no output>"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cache accessors

    /// The still-fresh cached value for a service (TTL-checked).
    private func freshCacheValue(for service: Service) -> CacheValue? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[service] else {
            return nil
        }
        let ttl: TimeInterval
        switch entry.value {
        case .credentials:
            ttl = Self.credentialsTTL
        case .absent, .inaccessible:
            ttl = Self.negativeTTL
        }
        return Date().timeIntervalSince(entry.storedAt) < ttl ? entry.value : nil
    }

    private func store(_ value: CacheValue, for service: Service) {
        lock.lock()
        defer { lock.unlock() }
        cache[service] = CacheEntry(value: value, storedAt: Date())
    }

    private func hasProbedLegacy(_ service: Service) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return legacyProbed.contains(service)
    }

    private func markLegacyProbed(_ service: Service) {
        lock.lock()
        defer { lock.unlock() }
        legacyProbed.insert(service)
    }

    private func unmarkLegacyProbed(_ service: Service) {
        lock.lock()
        defer { lock.unlock() }
        legacyProbed.remove(service)
    }
}
