import Foundation
import GRDB

/// Audits and migrates stale `organized_path` values without touching audio files.
/// Audit is strictly read-only. Apply is guarded by a SQLite backup, JSON manifest,
/// candidate revalidation, and one all-or-nothing database transaction.
final class OrganizedPathMigrationService {
    enum MatchReason: String, Codable, Hashable {
        case trackID = "deterministic_track_id"
        case exactBasename = "exact_basename"
    }

    enum RowStatus: String, Codable, Equatable {
        case alreadyValid = "already_valid"
        case eligible
        case unresolved
    }

    struct DiskCandidate: Codable, Hashable, Identifiable {
        let relativePath: String
        let reasons: [MatchReason]
        var id: String { relativePath }
    }

    struct AuditRow: Codable, Identifiable {
        let trackID: Int64
        let artist: String
        let title: String
        let beforeOrganizedPath: String
        let status: RowStatus
        let selectedRelativePath: String?
        let selectedReason: MatchReason?
        let candidates: [DiskCandidate]
        let note: String
        var id: Int64 { trackID }
    }

    struct Change: Codable, Equatable {
        let trackID: Int64
        let beforeOrganizedPath: String
        let afterOrganizedPath: String
        let confidence: MatchReason
    }

    struct AuditReport: Codable {
        let schemaVersion: Int
        let generatedAt: Date
        let libraryRoot: String
        let diskFileCount: Int
        let rows: [AuditRow]

        var inspectedCount: Int { rows.count }
        var alreadyValidCount: Int { rows.filter { $0.status == .alreadyValid }.count }
        var eligibleCount: Int { rows.filter { $0.status == .eligible }.count }
        var unresolvedCount: Int { rows.filter { $0.status == .unresolved }.count }
        var changes: [Change] {
            rows.compactMap { row in
                guard row.status == .eligible,
                      let after = row.selectedRelativePath,
                      let reason = row.selectedReason else { return nil }
                return Change(
                    trackID: row.trackID,
                    beforeOrganizedPath: row.beforeOrganizedPath,
                    afterOrganizedPath: after,
                    confidence: reason
                )
            }
        }
    }

    enum ManifestStatus: String, Codable, Equatable {
        case prepared
        case applied
        case failed
        case rollbackPrepared = "rollback_prepared"
        case rolledBack = "rolled_back"
    }

    struct Manifest: Codable {
        let schemaVersion: Int
        let migrationID: String
        let createdAt: Date
        let auditGeneratedAt: Date
        let databasePath: String
        let libraryRoot: String
        let backupPath: String
        let diskFileCount: Int
        let auditRows: [AuditRow]
        let changes: [Change]
        var status: ManifestStatus
        var appliedAt: Date?
        var rolledBackAt: Date?
        var rollbackBackupPath: String?
        var error: String?
    }

    struct ApplyResult {
        let updatedCount: Int
        let backupURL: URL
        let manifestURL: URL
    }

    struct RollbackResult {
        let restoredCount: Int
        let manifestURL: URL
        let rollbackBackupURL: URL
        let manifestFinalizationWarning: String?
    }

    enum MigrationError: LocalizedError {
        case libraryRootMissing
        case artifactsInsideLibrary
        case backupVerificationFailed
        case noEligibleChanges
        case auditChanged
        case candidateMissing(String)
        case rowMismatch(Int64)
        case updateCountMismatch(expected: Int, actual: Int)
        case noAppliedManifest
        case recoveryFailed(String)

        var errorDescription: String? {
            switch self {
            case .libraryRootMissing:
                return "Library root does not exist or is not a directory."
            case .artifactsInsideLibrary:
                return "Backup and manifest directory must be outside the library audio tree."
            case .backupVerificationFailed:
                return "The SQLite backup failed its integrity check; no paths were changed."
            case .noEligibleChanges:
                return "The audit contains no uniquely verified changes."
            case .auditChanged:
                return "The database or disk inventory changed since preview. Run the audit again."
            case .candidateMissing(let path):
                return "Migration candidate disappeared: \(path)"
            case .rowMismatch(let id):
                return "Track \(id) changed since preview; no changes were committed."
            case .updateCountMismatch(let expected, let actual):
                return "Expected \(expected) updates but observed \(actual); no changes were committed."
            case .noAppliedManifest:
                return "No applied organized-path migration is available to roll back."
            case .recoveryFailed(let detail):
                return "Migration finalization and automatic recovery failed: \(detail)"
            }
        }
    }

