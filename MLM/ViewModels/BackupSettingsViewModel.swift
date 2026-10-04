import Foundation

/// View model for Settings → Backup.
///
/// Wraps `BackupService` for the pane: destination, bundle list, manual backups, and the
/// restore flow that ends in a relaunch. All copy that depends on state lives here so it
/// can be tested without rendering the view.
@MainActor
@Observable
final class BackupSettingsViewModel {

    enum Phase: Equatable {
        case idle
        case backingUp
        case restoring(BackupInfo)
        case relaunching
    }

    /// Which operation an error came from — the same `BackupError` can mean different
    /// things to the user depending on it.
    enum ErrorContext {
        case backup
        case restore
    }

    /// Binding UI copy (UI-GROUNDTRUTH §5.6, Backup tab).
    enum Copy {
        static let notWritable = "MLM can't write to the backup folder. Choose another folder."
        static let backupFailed = "The backup couldn't be created. Try again."
        static let backupIntegrityFailed = "The backup copy failed its integrity check and was discarded. Try again."
        static let restoreDamaged = "This backup is damaged and can't be restored. Choose another backup."
        static let restoreIncomplete = "This backup is incomplete and can't be restored. Choose another backup."
        static let restoreSafetyBackupFailed = "MLM couldn't save a copy of your current library, so nothing was restored. Check the backup folder and try again."
        static let generic = "Something went wrong. Try again."
        static let relaunchRequiredTitle = "Restore didn't finish"
        static let relaunchRequired = "MLM couldn't replace the library files and needs to relaunch. If your library looks wrong afterwards, restore the \"Before restore\" backup."
        static let backupCreated = "Backup created"
        static let never = "Never"
    }

    // MARK: - State

    private(set) var destination: URL?
    private(set) var isDefaultDestination = true
    private(set) var backups: [BackupInfo] = []
    /// On-disk size per bundle, keyed by bundle URL.
    private(set) var bundleSizes: [URL: Int64] = [:]
    /// Creation date of the newest complete backup.
    private(set) var lastBackupDate: Date?
    private(set) var totalSizeBytes: Int64 = 0
    private(set) var phase: Phase = .idle
    /// One result line for the last finished action.
    private(set) var lastResult: String?
    /// Plain-language error line (cause + one action).
    private(set) var errorMessage: String?
    /// Technical detail for the "Details" disclosure; never shown as the main line.
    private(set) var errorDetails: String?
    /// The restore failed after the database was closed: the only way forward is a relaunch.
    private(set) var isRelaunchRequired = false

    var isBusy: Bool { phase != .idle }

    // MARK: - Dependencies

    private let service: BackupService
    private let configRepository: ConfigRepository
    private let relaunch: @MainActor () -> Void

    init(
        service: BackupService,
        configRepository: ConfigRepository,
        relaunch: @escaping @MainActor () -> Void = { BackupService.relaunchApp() }
    ) {
        self.service = service
        self.configRepository = configRepository
        self.relaunch = relaunch
    }

    // MARK: - Actions

    /// Reload destination and bundle list. A no-op once a restore has started: the
    /// database is (or is about to be) closed and config lookups would silently fall back
    /// to the default destination.
    func refresh() async {
        switch phase {
        case .restoring, .relaunching: return
        case .idle, .backingUp: break
        }

        let configured = (try? await configRepository.getBackupDestination()) ?? nil
        isDefaultDestination = configured?.isEmpty ?? true
        destination = await service.destinationDirectory()

        do {
            let list = try await service.listBackups()
            let urls = list.map(\.url)
            let sizes = await Task.detached { Self.measureBundles(urls) }.value
            backups = list
            bundleSizes = sizes
            lastBackupDate = list.first(where: \.isComplete)?.createdAt
            totalSizeBytes = sizes.values.reduce(0, +)
        } catch {
            present(error, context: .backup)
        }
    }

    /// Create a manual backup, then refresh the list.
    func backUpNow() async {
        guard phase == .idle else { return }
        phase = .backingUp
        clearMessages()
        do {
            _ = try await service.createBackup(reason: .manual)
            lastResult = Copy.backupCreated
        } catch {
            present(error, context: .backup)
        }
        phase = .idle
        await refresh()
    }

    /// Persist a new destination after proving it is writable. An unwritable folder is
    /// rejected and the previous destination stays in effect.
    func changeDestination(to url: URL) async {
        guard phase == .idle else { return }
        clearMessages()
        let writable = await Task.detached { Self.isWritable(url) }.value
        guard writable else {
            errorMessage = Copy.notWritable
            return
        }
        do {
            try await configRepository.setBackupDestination(url.path)
        } catch {
            present(error, context: .backup)
            return
        }
        await refresh()
    }

