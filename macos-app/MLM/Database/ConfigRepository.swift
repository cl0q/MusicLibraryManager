import Foundation
import GRDB

/// Repository for app configuration key-value store.
///
/// Maps to the `app_config` table. Used for library root path,
/// theme settings, and other persistent configuration.
final class ConfigRepository: Sendable {
    private let database: DatabasePool

    init(database: DatabasePool) {
        self.database = database
    }

    // MARK: - Read

    /// Get a config value by key.
    func get(key: String) async throws -> String? {
        try await database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT value FROM app_config WHERE key = ?
            """, arguments: [key])?["value"]
        }
    }

    /// Get all config key-value pairs.
    func getAll() async throws -> [AppConfig] {
        try await database.read { db in
            try AppConfig.fetchAll(db)
        }
    }

    // MARK: - Write

    /// Set a config value (insert or update).
    func set(key: String, value: String) async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO app_config (key, value, updated_at)
                VALUES (?, ?, datetime('now'))
            """, arguments: [key, value])
        }
    }

    /// Delete a config key.
    func delete(key: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM app_config WHERE key = ?",
                arguments: [key]
            )
        }
    }

    // MARK: - Convenience Accessors

    /// Get the library root path.
    func getLibraryRoot() async throws -> String? {
        try await get(key: "library_root")
    }

    /// Set the library root path.
    func setLibraryRoot(_ path: String) async throws {
        try await set(key: "library_root", value: path)
    }

    /// Get the current theme.
    func getTheme() async throws -> String {
        try await get(key: "theme") ?? "solar"
    }

    /// Set the current theme.
    func setTheme(_ theme: String) async throws {
        try await set(key: "theme", value: theme)
    }

    /// Get the library size limit in GB (if set).
    func getLibrarySizeLimit() async throws -> Int? {
        guard let value = try await get(key: "library_size_limit_gb") else {
            return nil
        }
        return Int(value)
    }
}
