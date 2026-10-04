import Foundation
import GRDB

/// Moves the pre-A3 install (loose `music_library.db` + `playlist-covers/` in Application
/// Support) into a library file (A0 D7, Step-0 decision 6).
///
/// Copy, then retire — never delete. A journal next to the legacy database records the last
/// completed step, so an interrupted adoption resumes at the next launch:
///
/// | Step | Effect | After a crash |
/// |---|---|---|
/// | `started` | journal written | roll back |
/// | `backedUp` | pre-adoption backup (`.preAdoption`) | roll back |
/// | `staged` | `VACUUM INTO` + covers + manifest in `<name>.mlibm.partial/` | roll back (drop `.partial`) |
/// | `verified` | `quick_check`, library id, track count | roll back |
/// | `installed` | `.partial` renamed to `.mlibm` — point of no return | roll forward |
/// | `registered` | registry entry + last active | roll forward |
/// | `repointed` | path-migration manifests (and id-less backups) follow the database | roll forward |
/// | `retired` | legacy files moved to `legacy-adopted-<timestamp>/` | roll forward |
///
/// The legacy files are only read until `retired`, so before the point of no return the old
/// layout stays fully usable; from it on, a complete library file exists.
struct LibraryAdoption: Sendable {

    struct Environment: Sendable {
        var legacyDatabaseURL: URL
        var registryStore: LibraryRegistryStore
        var backupsRoot: URL
        var pathMigrationsDirectory: URL

        var appSupportDirectory: URL { legacyDatabaseURL.deletingLastPathComponent() }
        var legacyCoversDirectory: URL {
            DatabaseManager.playlistCoversDirectory(forDatabaseAt: legacyDatabaseURL)
        }

        static var production: Environment {
            Environment(
                legacyDatabaseURL: DatabaseManager.legacyDatabaseURL,
                registryStore: LibraryRegistryStore(),
                backupsRoot: BackupService.defaultBackupsRoot,
                pathMigrationsDirectory: OrganizedPathMigrationService.defaultArtifactsDirectory()
            )
        }
    }

    /// What the adoption sheet shows while it runs.
    enum Phase: Equatable, Sendable {
        case backingUp
        case creatingLibraryFile
        case checking
    }

    enum Step: Int, Codable, CaseIterable, Comparable, Sendable {
        case started, backedUp, staged, verified, installed, registered, repointed, retired

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum AdoptionError: Error, Equatable {
        case legacyDatabaseMissing
        case alreadyInProgress
        case journalUnreadable
        /// The copy didn't match the original; the copy is discarded.
        case verificationFailed(String)
        /// Something appeared at the library file's path while adopting.
        case packagePathTaken
    }

    struct Result: Equatable, Sendable {
        let packageURL: URL
        let libraryId: String
        let retiredDirectory: URL
    }

    enum Outcome: Equatable, Sendable {
        case completed(Result)
        case rolledBack
    }

    let environment: Environment
    let now: @Sendable () -> Date

    init(environment: Environment = .production, now: @escaping @Sendable () -> Date = { Date() }) {
        self.environment = environment
        self.now = now
    }

    var journalURL: URL { environment.appSupportDirectory.appendingPathComponent("adoption-journal.json") }

    /// An adoption was started and not finished or rolled back.
    var isInProgress: Bool { FileManager.default.fileExists(atPath: journalURL.path) }

    // MARK: - Run

    /// Adopt the legacy install as a library named `name`. Before the point of no return a
    /// failure rolls back completely; after it, the journal stays and `resume()` finishes.
    func adopt(named name: String, progress: (Phase) -> Void) throws -> Result {
        try begin(named: name)
        do {
            progress(.backingUp)
            try advance(through: .backedUp)
            progress(.creatingLibraryFile)
            try advance(through: .staged)
            progress(.checking)
            try advance(through: .retired)
        } catch {
            if installedPackageURL() == nil {
                try? rollBack()
            }
            throw error
        }
        return try finish()
    }

    /// Finish or undo an interrupted adoption (next launch).
    func resume() throws -> Outcome {
        guard isInProgress else { return .rolledBack }
        var journal = try readJournal()
        guard isInstalled(journal) else {
            try rollBack()
            return .rolledBack
        }
        if journal.step < .installed {
            journal.step = .installed
            try writeJournal(journal)
        }
        try advance(through: .retired)
        return .completed(try finish())
    }

    /// The library file, once the adoption is past its point of no return.
    func installedPackageURL() -> URL? {
        guard let journal = try? readJournal(), isInstalled(journal) else { return nil }
        return URL(filePath: journal.packagePath, directoryHint: .notDirectory)
    }

    // MARK: - Steps (internal for crash tests)

    /// Write the journal: decide the library file's path, the library id and the retire folder.
    func begin(named name: String) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: environment.legacyDatabaseURL.path) else {
            throw AdoptionError.legacyDatabaseMissing
        }
        guard !isInProgress else { throw AdoptionError.alreadyInProgress }

