import Foundation
import Security

/// Keychain-based secure token storage for OAuth credentials.
///
/// Shared by all source integrations (Spotify, SoundCloud, Apple Music).
/// Each service uses a unique `service` key to namespace its tokens.
///
/// Stores:
/// - Access token
/// - Refresh token
/// - Token expiry date
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
final class TokenStorage: Sendable {

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

    // MARK: - Keychain account keys

    private enum AccountKey {
        static let accessToken = "access_token"
        static let refreshToken = "refresh_token"
        static let expiryDate = "expiry_date"
    }

    // MARK: - Token Operations

    /// Save OAuth tokens to the Keychain.
    ///
    /// - Parameters:
    ///   - service: The OAuth service (Spotify, SoundCloud, Apple Music).
    ///   - accessToken: The OAuth access token.
    ///   - refreshToken: The OAuth refresh token (optional for some flows).
    ///   - expiresIn: Token lifetime in seconds (used to compute expiry date).
    func saveTokens(
        service: Service,
        accessToken: String,
        refreshToken: String? = nil,
        expiresIn: Int? = nil
    ) throws {
        // Save access token
        try setKeychainItem(
            service: service.rawValue,
            account: AccountKey.accessToken,
            data: accessToken
        )

        // Save refresh token (if provided)
        if let refreshToken {
            try setKeychainItem(
                service: service.rawValue,
                account: AccountKey.refreshToken,
                data: refreshToken
            )
        }

        // Save expiry date (if lifetime provided)
        if let expiresIn {
            let expiryDate = Date().addingTimeInterval(TimeInterval(expiresIn))
            let isoString = ISO8601DateFormatter().string(from: expiryDate)
            try setKeychainItem(
                service: service.rawValue,
                account: AccountKey.expiryDate,
                data: isoString
            )
        }
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
        try setKeychainItem(
            service: service.rawValue,
            account: AccountKey.accessToken,
            data: accessToken
        )

        let expiryDate = Date().addingTimeInterval(TimeInterval(expiresIn))
        let isoString = ISO8601DateFormatter().string(from: expiryDate)
        try setKeychainItem(
            service: service.rawValue,
            account: AccountKey.expiryDate,
            data: isoString
        )
    }

    /// Retrieve stored credentials for a service.
    ///
    /// - Parameter service: The OAuth service.
    /// - Returns: Credentials if found, nil if no tokens stored.
    func getCredentials(service: Service) throws -> Credentials? {
        guard let accessToken = try getKeychainItem(
            service: service.rawValue,
            account: AccountKey.accessToken
        ) else {
            return nil
        }

        let refreshToken = try getKeychainItem(
            service: service.rawValue,
            account: AccountKey.refreshToken
        )

        var expiryDate: Date?
        if let expiryString = try getKeychainItem(
            service: service.rawValue,
            account: AccountKey.expiryDate
        ) {
            expiryDate = ISO8601DateFormatter().date(from: expiryString)
        }

        return Credentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiryDate: expiryDate
        )
    }

    /// Delete all stored credentials for a service.
    ///
    /// Used when the user disconnects a source.
    /// - Parameter service: The OAuth service.
    func deleteCredentials(service: Service) throws {
        try deleteKeychainItem(service: service.rawValue, account: AccountKey.accessToken)
        try deleteKeychainItem(service: service.rawValue, account: AccountKey.refreshToken)
        try deleteKeychainItem(service: service.rawValue, account: AccountKey.expiryDate)
    }

    /// Check if credentials exist for a service (without reading them).
    func hasCredentials(service: Service) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrAccount as String: AccountKey.accessToken,
            kSecReturnData as String: false,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Get all connected services.
    func connectedServices() -> [Service] {
        Service.allCases.filter { hasCredentials(service: $0) }
    }

    // MARK: - Keychain Primitives

    /// Errors from Keychain operations.
    enum KeychainError: LocalizedError {
        case unhandledError(status: OSStatus)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unhandledError(let status):
                let message = SecCopyErrorMessageString(status, nil) as? String
                return "Keychain error: \(message ?? "status \(status)")"
            case .encodingFailed:
                return "Failed to encode data for Keychain"
            }
        }
    }

    /// Set (add or update) a Keychain item.
    private func setKeychainItem(service: String, account: String, data: String) throws {
        guard let dataBytes = data.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Try to update first
        let updateAttributes: [String: Any] = [
            kSecValueData as String: dataBytes,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist — add it
            var addQuery = query
            addQuery[kSecValueData as String] = dataBytes
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandledError(status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unhandledError(status: updateStatus)
        }
    }

    /// Get a Keychain item value.
    private func getKeychainItem(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status: status)
        }

        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    /// Delete a Keychain item.
    private func deleteKeychainItem(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)

        // errSecItemNotFound is OK — nothing to delete
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }
}