    private struct Inventory {
        let filesByBasename: [String: [String]]
        let filesByTrackID: [Int64: [String]]
        let fileCount: Int
    }

    private enum ChangeDirection: Equatable {
        case forward
        case backward
    }

    private let database: any DatabaseWriter
    private let databasePath: URL
    private let libraryRoot: URL
    private let artifactsDirectory: URL
    private let fileManager: FileManager

    init(
        database: any DatabaseWriter,
        databasePath: URL,
        libraryRoot: URL,
        artifactsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.database = database
        self.databasePath = databasePath.standardizedFileURL.resolvingSymlinksInPath()
        self.libraryRoot = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.artifactsDirectory = (artifactsDirectory ?? Self.defaultArtifactsDirectory())
            .standardizedFileURL.resolvingSymlinksInPath()
        self.fileManager = fileManager
    }

    /// Read-only: no database, manifest, backup, or audio-file writes occur here.
    func audit() async throws -> AuditReport {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: libraryRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw MigrationError.libraryRootMissing }

        let tracks = try await database.read { db in
            try Track
                .filter(Track.Columns.organizedPath != nil)
                .order(Track.Columns.id)
                .fetchAll(db)
        }
        return makeAuditReport(tracks: tracks, inventory: buildInventory())
    }

    private func makeAuditReport(
        tracks: [Track],
        inventory: Inventory
    ) -> AuditReport {
        var staleClaimantsByBasename: [String: Int] = [:]
        for track in tracks {
            guard let before = track.organizedPath,
                  TranscodeCache.isStaleOrganizedPath(before)
                    || !isExistingLibraryFile(relativePath: before) else { continue }
            staleClaimantsByBasename[normalizedBasename(before), default: 0] += 1
        }
        var rows: [AuditRow] = []
        rows.reserveCapacity(tracks.count)
        var pathsClaimedByValidRows = Set<String>()

        for track in tracks {
            guard let trackID = track.id, let before = track.organizedPath else { continue }
            if !TranscodeCache.isStaleOrganizedPath(before),
               let validRelativePath = canonicalExistingRelativePath(before) {
                pathsClaimedByValidRows.insert(validRelativePath)
                rows.append(AuditRow(
                    trackID: trackID, artist: track.artist, title: track.title,
                    beforeOrganizedPath: before, status: .alreadyValid,
                    selectedRelativePath: nil, selectedReason: nil, candidates: [],
                    note: "Current organized_path resolves"
                ))
                continue
            }

            var grouped: [String: Set<MatchReason>] = [:]
            for path in inventory.filesByTrackID[trackID, default: []]
            where isExpectedDeterministicPath(path, for: track, trackID: trackID) {
                grouped[path, default: []].insert(.trackID)
            }
            let basename = normalizedBasename(before)
            for path in inventory.filesByBasename[basename, default: []] {
                grouped[path, default: []].insert(.exactBasename)
            }
            let candidates = grouped.map { path, reasons in
                DiskCandidate(relativePath: path, reasons: reasons.sorted { $0.rawValue < $1.rawValue })
            }.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }

            let trackIDCandidates = candidates.filter { $0.reasons.contains(.trackID) }
            let basenameCandidates = candidates.filter { $0.reasons.contains(.exactBasename) }
            let selected: DiskCandidate?
            let reason: MatchReason?
            let note: String
            if trackIDCandidates.count == 1 {
                selected = trackIDCandidates[0]
                reason = .trackID
                note = "Unique deterministic [trackId] filename"
            } else if trackIDCandidates.count > 1 {
                selected = nil
                reason = nil
                note = "Multiple deterministic [trackId] candidates"
            } else if basenameCandidates.count == 1,
                      staleClaimantsByBasename[basename] == 1 {
                selected = basenameCandidates[0]
                reason = .exactBasename
                note = "Unique exact basename"
            } else if basenameCandidates.count == 1 {
                selected = nil
                reason = nil
                note = "Exact basename is claimed by multiple stale tracks"
            } else if basenameCandidates.count > 1 {
                selected = nil
                reason = nil
                note = "Duplicate exact basenames require manual resolution"
            } else {
                selected = nil
                reason = nil
                note = "No high-confidence disk candidate"
            }

            rows.append(AuditRow(
                trackID: trackID, artist: track.artist, title: track.title,
                beforeOrganizedPath: before,
                status: selected == nil ? .unresolved : .eligible,
                selectedRelativePath: selected?.relativePath,
                selectedReason: reason, candidates: candidates, note: note
            ))
        }

        let selectedRowsByPath = Dictionary(
            grouping: rows.filter { $0.selectedRelativePath != nil },
            by: { $0.selectedRelativePath! }
        )
        var conflictingTrackIDs = Set(
            rows.lazy
                .filter {
                    guard let selected = $0.selectedRelativePath else { return false }
                    return pathsClaimedByValidRows.contains(selected)
                }
                .map(\.trackID)
        )
        for selectedRows in selectedRowsByPath.values where selectedRows.count > 1 {
            let trackIDRows = selectedRows.filter { $0.selectedReason == .trackID }
            if trackIDRows.count == 1 {
                conflictingTrackIDs.formUnion(
                    selectedRows.lazy
                        .filter { $0.trackID != trackIDRows[0].trackID }
                        .map(\.trackID)
                )
            } else {
                conflictingTrackIDs.formUnion(selectedRows.map(\.trackID))
            }
        }
        if !conflictingTrackIDs.isEmpty {
            rows = rows.map { row in
                guard conflictingTrackIDs.contains(row.trackID) else { return row }
                return AuditRow(
                    trackID: row.trackID,
                    artist: row.artist,
                    title: row.title,
                    beforeOrganizedPath: row.beforeOrganizedPath,
                    status: .unresolved,
                    selectedRelativePath: nil,
                    selectedReason: nil,
                    candidates: row.candidates,
                    note: "Disk candidate is already claimed by another track"
                )
            }
        }

        return AuditReport(
            schemaVersion: 1, generatedAt: Date(), libraryRoot: libraryRoot.path,
            diskFileCount: inventory.fileCount, rows: rows
        )
    }

    /// Applies only organized_path changes. Any missing file or stale row throws from
    /// the write closure, causing GRDB to roll the entire transaction back.
    func apply(_ report: AuditReport) async throws -> ApplyResult {
        guard report.libraryRoot == libraryRoot.path else { throw MigrationError.auditChanged }
        let changes = report.changes
        guard !changes.isEmpty else { throw MigrationError.noEligibleChanges }

        try validateArtifactsDirectory()
        try fileManager.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true)

        let migrationID = Self.makeMigrationID()
        let backupURL = artifactsDirectory.appendingPathComponent("organized-path-migration-\(migrationID).sqlite3")
        let manifestURL = artifactsDirectory.appendingPathComponent("organized-path-migration-\(migrationID).json")

        var manifest = Manifest(
            schemaVersion: 1, migrationID: migrationID, createdAt: Date(),
            auditGeneratedAt: report.generatedAt, databasePath: databasePath.path,
            libraryRoot: libraryRoot.path, backupPath: backupURL.path,
            diskFileCount: report.diskFileCount, auditRows: report.rows, changes: changes,
            status: .prepared, appliedAt: nil, rolledBackAt: nil,
            rollbackBackupPath: nil, error: nil
        )
        try writeManifest(manifest, to: manifestURL)

        do {
            try await database.writeWithoutTransaction { db in
                try db.inTransaction(.immediate) {
                    try self.createVerifiedBackup(at: backupURL)
                    let tracks = try Track
                        .filter(Track.Columns.organizedPath != nil)
                        .order(Track.Columns.id)
                        .fetchAll(db)
                    let freshReport = self.makeAuditReport(
                        tracks: tracks,
                        inventory: self.buildInventory()
                    )
                    guard freshReport.changes == changes else {
                        throw MigrationError.auditChanged
                    }
                    try self.updatePaths(changes, in: db, direction: .forward)
                    return .commit
                }
            }
        } catch {
            manifest.status = .failed
            manifest.error = error.localizedDescription
            try? writeManifest(manifest, to: manifestURL)
            throw error
        }

        manifest.status = .applied
        manifest.appliedAt = Date()
        do {
            try writeManifest(manifest, to: manifestURL)
        } catch {
            let finalizationError = error
            do {
                try await updatePaths(changes, direction: .backward)
            } catch {
                manifest.status = .prepared
                manifest.error = "Manifest finalization failed and DB compensation failed: \(error.localizedDescription)"
                try? writeManifest(manifest, to: manifestURL)
                throw MigrationError.recoveryFailed(
                    "\(error.localizedDescription). Restore from \(backupURL.path)"
                )
            }
            manifest.status = .failed
            manifest.appliedAt = nil
            manifest.error = "Manifest finalization failed; DB changes were compensated: \(finalizationError.localizedDescription)"
            try? writeManifest(manifest, to: manifestURL)
            throw finalizationError
        }
        return ApplyResult(updatedCount: changes.count, backupURL: backupURL, manifestURL: manifestURL)
    }

    /// Rolls back the most recent still-applied manifest. The original migration backup
    /// remains untouched; an additional consistent pre-rollback backup is created.
    func rollbackMostRecent() async throws -> RollbackResult {
        try validateArtifactsDirectory()
        guard let pair = try await latestRecoverableManifest() else {
            throw MigrationError.noAppliedManifest
        }
        var manifest = pair.manifest
        let manifestURL = pair.url
        let rollbackBackupURL = artifactsDirectory
            .appendingPathComponent("organized-path-pre-rollback-\(Self.makeMigrationID()).sqlite3")

        manifest.status = .rollbackPrepared
        manifest.rollbackBackupPath = rollbackBackupURL.path
        manifest.error = nil
        try writeManifest(manifest, to: manifestURL)

        let statusBeforeRollback = pair.manifest.status
        do {
            try await database.writeWithoutTransaction { db in
                try db.inTransaction(.immediate) {
                    try self.createVerifiedBackup(at: rollbackBackupURL)
                    try self.updatePaths(manifest.changes, in: db, direction: .backward)
                    return .commit
                }
            }
        } catch {
            manifest.status = statusBeforeRollback
            manifest.error = error.localizedDescription
            try? writeManifest(manifest, to: manifestURL)
            throw error
        }

        manifest.status = .rolledBack
        manifest.rolledBackAt = Date()
        var finalizationWarning: String?
        do {
            try writeManifest(manifest, to: manifestURL)
        } catch {
            let warning = "Paths were restored, but the manifest status could not be finalized: \(error.localizedDescription)"
            finalizationWarning = warning
            AppLogger.shared.warn(warning, source: "PathMigration")
        }
        return RollbackResult(
            restoredCount: manifest.changes.count, manifestURL: manifestURL,
            rollbackBackupURL: rollbackBackupURL,
            manifestFinalizationWarning: finalizationWarning
        )
    }

    func hasAppliedMigration() async throws -> Bool {
        try await latestRecoverableManifest() != nil
    }

    private func buildInventory() -> Inventory {
        var byBasename: [String: [String]] = [:]
        var byTrackID: [Int64: [String]] = [:]
        var fileCount = 0
        guard let enumerator = fileManager.enumerator(
            at: libraryRoot, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return Inventory(filesByBasename: [:], filesByTrackID: [:], fileCount: 0) }

        for case let fileURL as URL in enumerator {
            guard MetadataExtractor.isAudioFile(fileURL),
                  (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let relative = Self.relativePath(root: libraryRoot, file: fileURL),
                  !TranscodeCache.isStaleOrganizedPath(relative) else { continue }
            fileCount += 1
            byBasename[normalizedBasename(relative), default: []].append(relative)
            if let trackID = Self.deterministicTrackID(in: fileURL) {
                byTrackID[trackID, default: []].append(relative)
            }
        }
        for key in byBasename.keys { byBasename[key]?.sort() }
        for key in byTrackID.keys { byTrackID[key]?.sort() }
        return Inventory(filesByBasename: byBasename, filesByTrackID: byTrackID, fileCount: fileCount)
    }

    private func isExistingLibraryFile(relativePath: String) -> Bool {
        Self.isExistingFile(root: libraryRoot, relativePath: relativePath, fileManager: fileManager)
    }

    private func canonicalExistingRelativePath(_ relativePath: String) -> String? {
        guard isExistingLibraryFile(relativePath: relativePath) else { return nil }
        let candidate = libraryRoot
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        return Self.relativePath(root: libraryRoot, file: candidate)
    }

    private static func isExistingFile(
        root: URL, relativePath: String, fileManager: FileManager
    ) -> Bool {
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard isContained(candidate, in: root) else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func normalizedBasename(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent.lowercased()
    }

    private static func deterministicTrackID(in fileURL: URL) -> Int64? {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        guard stem.last == "]", let opening = stem.lastIndex(of: "[") else { return nil }
        let start = stem.index(after: opening)
        let end = stem.index(before: stem.endIndex)
        guard start < end else { return nil }
        return Int64(stem[start..<end])
    }

    private func isExpectedDeterministicPath(
        _ relativePath: String,
        for track: Track,
        trackID: Int64
    ) -> Bool {
        let fileURL = URL(fileURLWithPath: relativePath)
        let request = DownloadOrchestrator.DownloadRequest(
            trackId: trackID,
            artist: track.artist,
            title: track.title,
            query: "",
            soundcloudURL: nil,
            userId: nil
        )
        return fileURL.lastPathComponent == DownloadOrchestrator.finalFileName(
            for: request,
            pathExtension: fileURL.pathExtension
        )
    }

    private static func relativePath(root: URL, file: URL) -> String? {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    private func validateArtifactsDirectory() throws {
        if artifactsDirectory == libraryRoot || Self.isContained(artifactsDirectory, in: libraryRoot) {
            throw MigrationError.artifactsInsideLibrary
        }
    }

    private func writeManifest(_ manifest: Manifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func createVerifiedBackup(at url: URL) throws {
        var sourceConfiguration = Configuration()
        sourceConfiguration.readonly = true
        let backupSource = try DatabaseQueue(
            path: databasePath.path,
            configuration: sourceConfiguration
        )
        let backupDatabase = try DatabaseQueue(path: url.path)
        try backupSource.backup(to: backupDatabase)
        let integrityResult = try backupDatabase.read { db in
            try String.fetchOne(db, sql: "PRAGMA quick_check")
        }
        guard integrityResult == "ok" else {
            throw MigrationError.backupVerificationFailed
        }
    }

    private func updatePaths(
        _ changes: [Change],
        direction: ChangeDirection
    ) async throws {
        try await database.write { db in
            try self.updatePaths(changes, in: db, direction: direction)
        }
    }

    private func updatePaths(
        _ changes: [Change],
        in db: Database,
        direction: ChangeDirection
    ) throws {
        var updated = 0
        for change in changes {
            let expected: String
            let replacement: String
            switch direction {
            case .forward:
                expected = change.beforeOrganizedPath
                replacement = change.afterOrganizedPath
                guard Self.isExistingFile(
                    root: libraryRoot,
                    relativePath: replacement,
                    fileManager: fileManager
                ) else { throw MigrationError.candidateMissing(replacement) }
            case .backward:
                expected = change.afterOrganizedPath
                replacement = change.beforeOrganizedPath
            }

            let current = try String.fetchOne(
                db,
                sql: "SELECT organized_path FROM tracks WHERE id = ?",
                arguments: [change.trackID]
            )
            guard current == expected else {
                throw MigrationError.rowMismatch(change.trackID)
            }
            try db.execute(
                sql: "UPDATE tracks SET organized_path = ? WHERE id = ? AND organized_path = ?",
                arguments: [replacement, change.trackID, expected]
            )
            guard db.changesCount == 1 else {
                throw MigrationError.rowMismatch(change.trackID)
            }
            updated += db.changesCount
        }
        guard updated == changes.count else {
            throw MigrationError.updateCountMismatch(
                expected: changes.count,
                actual: updated
            )
        }
        for change in changes {
            let expected = direction == .forward
                ? change.afterOrganizedPath
                : change.beforeOrganizedPath
            let persisted = try String.fetchOne(
                db,
                sql: "SELECT organized_path FROM tracks WHERE id = ?",
                arguments: [change.trackID]
            )
            guard persisted == expected else {
                throw MigrationError.rowMismatch(change.trackID)
            }
            if direction == .forward,
               !Self.isExistingFile(
                root: libraryRoot,
                relativePath: expected,
                fileManager: fileManager
               ) {
                throw MigrationError.candidateMissing(expected)
            }
        }
    }

    private func latestRecoverableManifest() async throws -> (manifest: Manifest, url: URL)? {
        guard fileManager.fileExists(atPath: artifactsDirectory.path) else { return nil }
        let urls = try fileManager.contentsOfDirectory(
            at: artifactsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasPrefix("organized-path-migration-") && $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = urls.compactMap { url -> (Manifest, URL)? in
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? decoder.decode(Manifest.self, from: data),
                  manifestMatchesCurrentContext(manifest),
                  [.prepared, .applied, .rollbackPrepared].contains(manifest.status)
            else { return nil }
            return (manifest, url)
        }
        let newestFirst = decoded.sorted { lhs, rhs in
            if lhs.0.createdAt == rhs.0.createdAt {
                return lhs.0.migrationID > rhs.0.migrationID
            }
            return lhs.0.createdAt > rhs.0.createdAt
        }
        for pair in newestFirst {
            switch pair.0.status {
            case .applied:
                return (manifest: pair.0, url: pair.1)
            case .prepared, .rollbackPrepared:
                let allBefore = try await database.read { db in
                    try pair.0.changes.allSatisfy { change in
                        try String.fetchOne(
                            db,
                            sql: "SELECT organized_path FROM tracks WHERE id = ?",
                            arguments: [change.trackID]
                        ) == change.beforeOrganizedPath
                    }
                }
                if !allBefore {
                    return (manifest: pair.0, url: pair.1)
                }
            case .failed, .rolledBack:
                break
            }
        }
        return nil
    }

    private func manifestMatchesCurrentContext(_ manifest: Manifest) -> Bool {
        let manifestDatabasePath = URL(fileURLWithPath: manifest.databasePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let manifestLibraryRoot = URL(fileURLWithPath: manifest.libraryRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return manifestDatabasePath == databasePath.path
            && manifestLibraryRoot == libraryRoot.path
    }

    /// Points manifests recorded against `oldDatabase` at `newDatabase` after the database
    /// moved into a library file (A3 adoption), so their rollback stays available. Only the
    /// `databasePath` field changes. Returns the number of manifests updated.
    @discardableResult
    static func repointManifests(
        in directory: URL,
        fromDatabase oldDatabase: URL,
        to newDatabase: URL,
        fileManager: FileManager = .default
    ) throws -> Int {
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        let old = oldDatabase.standardizedFileURL.resolvingSymlinksInPath().path
        var updated = 0
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix("organized-path-migration-") && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = json["databasePath"] as? String,
                  URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == old
            else { continue }
            json["databasePath"] = newDatabase.path
            let encoded = try JSONSerialization.data(
                withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try encoded.write(to: url, options: .atomic)
            updated += 1
        }
        return updated
    }

    static func defaultArtifactsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("com.musiclibrary.app", isDirectory: true)
            .appendingPathComponent("PathMigrations", isDirectory: true)
    }

    private static func makeMigrationID() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "\(timestamp)-\(UUID().uuidString.lowercased())"
    }
}
