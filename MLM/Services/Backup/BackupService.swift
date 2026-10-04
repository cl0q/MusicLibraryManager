import Foundation
import GRDB
import AppKit

/// Reason a backup was created.
enum BackupReason: String, Codable, Sendable {
    case scheduled
    case preMigration
    case manual
    case preRestore
}

/// Metadata for a single backup bundle.
struct BackupInfo: Codable, Sendable, Equatable {
    let url: URL
    let createdAt: Date
    let reason: BackupReason?
    let schemaVersion: String?
    let trackCount: Int?
    let databaseSizeBytes: Int64?
    let isComplete: Bool

    // Custom Codable: encode `url` as a path string for JSON portability.
    private enum CodingKeys: String, CodingKey {
        case url, createdAt, reason, schemaVersion, trackCount, databaseSizeBytes, isComplete
    }

    init(
        url: URL,
        createdAt: Date,
        reason: BackupReason?,
        schemaVersion: String?,
        trackCount: Int?,
        databaseSizeBytes: Int64?,
        isComplete: Bool
    ) {
        self.url = url
        self.createdAt = createdAt
        self.reason = reason
        self.schemaVersion = schemaVersion
        self.trackCount = trackCount
        self.databaseSizeBytes = databaseSizeBytes
        self.isComplete = isComplete
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let path = try c.decode(String.self, forKey: .url)
        self.url = URL(fileURLWithPath: path)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.reason = try c.decodeIfPresent(BackupReason.self, forKey: .reason)
        self.schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion)
        self.trackCount = try c.decodeIfPresent(Int.self, forKey: .trackCount)
        self.databaseSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .databaseSizeBytes)
        self.isComplete = try c.decode(Bool.self, forKey: .isComplete)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url.path, forKey: .url)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(schemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(trackCount, forKey: .trackCount)
        try c.encodeIfPresent(databaseSizeBytes, forKey: .databaseSizeBytes)
        try c.encode(isComplete, forKey: .isComplete)
    }
}

/// Errors raised by `BackupService`.
enum BackupError: Error, Equatable {
    case destinationNotWritable
    case vacuumFailed(String)
    case integrityCheckFailed(String)
    case bundleIncomplete(URL)
    case restoreSafetyBackupFailed
}

/// Creates, lists, prunes, and restores timestamped backup bundles of the music library.
final class BackupService: Sendable {
    private let database: any DatabaseWriter & DatabaseReader
    private let databasePath: URL
    private let coversDirectory: URL?
    private let configRepository: ConfigRepository
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    /// Optional closure to close the live database pool before a restore swap.
    private let poolCloser: (@Sendable () throws -> Void)?

