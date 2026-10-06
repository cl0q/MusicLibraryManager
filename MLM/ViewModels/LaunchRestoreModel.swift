import Foundation
import GRDB
import Observation

/// `Restore from Backup…` on a library that failed to open (S-LAUNCH-RESTORE, DEC-031).
///
/// The restore is the existing one (`BackupService.prepareRestore` through
/// `BackupSettingsViewModel.restore`): it first saves a `Before restore` backup of the current
/// database, never restores across libraries, then relaunches. To reach it without opening the
/// library, the library's database is opened as a plain pool — **no migration, no
/// pre-migration backup** — and closed again when the screen moves on. Offered only when that
/// works, the database names the library it should (`expectedLibraryId`), and complete backups
/// exist; otherwise the failure screen has no `Restore from Backup…`.
@MainActor
@Observable
final class LaunchRestoreModel {
    let libraryName: String
    let backups: BackupSettingsViewModel
    @ObservationIgnored private let pool: DatabasePool

    private init(libraryName: String, backups: BackupSettingsViewModel, pool: DatabasePool) {
        self.libraryName = libraryName
        self.backups = backups
        self.pool = pool
    }

    /// Complete backups, newest first.
    var restorable: [BackupInfo] { backups.backups.filter(\.isComplete) }

    /// - Parameters:
    ///   - expectedLibraryId: the id the database must carry (`nil` = any, the old install).
    ///   - relaunch: after a successful restore (the caller makes the library open again).
    static func make(
        databaseURL: URL,
        expectedLibraryId: String?,
        libraryName: String,
        backupsRoot: URL,
        relaunch: @escaping @MainActor () -> Void
    ) async -> LaunchRestoreModel? {
        let opened: (DatabasePool, String)? = await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
            var config = Configuration()
            config.foreignKeysEnabled = false
            guard let pool = try? DatabasePool(path: databaseURL.path, configuration: config) else { return nil }
            // "" = the database has no library id (the old install before adoption).
            let id: String
            do {
                id = try pool.read { db -> String in
                    guard try db.tableExists("app_config") else { return "" }
                    return try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = 'library_id'") ?? ""
                }
            } catch {
                try? pool.close()
                return nil
            }
            return (pool, id)
        }.value
        guard let (pool, libraryId) = opened else { return nil }
        if let expectedLibraryId, expectedLibraryId != libraryId {
            try? pool.close()
            return nil
        }
        let service = BackupService(
            database: pool,
            databasePath: databaseURL,
            coversDirectory: DatabaseManager.playlistCoversDirectory(forDatabaseAt: databaseURL),
            configRepository: ConfigRepository(database: pool),
            defaultBackupsRoot: backupsRoot,
            poolCloser: { try pool.close() }
        )
        let backups = BackupSettingsViewModel(
            service: service, configRepository: ConfigRepository(database: pool), relaunch: relaunch)
        await backups.refresh()
        let model = LaunchRestoreModel(libraryName: libraryName, backups: backups, pool: pool)
        guard !model.restorable.isEmpty else {
            model.close()
            return nil
        }
        return model
    }

    /// Restores `info` (the existing path) and relaunches.
    func restore(_ info: BackupInfo) async {
        await backups.restore(info)
    }

    /// Release the database before anything else opens it.
    func close() {
        guard !backups.isBusy else { return }
        try? pool.close()
    }

    /// `Today, 09:14` style, the way Settings ▸ Backup lists them.
    static func dateText(_ info: BackupInfo) -> String {
        BackupSettingsViewModel.formatDate(info.createdAt)
    }

    /// `Automatic · 12,935 tracks · 124.8 MB`.
    func detailText(_ info: BackupInfo) -> String {
        var parts = [BackupSettingsViewModel.reasonLabel(info.reason)]
        if let tracks = info.trackCount {
            parts.append("\(tracks.formatted(.number)) \(tracks == 1 ? "track" : "tracks")")
        }
        if let size = backups.bundleSizes[info.url] ?? info.databaseSizeBytes {
            parts.append(size.formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }
}
