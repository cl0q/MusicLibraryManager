import Foundation

/// Reads OAuth credentials from process environment or a .env file.
///
/// Priority:
/// 1. Process environment (`ProcessInfo.processInfo.environment`)
/// 2. `~/Library/Application Support/MLM/.env`
///
/// The .env file format is one `KEY=VALUE` pair per line.
/// Lines starting with `#` and blank lines are ignored.
enum CredentialsLoader {

    /// Path to the .env file in Application Support.
    static var envFilePath: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MLM")
            .appendingPathComponent(".env")
    }

    /// Load and parse the .env file.
    static func loadEnvFile() -> [String: String] {
        guard let content = try? String(contentsOf: envFilePath, encoding: .utf8) else {
            return [:]
        }
        var result: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let eqRange = trimmed.range(of: "=") else { continue }
            let key = String(trimmed[..<eqRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[eqRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    /// Return a credential value by key.
    ///
    /// Checks process environment first (useful when launched via `run.sh`
    /// which exports vars from the repo root `.env`), then falls back to the
    /// Application Support `.env` file (used when launched as a standalone .app).
    static func credential(key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
            return value
        }
        return loadEnvFile()[key]
    }

    /// Whether OAuth credentials are present for the given service.
    static func hasCredentials(for service: TokenStorage.Service) -> Bool {
        switch service {
        case .soundcloud:
            credential(key: "SOUNDCLOUD_CLIENT_ID") != nil &&
            credential(key: "SOUNDCLOUD_CLIENT_SECRET") != nil
        case .spotify:
            credential(key: "SPOTIFY_CLIENT_ID") != nil &&
            credential(key: "SPOTIFY_CLIENT_SECRET") != nil
        case .appleMusic:
            true  // Uses MusicKit — no custom OAuth credentials
        }
    }
}
