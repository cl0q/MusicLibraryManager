import Foundation
import GRDB

/// A library file: a `.mlibm` directory that Finder shows as one file (A0 D1/D9).
///
/// ```
/// Main Library.mlibm/
/// ├── library.json        manifest (D6)
/// ├── music_library.db    SQLite, WAL
/// └── playlist-covers/
/// ```
///
/// The database's `app_config.library_id` is the authority: a missing or damaged
/// manifest is rebuilt from it, never the other way round, and any disagreement
/// between database, manifest and registry is reported, never repaired.
enum LibraryPackage {
    static let fileExtension = "mlibm"
    static let databaseFileName = "music_library.db"
    static let stagingSuffix = ".partial"

    /// Fallback file name when a library name sanitizes to nothing.
    private static let fallbackName = "Library"
    /// Leaves room for " 99", the staging suffix and the extension within 255 bytes.
    private static let maxBaseNameBytes = 200

    // MARK: - Layout

    static func manifestURL(in package: URL) -> URL {
        package.appendingPathComponent(LibraryPackageManifest.fileName)
    }

    static func databaseURL(in package: URL) -> URL {
        package.appendingPathComponent(databaseFileName)
    }

    static func coversDirectory(in package: URL) -> URL {
        DatabaseManager.playlistCoversDirectory(forDatabaseAt: databaseURL(in: package))
    }

    // MARK: - File names

    /// `<name>.mlibm`, with characters Finder or the filesystem can't take replaced.
    static func fileName(forLibraryName name: String) -> String {
        "\(sanitizedBaseName(name)).\(fileExtension)"
    }

    /// First free `<name>.mlibm`, `<name> 2.mlibm`, … in `directory`. A name is taken
    /// when either the library file or its staging directory exists.
    static func availablePackageURL(
        forLibraryName name: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let base = sanitizedBaseName(name)
        var counter = 1
        while true {
            let candidate = directory.appendingPathComponent(
                counter == 1 ? "\(base).\(fileExtension)" : "\(base) \(counter).\(fileExtension)")
            let staging = stagingURL(for: candidate)
            if !fileManager.fileExists(atPath: candidate.path), !fileManager.fileExists(atPath: staging.path) {
                return candidate
            }
            counter += 1
        }
    }

    static func stagingURL(for package: URL) -> URL {
        URL(fileURLWithPath: package.path + stagingSuffix)
    }

    private static func sanitizedBaseName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            scalars.append(scalar == "/" || scalar == ":" ? "-" : scalar)
        }
        var base = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.utf8.count > maxBaseNameBytes { base.removeLast() }
        return base.isEmpty ? fallbackName : base
    }

    // MARK: - Create

    /// Creates a new, migrated, empty library file in `directory` and returns its URL.
    ///
    /// Built in a `.partial` staging directory and renamed at the end, so an interrupted
    /// creation never leaves something that looks like a library file.
    static func createEmpty(
        named name: String,
        libraryId: String,
        in directory: URL,
        now: Date,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let package = availablePackageURL(forLibraryName: name, in: directory, fileManager: fileManager)
        let staging = stagingURL(for: package)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            let manager = try DatabaseManager(path: databaseURL(in: staging))
            try manager.pool.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO app_config (key, value, updated_at) VALUES ('library_id', ?, datetime('now'))",
                    arguments: [libraryId])
            }
            try manager.pool.close()

            let manifest = LibraryPackageManifest(
                libraryId: libraryId,
                name: name,
                createdAt: now,
                schemaVersion: try readDatabaseIdentity(at: databaseURL(in: staging)).schemaVersion
            )
            try manifest.write(to: manifestURL(in: staging))
            try fileManager.moveItem(at: staging, to: package)
            return package
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - Database identity

    /// Writes `libraryId` into the database of `package`, only if it has none. Used once for
    /// a library file built by hand; an existing id is never replaced.
    static func assignLibraryId(_ libraryId: String, toDatabaseIn package: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: databaseURL(in: package).path, configuration: config)
        defer { try? queue.close() }
        try queue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO app_config (key, value, updated_at) VALUES ('library_id', ?, datetime('now'))",
                arguments: [libraryId])
        }
    }

    /// `app_config.library_id` of the database at `url`, or `nil` when the database, the
    /// table or the key doesn't exist. Never creates a database.
    static func readDatabaseLibraryId(at url: URL) throws -> String? {
        try readDatabaseIdentity(at: url).libraryId
    }

    /// Library id plus the last applied migration (the manifest's `schema_version`).
    ///
    /// Uses a plain connection (not read-only) so WAL contents are seen.
    static func readDatabaseIdentity(at url: URL) throws -> (libraryId: String?, schemaVersion: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        defer { try? queue.close() }
        let migrator = DatabaseManager.buildMigrator()
        return try queue.read { db in
            var libraryId: String?
            if try db.tableExists("app_config") {
                libraryId = try String.fetchOne(
                    db, sql: "SELECT value FROM app_config WHERE key = 'library_id'")
            }
            let applied = try migrator.appliedIdentifiers(db)
            let schemaVersion = migrator.migrations.last(where: { applied.contains($0) })
            return (libraryId?.isEmpty == false ? libraryId : nil, schemaVersion)
        }
    }

    // MARK: - Validate

    enum ValidationError: Error, Equatable {
        case notFound
        /// Not a directory, or no `music_library.db` inside.
        case missingDatabase
        /// The database carries no `library_id`; adoption/open must assign one first.
        case missingLibraryId
        case unsupportedManifestVersion(Int)
        /// Database id differs from the manifest's or the registry's. Never auto-repaired.
        case idMismatch(expected: String, found: String)
    }

    struct Validated: Equatable {
        let url: URL
        let manifest: LibraryPackageManifest
        /// The manifest was missing or unreadable and has been rewritten from the database.
        let manifestRepaired: Bool
    }

    /// Checks that `package` is a usable library file whose identity agrees everywhere.
    ///
    /// - Parameter expectedLibraryId: the registry's id for this path, if any.
    static func validate(
        at package: URL,
        expectedLibraryId: String?,
        now: Date,
        fileManager: FileManager = .default
    ) throws -> Validated {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: package.path, isDirectory: &isDirectory) else {
            throw ValidationError.notFound
        }
        let database = databaseURL(in: package)
        guard isDirectory.boolValue, fileManager.fileExists(atPath: database.path) else {
            throw ValidationError.missingDatabase
        }

        let identity = try readDatabaseIdentity(at: database)
        guard let databaseId = identity.libraryId else { throw ValidationError.missingLibraryId }
        if let expectedLibraryId, expectedLibraryId != databaseId {
            throw ValidationError.idMismatch(expected: expectedLibraryId, found: databaseId)
        }

        let manifestURL = manifestURL(in: package)
        do {
            let manifest = try LibraryPackageManifest.read(from: manifestURL)
            guard manifest.libraryId == databaseId else {
                throw ValidationError.idMismatch(expected: manifest.libraryId, found: databaseId)
            }
            return Validated(url: package, manifest: manifest, manifestRepaired: false)
        } catch LibraryPackageManifest.ReadError.unsupportedVersion(let version) {
            throw ValidationError.unsupportedManifestVersion(version)
        } catch LibraryPackageManifest.ReadError.missing, LibraryPackageManifest.ReadError.malformed {
            let repaired = LibraryPackageManifest(
                libraryId: databaseId,
                name: package.deletingPathExtension().lastPathComponent,
                createdAt: now,
                schemaVersion: identity.schemaVersion
            )
            try repaired.write(to: manifestURL)
            return Validated(url: package, manifest: repaired, manifestRepaired: true)
        }
    }
}