        let existingId = try LibraryPackage.readDatabaseLibraryId(at: environment.legacyDatabaseURL)
        let package = LibraryPackage.availablePackageURL(
            forLibraryName: name, in: environment.registryStore.librariesDirectory)
        let journal = Journal(
            step: .started,
            name: name,
            packagePath: package.path,
            libraryId: existingId ?? UUID().uuidString.lowercased(),
            legacyHadLibraryId: existingId != nil,
            sourceTrackCount: nil,
            retiredPath: retiredDirectory().path,
            startedAt: now()
        )
        try writeJournal(journal)
    }

    /// Run the remaining steps up to and including `target`, recording each in the journal.
    func advance(through target: Step) throws {
        var journal = try readJournal()
        while journal.step < target, let next = Step(rawValue: journal.step.rawValue + 1) {
            try perform(next, journal: &journal)
            journal.step = next
            try writeJournal(journal)
        }
    }

    private func perform(_ step: Step, journal: inout Journal) throws {
        let fileManager = FileManager.default
        let package = URL(filePath: journal.packagePath, directoryHint: .notDirectory)
        let staging = LibraryPackage.stagingURL(for: package)

        switch step {
        case .started:
            break

        case .backedUp:
            let legacy = try openLegacyDatabase()
            defer { try? legacy.close() }
            _ = try BackupService.createBundle(
                database: legacy,
                databasePath: environment.legacyDatabaseURL,
                coversDirectory: existingLegacyCovers,
                reason: .preAdoption,
                backupsRoot: environment.backupsRoot,
                now: now
            )

        case .staged:
            if fileManager.fileExists(atPath: staging.path) {
                try fileManager.removeItem(at: staging)
            }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            let stagedDatabase = LibraryPackage.databaseURL(in: staging)
            do {
                let legacy = try openLegacyDatabase()
                defer { try? legacy.close() }
                journal.sourceTrackCount = try legacy.read(Self.trackCount)
                let escaped = stagedDatabase.path.replacingOccurrences(of: "'", with: "''")
                try legacy.writeWithoutTransaction { db in
                    try db.execute(sql: "VACUUM INTO '\(escaped)'")
                }
            }
            if !journal.legacyHadLibraryId {
                // The new id goes into the copy only; the legacy database stays untouched.
                try LibraryPackage.assignLibraryId(journal.libraryId, toDatabaseIn: staging)
            }
            if let covers = existingLegacyCovers {
                try fileManager.copyItem(at: covers, to: LibraryPackage.coversDirectory(in: staging))
            }
            let manifest = LibraryPackageManifest(
                libraryId: journal.libraryId,
                name: journal.name,
                createdAt: now(),
                schemaVersion: try LibraryPackage.readDatabaseIdentity(at: stagedDatabase).schemaVersion
            )
            try manifest.write(to: LibraryPackage.manifestURL(in: staging))

        case .verified:
            try verify(staging: staging, journal: journal)

        case .installed:
            let packageExists = fileManager.fileExists(atPath: package.path)
            let stagingExists = fileManager.fileExists(atPath: staging.path)
            if packageExists && !stagingExists { break } // renamed before the journal caught up
            guard !packageExists else { throw AdoptionError.packagePathTaken }
            try fileManager.moveItem(at: staging, to: package)

        case .registered:
            var registry = try environment.registryStore.load(now: now()).registry
            registry.upsert(libraryId: journal.libraryId, url: package, name: journal.name)
            registry.markOpened(libraryId: journal.libraryId, at: now())
            try environment.registryStore.save(registry)

        case .repointed:
            let newDatabase = LibraryPackage.databaseURL(in: package)
            try OrganizedPathMigrationService.repointManifests(
                in: environment.pathMigrationsDirectory,
                fromDatabase: environment.legacyDatabaseURL,
                to: newDatabase
            )
            if !journal.legacyHadLibraryId {
                var folders = [environment.backupsRoot]
                if let custom = try customBackupDestination(of: newDatabase) { folders.append(custom) }
                for folder in folders {
                    try BackupService.claimUnassignedBundles(
                        in: folder,
                        sourceDatabasePath: environment.legacyDatabaseURL,
                        libraryId: journal.libraryId
                    )
                }
            }

        case .retired:
            let retired = URL(fileURLWithPath: journal.retiredPath)
            try fileManager.createDirectory(at: retired, withIntermediateDirectories: true)
            let database = environment.legacyDatabaseURL
            let items = [
                database,
                URL(fileURLWithPath: database.path + "-wal"),
                URL(fileURLWithPath: database.path + "-shm"),
                environment.legacyCoversDirectory,
            ]
            for item in items where fileManager.fileExists(atPath: item.path) {
                let target = retired.appendingPathComponent(item.lastPathComponent)
                guard !fileManager.fileExists(atPath: target.path) else { continue }
                try fileManager.moveItem(at: item, to: target)
            }
        }
    }

    // MARK: - Verification

    private func verify(staging: URL, journal: Journal) throws {
        var config = Configuration()
        config.readonly = true
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: LibraryPackage.databaseURL(in: staging).path, configuration: config)
        defer { try? queue.close() }

        let check = try queue.read { db in try String.fetchOne(db, sql: "PRAGMA quick_check") }
        guard check == "ok" else { throw AdoptionError.verificationFailed("quick_check: \(check ?? "no result")") }

        let libraryId = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = 'library_id'")
        }
        guard libraryId == journal.libraryId else {
            throw AdoptionError.verificationFailed("library id \(libraryId ?? "none") ≠ \(journal.libraryId)")
        }

        let count = try queue.read(Self.trackCount)
        guard count == journal.sourceTrackCount else {
            throw AdoptionError.verificationFailed("tracks \(count) ≠ \(journal.sourceTrackCount ?? -1)")
        }

        let manifest = try LibraryPackageManifest.read(from: LibraryPackage.manifestURL(in: staging))
        guard manifest.libraryId == journal.libraryId else {
            throw AdoptionError.verificationFailed("manifest id \(manifest.libraryId) ≠ \(journal.libraryId)")
        }

        if let covers = existingLegacyCovers {
            let fileManager = FileManager.default
            let original = try fileManager.contentsOfDirectory(atPath: covers.path).sorted()
            let copied = try fileManager.contentsOfDirectory(
                atPath: LibraryPackage.coversDirectory(in: staging).path).sorted()
            guard original == copied else {
                throw AdoptionError.verificationFailed("covers \(copied.count) ≠ \(original.count)")
            }
        }
    }

    private static func trackCount(_ db: Database) throws -> Int {
        guard try db.tableExists("tracks") else { return 0 }
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? 0
    }

    // MARK: - Journal

    private struct Journal: Codable {
        var journalVersion = 1
        var step: Step
        var name: String
        var packagePath: String
        var libraryId: String
        var legacyHadLibraryId: Bool
        var sourceTrackCount: Int?
        var retiredPath: String
        var startedAt: Date

        enum CodingKeys: String, CodingKey {
            case journalVersion = "journal_version"
            case step
            case name
            case packagePath = "package_path"
            case libraryId = "library_id"
            case legacyHadLibraryId = "legacy_had_library_id"
            case sourceTrackCount = "source_track_count"
            case retiredPath = "retired_path"
            case startedAt = "started_at"
        }
    }

    private func readJournal() throws -> Journal {
        guard let data = try? Data(contentsOf: journalURL),
              let journal = try? LibraryJSON.decoder.decode(Journal.self, from: data) else {
            throw AdoptionError.journalUnreadable
        }
        return journal
    }

    private func writeJournal(_ journal: Journal) throws {
        try AtomicFileWriter.write(try LibraryJSON.encoder.encode(journal), to: journalURL)
    }

    /// Past the point of no return: recorded, or the rename happened before the journal
    /// caught up (library file present with this adoption's id, staging gone).
    private func isInstalled(_ journal: Journal) -> Bool {
        if journal.step >= .installed { return true }
        let package = URL(filePath: journal.packagePath, directoryHint: .notDirectory)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: package.path),
              !fileManager.fileExists(atPath: LibraryPackage.stagingURL(for: package).path),
              let id = try? LibraryPackage.readDatabaseLibraryId(at: LibraryPackage.databaseURL(in: package))
        else { return false }
        return id == journal.libraryId
    }

    /// Undo everything before the point of no return: only the staging folder and the journal
    /// are removed. The pre-adoption backup stays.
    private func rollBack() throws {
        if let journal = try? readJournal() {
            let package = URL(filePath: journal.packagePath, directoryHint: .notDirectory)
            let staging = LibraryPackage.stagingURL(for: package)
            if FileManager.default.fileExists(atPath: staging.path) {
                try FileManager.default.removeItem(at: staging)
            }
        }
        try FileManager.default.removeItem(at: journalURL)
    }

    private func finish() throws -> Result {
        let journal = try readJournal()
        try FileManager.default.removeItem(at: journalURL)
        return Result(
            packageURL: URL(filePath: journal.packagePath, directoryHint: .notDirectory),
            libraryId: journal.libraryId,
            retiredDirectory: URL(fileURLWithPath: journal.retiredPath)
        )
    }

    // MARK: - Helpers

    /// Plain connection (not read-only) so WAL contents are included.
    private func openLegacyDatabase() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = false
        return try DatabaseQueue(path: environment.legacyDatabaseURL.path, configuration: config)
    }

    private var existingLegacyCovers: URL? {
        let covers = environment.legacyCoversDirectory
        return FileManager.default.fileExists(atPath: covers.path) ? covers : nil
    }

    private func customBackupDestination(of database: URL) throws -> URL? {
        let queue = try DatabaseQueue(path: database.path)
        defer { try? queue.close() }
        let value = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = 'backup_destination'")
        }
        guard let value, !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value)
    }

    private func retiredDirectory() -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let base = "legacy-adopted-\(formatter.string(from: now()))"
        var candidate = environment.appSupportDirectory.appendingPathComponent(base)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = environment.appSupportDirectory.appendingPathComponent("\(base)-\(counter)")
            counter += 1
        }
        return candidate
    }
}