    /// Default destination: `~/Library/Application Support/com.musiclibrary.app/backups/`.
    static let defaultDestination: URL = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("com.musiclibrary.app")
            .appendingPathComponent("backups")
    }()

    private static let bundlePrefix = "mlm-backup-"
    private static let tempPrefix = ".tmp-"
    private static let manifestName = "backup.json"
    private static let snapshotName = "music_library.db"
    private static let coversName = "playlist-covers"
    private static let defaultKeep = 10
    private static let staleTempAge: TimeInterval = 3600 // 1 h

    /// Decoder that mirrors `writeManifest`'s ISO 8601 date encoding.
    private static let iso8601Decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(
        database: any DatabaseWriter & DatabaseReader,
        databasePath: URL,
        coversDirectory: URL?,
        configRepository: ConfigRepository,
        fileManager: FileManager = .default,
        now: @Sendable @escaping () -> Date = { Date() },
        poolCloser: (@Sendable () throws -> Void)? = nil
    ) {
        self.database = database
        self.databasePath = databasePath
        self.coversDirectory = coversDirectory
        self.configRepository = configRepository
        self.fileManager = fileManager
        self.now = now
        self.poolCloser = poolCloser
    }

    // MARK: - Destination

    /// Resolved destination directory: `app_config["backup_destination"]` if set,
    /// otherwise the default Application Support path.
    func destinationDirectory() async -> URL {
        if let override = try? await configRepository.getBackupDestination(),
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Self.defaultDestination
    }

    // MARK: - List

    /// Enumerate backup bundles at the destination, newest first.
    ///
    /// - Ignores `.tmp-*` scratch directories.
    /// - Bundles missing `backup.json` or `music_library.db` are returned with `isComplete == false`.
    func listBackups() async throws -> [BackupInfo] {
        try Self.listBundles(in: await destinationDirectory(), fileManager: fileManager)
    }

    // MARK: - Create

    /// Create a new backup bundle with the given reason.
    ///
    /// Atomic-or-nothing: builds in a `.tmp-<UUID>` scratch dir inside the destination,
    /// then moves into place. On any failure the scratch dir is removed.
    func createBackup(reason: BackupReason) async throws -> BackupInfo {
        try await makeBackup(reason: reason, prune: true)
    }

    /// Create a backup only if the newest complete backup is older than `minimumAge`.
    ///
    /// Returns `nil` when throttled (no new bundle created).
    func createBackupIfDue(minimumAge: TimeInterval = 86_400) async throws -> BackupInfo? {
        let backups = try await listBackups()
        let newest = backups.first(where: { $0.isComplete })
        let currentTime = now()
        if let newest, currentTime.timeIntervalSince(newest.createdAt) < minimumAge {
            return nil
        }
        return try await createBackup(reason: .scheduled)
    }

    private func makeBackup(reason: BackupReason, prune: Bool) async throws -> BackupInfo {
        let destination = await destinationDirectory()
        let libraryId = (try? await configRepository.get(key: "library_id")) ?? ""
        let info = try Self.writeBundle(
            database: database,
            databasePath: databasePath,
            coversDirectory: coversDirectory,
            destination: destination,
            reason: reason,
            libraryId: libraryId,
            fileManager: fileManager,
            now: now
        )
        if prune {
            // Best-effort: a failed prune never fails the backup itself.
            _ = try? Self.pruneBundles(in: destination, keep: Self.defaultKeep, fileManager: fileManager)
        }
        return info
    }

    // MARK: - Restore

    /// Validate that a backup bundle is complete on disk and its snapshot passes integrity check.
    ///
    /// Re-checks the filesystem rather than trusting `info.isComplete`, which may be stale.
    /// Throws `.bundleIncomplete` if the bundle is missing `backup.json` or `music_library.db`.
    /// Throws `.integrityCheckFailed` if `PRAGMA quick_check` does not return `"ok"`.
    func validateForRestore(_ info: BackupInfo) throws {
        let manifestURL = info.url.appendingPathComponent(Self.manifestName)
        let snapshotURL = info.url.appendingPathComponent(Self.snapshotName)
        guard fileManager.fileExists(atPath: manifestURL.path),
              fileManager.fileExists(atPath: snapshotURL.path) else {
            throw BackupError.bundleIncomplete(info.url)
        }
        try Self.verifySnapshot(at: snapshotURL)
    }

    /// Replace the live database (and playlist covers) with the contents of a backup bundle.
    ///
    /// Sequence:
    /// 1. Validate the bundle (completeness + integrity).
    /// 2. Safety backup of the current live state (reason `.preRestore`, no pruning so the
    ///    source bundle can never be pruned away mid-restore). Failure → `.restoreSafetyBackupFailed`.
    /// 3. Stage copies of the snapshot (and covers) next to the live files. The source bundle
    ///    is never consumed — it stays complete and restorable.
    /// 4. Close the live pool via `poolCloser`.
    /// 5. Remove the live `-wal` / `-shm` sidecars, then swap the staged snapshot in.
    /// 6. Swap the staged covers in, if the bundle has any and a covers directory is configured.
    ///
    /// Steps 1–4 leave the live database untouched on failure. After this returns the
    /// database is NOT reopened — the caller must relaunch the app (`relaunchApp()`).
    func prepareRestore(from info: BackupInfo) async throws {
        try validateForRestore(info)

        do {
            _ = try await makeBackup(reason: .preRestore, prune: false)
        } catch {
            throw BackupError.restoreSafetyBackupFailed
        }

        let snapshotURL = info.url.appendingPathComponent(Self.snapshotName)
        let stagedDatabase = databasePath.deletingLastPathComponent()
            .appendingPathComponent(".restore-\(UUID().uuidString).db")
        try fileManager.copyItem(at: snapshotURL, to: stagedDatabase)

        var stagedCovers: URL?
        let bundleCovers = info.url.appendingPathComponent(Self.coversName)
        if let coversDirectory, fileManager.fileExists(atPath: bundleCovers.path) {
            let staged = coversDirectory.deletingLastPathComponent()
                .appendingPathComponent(".restore-covers-\(UUID().uuidString)")
            do {
                try fileManager.createDirectory(
                    at: coversDirectory.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: bundleCovers, to: staged)
            } catch {
                try? fileManager.removeItem(at: stagedDatabase)
                throw error
            }
            stagedCovers = staged
        }

        do {
            try poolCloser?()
        } catch {
            try? fileManager.removeItem(at: stagedDatabase)
            if let stagedCovers { try? fileManager.removeItem(at: stagedCovers) }
            throw error
        }

        // SQLite sidecars are `<db>-wal` / `<db>-shm` (suffix, not path extension).
        // A stale WAL left next to the restored file would be replayed onto it.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: databasePath.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try fileManager.removeItem(at: sidecar)
            }
        }
        try Self.swapItem(at: databasePath, with: stagedDatabase, fileManager: fileManager)

        if let coversDirectory, let stagedCovers {
            try Self.swapItem(at: coversDirectory, with: stagedCovers, fileManager: fileManager)
        }
    }

    /// Relaunch the app once this process has exited, then terminate.
    ///
    /// A detached shell waits for this PID to disappear before reopening the bundle, so the
    /// new instance never overlaps the old one. Untestable by design — keep it thin.
    @MainActor
    static func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let target: String
        let launch: String
        if bundleURL.pathExtension == "app" {
            target = bundleURL.path
            launch = "/usr/bin/open \"$1\""
        } else {
            target = Bundle.main.executablePath ?? CommandLine.arguments[0]
            launch = "\"$1\" >/dev/null 2>&1 &"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; \(launch)",
            "sh",
            target
        ]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Pre-migration backup (synchronous)

    /// Check whether there are pending migrations by comparing registered vs applied identifiers.
    ///
    /// Pure function for direct testing.
    static func hasPendingMigrations(registered: Set<String>, applied: Set<String>) -> Bool {
        !registered.isSubset(of: applied)
    }

    /// Perform a synchronous pre-migration backup if there are pending migrations.
    ///
    /// Called from `DatabaseManager.init()` (which is synchronous) before `migrator.migrate`,
    /// so it cannot go through the async instance API or the `DependencyContainer`.
    /// A brand-new database (no applied migrations) has nothing to protect and is skipped.
    ///
    /// Returns the created bundle URL, or `nil` if nothing needed backing up.
    /// Throws if the backup fails (startup aborts — migrations must never run unprotected).
    ///
    /// - Parameters:
    ///   - pool: The live database pool.
    ///   - databasePath: Path to the live database file.
    ///   - coversDirectory: Playlist covers to include in the bundle (`nil` = none).
    ///   - destinationOverride: Override for the backup destination (for testing).
    ///   - fileManager: FileManager to use (default `.default`).
    static func performPreMigrationBackupIfNeeded(
        pool: DatabasePool,
        databasePath: URL,
        coversDirectory: URL? = nil,
        destinationOverride: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL? {
        let migrator = DatabaseManager.buildMigrator()
        let applied = try pool.read { db in
            try migrator.appliedIdentifiers(db)
        }
        guard !applied.isEmpty,
              hasPendingMigrations(registered: Set(migrator.migrations), applied: applied) else {
            return nil
        }

        let configuredDestination = (try? pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = 'backup_destination'")
        }) ?? nil
        let destination: URL
        if let destinationOverride {
            destination = destinationOverride
        } else if let configuredDestination, !configuredDestination.isEmpty {
            destination = URL(fileURLWithPath: configuredDestination)
        } else {
            destination = defaultDestination
        }

        let libraryId = (try? pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = 'library_id'")
        }) ?? nil

        let info = try writeBundle(
            database: pool,
            databasePath: databasePath,
            coversDirectory: coversDirectory,
            destination: destination,
            reason: .preMigration,
            libraryId: libraryId ?? "",
            fileManager: fileManager,
            now: { Date() }
        )
        // Best-effort: a failed prune never aborts startup.
        _ = try? pruneBundles(in: destination, keep: defaultKeep, fileManager: fileManager)
        return info.url
    }

    // MARK: - Prune

    /// Remove backup bundles until at most `keep` remain.
    ///
    /// Incomplete bundles are pruned before complete ones, oldest first in each group.
    /// Returns the URLs of removed bundles.
    @discardableResult
    func pruneBackups(keep: Int = 10) async throws -> [URL] {
        try Self.pruneBundles(in: await destinationDirectory(), keep: keep, fileManager: fileManager)
    }

    // MARK: - Internals

    /// Build a complete bundle in `destination` from a `VACUUM INTO` snapshot of `database`.
    ///
    /// Shared by the async instance API and the synchronous pre-migration hook.
    private static func writeBundle(
        database: any DatabaseWriter,
        databasePath: URL,
        coversDirectory: URL?,
        destination: URL,
        reason: BackupReason,
        libraryId: String,
        fileManager: FileManager,
        now: () -> Date
    ) throws -> BackupInfo {
        // Ensure destination exists and is writable.
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw BackupError.destinationNotWritable
        }
        guard isWritable(destination, fileManager: fileManager) else {
            throw BackupError.destinationNotWritable
        }

        sweepStaleTempDirs(in: destination, fileManager: fileManager, cutoff: now().addingTimeInterval(-staleTempAge))

        let scratch = destination.appendingPathComponent("\(tempPrefix)\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            throw BackupError.destinationNotWritable
        }

        do {
            let snapshotURL = scratch.appendingPathComponent(snapshotName)
            try runVacuumInto(database: database, target: snapshotURL, fileManager: fileManager)
            try verifySnapshot(at: snapshotURL)

            let trackCount = try readTrackCount(from: snapshotURL)
            let schemaVersion = try readSchemaVersion(from: database)
            let createdAt = now()
            let dbSize = dbFileSize(at: snapshotURL)

            let manifest = BackupManifest(
                backupVersion: 1,
                createdAt: createdAt,
                reason: reason,
                sourceDatabasePath: databasePath.path,
                libraryId: libraryId,
                schemaVersion: schemaVersion,
                trackCount: trackCount,
                databaseSizeBytes: dbSize
            )
            try writeManifest(manifest, to: scratch.appendingPathComponent(manifestName))

            // Copy covers if present.
            if let covers = coversDirectory,
               fileManager.fileExists(atPath: covers.path) {
                try fileManager.copyItem(at: covers, to: scratch.appendingPathComponent(coversName))
            }

            // Move scratch → final bundle name.
            let finalName = uniqueBundleName(in: destination, basedOn: createdAt, fileManager: fileManager)
            let finalURL = destination.appendingPathComponent(finalName)
            try fileManager.moveItem(at: scratch, to: finalURL)

            return BackupInfo(
                url: finalURL,
                createdAt: createdAt,
                reason: reason,
                schemaVersion: schemaVersion,
                trackCount: trackCount,
                databaseSizeBytes: dbSize,
                isComplete: true
            )
        } catch {
            // Best-effort cleanup of the scratch dir.
            try? fileManager.removeItem(at: scratch)
            throw error
        }
    }

    private static func listBundles(in destination: URL, fileManager: FileManager) throws -> [BackupInfo] {
        guard fileManager.fileExists(atPath: destination.path) else { return [] }

        let contents = try fileManager.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var infos: [BackupInfo] = []
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix(bundlePrefix) else { continue }
            // Skip any leftover temp dirs that happen to carry the prefix (defensive).
            if name.hasPrefix(tempPrefix) { continue }

            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            infos.append(describeBundle(at: url, fileManager: fileManager))
        }

        return infos.sorted { $0.createdAt > $1.createdAt }
    }

    private static func pruneBundles(in destination: URL, keep: Int, fileManager: FileManager) throws -> [URL] {
        let all = try listBundles(in: destination, fileManager: fileManager)
        guard all.count > keep else { return [] }

        // Split into incomplete (oldest first) and complete (oldest first).
        let incomplete = all.filter { !$0.isComplete }.sorted { $0.createdAt < $1.createdAt }
        let complete = all.filter { $0.isComplete }.sorted { $0.createdAt < $1.createdAt }

        var toRemove: [BackupInfo] = []
        var remaining = all.count

        // Prune incomplete first.
        for info in incomplete {
            guard remaining > keep else { break }
            toRemove.append(info)
            remaining -= 1
        }
        // Then complete, oldest first.
        for info in complete {
            guard remaining > keep else { break }
            toRemove.append(info)
            remaining -= 1
        }

        var removed: [URL] = []
        for info in toRemove {
            do {
                try fileManager.removeItem(at: info.url)
                removed.append(info.url)
            } catch {
                // Best-effort: continue pruning the rest.
            }
        }
        return removed
    }

    private static func describeBundle(at url: URL, fileManager: FileManager) -> BackupInfo {
        let manifestURL = url.appendingPathComponent(manifestName)
        let snapshotURL = url.appendingPathComponent(snapshotName)
        let hasManifest = fileManager.fileExists(atPath: manifestURL.path)
        let hasSnapshot = fileManager.fileExists(atPath: snapshotURL.path)
        let isComplete = hasManifest && hasSnapshot

        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? iso8601Decoder.decode(BackupManifest.self, from: data) {
            return BackupInfo(
                url: url,
                createdAt: manifest.createdAt,
                reason: manifest.reason,
                schemaVersion: manifest.schemaVersion,
                trackCount: manifest.trackCount,
                databaseSizeBytes: manifest.databaseSizeBytes,
                isComplete: isComplete
            )
        }

        // Fallback: use directory mtime.
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date.distantPast
        return BackupInfo(
            url: url,
            createdAt: mtime,
            reason: nil,
            schemaVersion: nil,
            trackCount: nil,
            databaseSizeBytes: nil,
            isComplete: isComplete
        )
    }

    private static func runVacuumInto(database: any DatabaseWriter, target: URL, fileManager: FileManager) throws {
        // VACUUM INTO requires a path string. Use a quoted literal with escaped single quotes.
        let escaped = target.path.replacingOccurrences(of: "'", with: "''")
        let sql = "VACUUM INTO '\(escaped)'"
        do {
            try database.writeWithoutTransaction { db in
                try db.execute(sql: sql)
            }
        } catch {
            throw BackupError.vacuumFailed(String(describing: error))
        }
        guard fileManager.fileExists(atPath: target.path) else {
            throw BackupError.vacuumFailed("snapshot file not created")
        }
    }

    private static func verifySnapshot(at url: URL) throws {
        var config = Configuration()
        config.readonly = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw BackupError.integrityCheckFailed(String(describing: error))
        }
        let result = try queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA quick_check")
        }
        guard result == "ok" else {
            throw BackupError.integrityCheckFailed(result ?? "no result")
        }
    }

    private static func readTrackCount(from snapshotURL: URL) throws -> Int {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: snapshotURL.path, configuration: config)
        return try queue.read { db in
            guard try db.tableExists("tracks") else { return 0 }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? 0
        }
    }

    /// Highest applied migration identifier, read from GRDB's `grdb_migrations` table.
    private static func readSchemaVersion(from database: any DatabaseWriter) throws -> String {
        let ids = try database.read { db -> [String] in
            guard try db.tableExists("grdb_migrations") else { return [] }
            return try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        return ids.last ?? ""
    }

    private static func dbFileSize(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
    }

    private static func writeManifest(_ manifest: BackupManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    /// Build a unique bundle name for the given date, appending `-1`, `-2`, … on collision.
    private static func uniqueBundleName(in directory: URL, basedOn date: Date, fileManager: FileManager) -> String {
        let base = bundleName(for: date)
        var candidate = base
        var suffix = 1
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// Format a date as `mlm-backup-yyyyMMdd-HHmmss` in local time.
    private static func bundleName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)
        return "\(bundlePrefix)\(stamp)"
    }

    private static func isWritable(_ url: URL, fileManager: FileManager) -> Bool {
        let probe = url.appendingPathComponent(".mlm-write-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .atomic)
            try fileManager.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// Remove `.tmp-*` scratch dirs last modified before `cutoff`.
    private static func sweepStaleTempDirs(in directory: URL, fileManager: FileManager, cutoff: Date) {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        )) ?? []
        for url in contents {
            guard url.lastPathComponent.hasPrefix(tempPrefix) else { continue }
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .contentModificationDateKey]
            )
            guard values?.isDirectory == true,
                  let mtime = values?.contentModificationDate,
                  mtime < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Replace `target` with `staged` (same volume). `target` may or may not exist.
    private static func swapItem(at target: URL, with staged: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: target)
        }
    }
}

/// On-disk manifest shape for `backup.json`.
private struct BackupManifest: Codable {
    let backupVersion: Int
    let createdAt: Date
    let reason: BackupReason
    let sourceDatabasePath: String
    let libraryId: String
    let schemaVersion: String
    let trackCount: Int
    let databaseSizeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case backupVersion = "backup_version"
        case createdAt = "created_at"
        case reason
        case sourceDatabasePath = "source_database_path"
        case libraryId = "library_id"
        case schemaVersion = "schema_version"
        case trackCount = "track_count"
        case databaseSizeBytes = "database_size_bytes"
    }
}
