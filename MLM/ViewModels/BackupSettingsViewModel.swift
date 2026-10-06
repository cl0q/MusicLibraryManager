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
        static let relaunchRequiredTitle = "Restore didn’t finish"
        static let relaunchRequired = "MLM couldn't replace the library files and needs to relaunch. If your library looks wrong afterwards, restore the \"Before restore\" backup."
        static let backupCreated = "Backup created"
        static let never = "Never"
        static let footer = "Each backup contains the library database and playlist covers. Audio files and account credentials are never included."
        static let scheduleFooter = "MLM also backs up before updating the library database, before a restore and before library file setup, whatever the schedule."
        static let keepFooter = "Older backups are removed after a new one succeeds."
        static let listFooter = "Only backups of the open library are listed. Restoring never crosses libraries."
        static let defaultLocation = "Default location"
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
    /// Back up automatically (DEC-036).
    private(set) var schedule: BackupSchedule = .default
    /// Keep (DEC-036).
    private(set) var retention: BackupRetention = .default
    /// Whether the backup folder can be reached now (ST-BACKUP.E04 / N03).
    private(set) var destinationReach: LocationReach = .notSet
    /// Tracks in the library now (for the restore consequence).
    private(set) var currentTrackCount: Int?

    var isBusy: Bool { phase != .idle }

    // MARK: - Dependencies

    private let service: BackupService
    private let configRepository: ConfigRepository
    private let relaunch: @MainActor () -> Void
    /// Activity's queued, running and paused operations (the restore guard, PP-SETTINGS-15).
    private let activeOperations: @MainActor () -> [ActivityOperation]
    private let countTracks: @Sendable () async -> Int?
    private let isVolumeMounted: @Sendable (URL) -> Bool

    /// - Parameter relaunch: after a successful restore. The app passes
    ///   `relaunchIntoLibrary(package:)`, so the restored library opens even when “Open the last
    ///   library at launch” is off (PP-SETTINGS-16).
    init(
        service: BackupService,
        configRepository: ConfigRepository,
        relaunch: @escaping @MainActor () -> Void = { BackupService.relaunchApp() },
        activeOperations: @escaping @MainActor () -> [ActivityOperation] = { ActivityCenter.shared.activeOperations },
        countTracks: @escaping @Sendable () async -> Int? = { nil },
        isVolumeMounted: @escaping @Sendable (URL) -> Bool = { DataLocationsViewModel.isVolumeMounted($0) }
    ) {
        self.service = service
        self.configRepository = configRepository
        self.relaunch = relaunch
        self.activeOperations = activeOperations
        self.countTracks = countTracks
        self.isVolumeMounted = isVolumeMounted
    }

    /// The relaunch after a restore: the library file to open next time is remembered first
    /// (W3-LAUNCH's pending open), then MLM relaunches.
    static func relaunchIntoLibrary(
        package: URL?,
        pendingOpen: LibraryLaunchCoordinator.PendingOpenStore = .userDefaults,
        relaunch: @escaping @MainActor () -> Void = { BackupService.relaunchApp() }
    ) -> @MainActor () -> Void {
        {
            if let package { pendingOpen.set(package.path) }
            relaunch()
        }
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
        schedule = await service.schedule()
        retention = await service.retention()
        currentTrackCount = await countTracks()
        let mounted = isVolumeMounted
        let folder = destination
        destinationReach = await Task.detached {
            LocationReach.of(folder, isVolumeMounted: mounted, exists: { FileManager.default.fileExists(atPath: $0.path) })
        }.value

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
        // Activity (W3-ACT): `Back Up Now` — no Cancel (it has none).
        // The row is written with the result only: the backup's own snapshot must not contain a
        // running row that a restore would show as "Stopped when MLM quit" (N5).
        let job = ActivityCenter.shared.begin(.backup, title: "Back Up Now", subject: .settings(.backup),
                                              recordsStart: false)
        do {
            let info = try await service.createBackup(reason: .manual)
            lastResult = Copy.backupCreated
            job.finish(.backup(info))
        } catch {
            present(error, context: .backup)
            job.fail(cause: errorMessage ?? error.localizedDescription, fix: .runAgain)
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

    // MARK: - Schedule and retention

    func setSchedule(_ schedule: BackupSchedule) async {
        clearMessages()
        do {
            try await service.setSchedule(schedule)
            self.schedule = schedule
        } catch {
            present(error, context: .backup)
        }
    }

    func setRetention(_ retention: BackupRetention) async {
        guard phase == .idle else { return }
        clearMessages()
        do {
            try await service.setRetention(retention)
            self.retention = retention
        } catch {
            present(error, context: .backup)
        }
        await refresh()
    }

    // MARK: - Restore guard (PP-SETTINGS-15)

    /// The work that blocks a restore now: everything running, queued or paused except work
    /// that waits for the library drive. `nil` when a restore may start.
    func restoreBlockers() -> RunningWorkSummary? {
        let summary = RunningWorkSummary(operations: activeOperations())
        return summary.isEmpty ? nil : summary
    }

    /// `Can’t restore while 2 downloads and 1 sync are running.` + one line per operation.
    static func restoreRefusal(_ summary: RunningWorkSummary) -> String {
        var text = "MLM can’t restore while \(summary.runningPhrase) running. Let them finish or cancel them in Activity, then restore."
        for line in summary.lines { text += "\n• " + line }
        if summary.moreCount > 0 { text += "\n• and \(summary.moreCount.formatted(.number)) more" }
        return text
    }

    /// A-SET-RESTORE's title: `Restore the backup from 4 Oct 2026, 08:57?`
    static func restoreTitle(_ info: BackupInfo) -> String {
        "Restore the backup from \(formatDate(info.createdAt))?"
    }

    /// A-SET-RESTORE's message: what happens, in numbers, and how to undo it.
    func restoreMessage(for info: BackupInfo, libraryName: String) -> String {
        var text = "MLM first saves a copy of the current library (“Before restore”), then replaces the library database and playlist covers with this backup. MLM quits and reopens in the restored “\(libraryName)”. Audio files are not changed."
        if let now = currentTrackCount, let then = info.trackCount, now > then {
            let added = now - then
            text += "\n\n\(added == 1 ? "1 track" : "\(added.formatted()) tracks") added since this backup \(added == 1 ? "leaves" : "leave") the library; their files stay in the library folder."
        }
        text += "\n\nTo undo, restore the “Before restore” backup."
        return text
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
        // Work that started after the alert opened still blocks it (PP-SETTINGS-15).
        if let blockers = restoreBlockers() {
            errorMessage = Self.restoreRefusal(blockers)
            return
        }

        phase = .restoring(info)
        // Activity (W3-ACT): app-level — the library file is replaced by the restore.
        let job = ActivityCenter.shared.begin(
            .restore, title: "Restore backup of \(info.createdAt.formatted(date: .abbreviated, time: .shortened))",
            subject: .settings(.backup), appLevel: true)
        do {
            try await service.prepareRestore(from: info)
            job.finish(ActivityResult(summary: "Relaunching with the restored library"))
            await ActivityCenter.shared.flushPersistence()
            phase = .relaunching
            relaunch()
        } catch BackupError.restoreSwapFailed(let detail) {
            job.fail(cause: "Restore didn’t finish — MLM relaunches to recover")
            await ActivityCenter.shared.flushPersistence()
            phase = .relaunching
            errorDetails = detail
            isRelaunchRequired = true
        } catch {
            phase = .idle
            present(error, context: .restore)
            job.fail(cause: errorMessage ?? error.localizedDescription)
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
        case .preAdoption: return "Before library file setup"
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
        case .wrongLibrary:
            return Copy.generic
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
        case .destinationNotWritable, .restoreSafetyBackupFailed, .wrongLibrary:
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