    /// Clear the custom destination (empty value ⇒ default destination).
    func resetDestinationToDefault() async {
        guard phase == .idle else { return }
        clearMessages()
        do {
            try await configRepository.setBackupDestination("")
        } catch {
            present(error, context: .backup)
            return
        }
        await refresh()
    }

    /// Restore `info` and relaunch. Failures before the database closed leave the pane
    /// usable; `.restoreSwapFailed` requires a relaunch, which `acknowledgeRelaunchRequired()`
    /// performs once the user has read the message.
    func restore(_ info: BackupInfo) async {
        guard phase == .idle else { return }
        clearMessages()
        guard info.isComplete else {
            errorMessage = Copy.restoreIncomplete
            return
        }

        phase = .restoring(info)
        do {
            try await service.prepareRestore(from: info)
            phase = .relaunching
            relaunch()
        } catch BackupError.restoreSwapFailed(let detail) {
            phase = .relaunching
            errorDetails = detail
            isRelaunchRequired = true
        } catch {
            phase = .idle
            present(error, context: .restore)
            await refresh()
        }
    }

    func acknowledgeRelaunchRequired() {
        guard isRelaunchRequired else { return }
        isRelaunchRequired = false
        relaunch()
    }

    // MARK: - Presentation

    static func reasonLabel(_ reason: BackupReason?) -> String {
        switch reason {
        case .scheduled: return "Automatic"
        case .preMigration: return "Before update"
        case .manual: return "Manual"
        case .preRestore: return "Before restore"
        case nil: return "Unknown"
        }
    }

    /// Plain-language main line for an error (UI-GROUNDTRUTH §1.7 rule 4).
    static func message(for error: Error, context: ErrorContext) -> String {
        guard let backupError = error as? BackupError else { return Copy.generic }
        switch backupError {
        case .destinationNotWritable:
            return Copy.notWritable
        case .vacuumFailed:
            return Copy.backupFailed
        case .integrityCheckFailed:
            return context == .restore ? Copy.restoreDamaged : Copy.backupIntegrityFailed
        case .bundleIncomplete:
            return Copy.restoreIncomplete
        case .restoreSafetyBackupFailed:
            return Copy.restoreSafetyBackupFailed
        case .restoreSwapFailed:
            return Copy.relaunchRequired
        }
    }

    /// Technical detail for the "Details" disclosure, if there is any worth showing.
    static func details(for error: Error) -> String? {
        guard let backupError = error as? BackupError else { return String(describing: error) }
        switch backupError {
        case .vacuumFailed(let detail), .integrityCheckFailed(let detail), .restoreSwapFailed(let detail):
            return detail
        case .bundleIncomplete(let url):
            return url.path
        case .destinationNotWritable, .restoreSafetyBackupFailed:
            return nil
        }
    }

    static func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var lastBackupText: String {
        lastBackupDate.map(Self.formatDate) ?? Copy.never
    }

    /// Secondary line for a bundle row: `Manual · 12,935 tracks · 124.8 MB`.
    func detailLine(for info: BackupInfo) -> String {
        var parts = [Self.reasonLabel(info.reason)]
        if let count = info.trackCount {
            parts.append(count == 1 ? "1 track" : "\(count.formatted()) tracks")
        }
        if let size = bundleSizes[info.url] ?? info.databaseSizeBytes {
            parts.append(Self.formatBytes(size))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Helpers

    private func clearMessages() {
        lastResult = nil
        errorMessage = nil
        errorDetails = nil
    }

    private func present(_ error: Error, context: ErrorContext) {
        errorMessage = Self.message(for: error, context: context)
        errorDetails = Self.details(for: error)
    }

    /// Write-probe the folder, the same way `BackupService` checks its destination.
    nonisolated static func isWritable(_ directory: URL) -> Bool {
        let probe = directory.appendingPathComponent(".mlm-write-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .atomic)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// Allocated on-disk size of each bundle directory.
    nonisolated static func measureBundles(_ urls: [URL]) -> [URL: Int64] {
        var sizes: [URL: Int64] = [:]
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        for url in urls {
            var total: Int64 = 0
            if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
                for case let file as URL in enumerator {
                    let values = try? file.resourceValues(forKeys: Set(keys))
                    total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
                }
            }
            sizes[url] = total
        }
        return sizes
    }
}
