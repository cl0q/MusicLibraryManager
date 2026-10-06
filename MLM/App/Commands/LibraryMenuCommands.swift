import Observation
import SwiftUI

/// Library menu (M-LIBRARY). Its old items moved: Search Library → Edit ▸ Find, Import from
/// Folder… → File ▸ Import Files or Folder…, More Info → Track ▸ Get Info; the temporary
/// `Sources` item became File ▸ Import Playlist from Source… (IMP-009).
struct LibraryMenuCommands: Commands {
    @FocusedValue(\.shellActions) private var shellActions
    @FocusedValue(\.statusBarCenter) private var statusBar
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandMenu(MenuBarMenu.library.rawValue) {
            let hasLibrary = shellActions != nil
            // W3-ADD: every connected source, one Activity operation each (UC-TB-05).
            CommandButton(.refreshFromSources,
                          enabled: shellActions?.canRefreshFromSources == true,
                          disabledReason: hasLibrary ? ImportSheetsPresenter.noSourceConnected : nil) {
                shellActions?.refreshFromSources()
            }
            CommandButton(.scanLibraryFolder,
                          enabled: shellActions?.isScanningLibraryFolder == false,
                          disabledReason: hasLibrary ? "The library folder is being scanned." : nil) {
                shellActions?.scanLibraryFolder()
            }

            Divider()

            // W3-REV: the same Activity operation as Review ▸ Run Scan; it never opens Review (P3).
            CommandButton(.findDuplicates, enabled: hasLibrary && ReviewScanRunner.shared.blockedReason == nil,
                          disabledReason: hasLibrary ? ReviewScanRunner.shared.blockedReason : "No library is open.") {
                ReviewScanRunner.shared.startWithConfirmation(statusBar: statusBar)
            }
            CommandButton(.findAlbums)

            Divider()

            CommandSubmenu(.maintenance, enabled: hasLibrary) {
                CommandButton(.fingerprintAllTracks, enabled: jobBlockedReason(MaintenanceJob.fingerprint) == nil,
                              disabledReason: jobBlockedReason(MaintenanceJob.fingerprint)) {
                    MaintenanceJobs.shared.start(MaintenanceJob.fingerprint)
                }
                CommandButton(.replayGainAnalysis, enabled: jobBlockedReason(MaintenanceJob.replayGain) == nil,
                              disabledReason: jobBlockedReason(MaintenanceJob.replayGain)) {
                    MaintenanceJobs.shared.start(MaintenanceJob.replayGain)
                }
                CommandButton(.danceabilityAnalysis, enabled: jobBlockedReason(MaintenanceJob.danceability) == nil,
                              disabledReason: jobBlockedReason(MaintenanceJob.danceability)) {
                    MaintenanceJobs.shared.start(MaintenanceJob.danceability)
                }
                CommandButton(.similarityAnalysis, enabled: jobBlockedReason(MaintenanceJob.similarity) == nil,
                              disabledReason: jobBlockedReason(MaintenanceJob.similarity)) {
                    MaintenanceJobs.shared.start(MaintenanceJob.similarity)
                }
                Divider()
                CommandButton(.refreshEmbeddedArtwork, enabled: jobBlockedReason(MaintenanceJob.artworkEmbedded) == nil,
                              disabledReason: jobBlockedReason(MaintenanceJob.artworkEmbedded)) {
                    MaintenanceJobs.shared.start(MaintenanceJob.artworkEmbedded)
                }
                CommandButton(.fetchArtworkFromMusicBrainz, enabled: jobBlockedReason(MaintenanceJob.artworkMusicBrainz) == nil,
                              disabledReason: jobBlockedReason(MaintenanceJob.artworkMusicBrainz)) {
                    MaintenanceJobs.shared.start(MaintenanceJob.artworkMusicBrainz)
                }
                CommandButton(.rereadTagsFromFiles, enabled: jobBlockedReason(MaintenanceJob.rereadTags) == nil,
                              disabledReason: jobBlockedReason(MaintenanceJob.rereadTags)) {
                    // It replaces database values: the question is asked in Settings ▸ Maintenance,
                    // where the job's row is (review S2).
                    MaintenanceJobs.shared.rereadConfirmationRequested = true
                    openSettings(tab: .maintenance)
                }
                Divider()
                CommandButton(.maintenanceSettings, enabled: hasLibrary) {
                    openSettings(tab: .maintenance)
                }
            }
            CommandButton(.backUpNow,
                          enabled: hasLibrary && statusBar != nil && !BackupNowCommand.shared.isRunning,
                          disabledReason: BackupNowCommand.shared.isRunning ? "A backup is being made." : nil) {
                if let statusBar { BackupNowCommand.shared.run(statusBar: statusBar, openSettings: openSettings) }
            }

            Divider()

            CommandButton(.librarySettings, enabled: hasLibrary) {
                openSettings(tab: .library)
            }
        }
    }

    /// A Maintenance ▸ job (W3-SET) starts or queues the job and never opens Settings (P3). It
    /// is disabled with the reason while it is queued or running, or while it can't run.
    private func jobBlockedReason(_ action: String) -> String? {
        guard shellActions != nil else { return "No library is open." }
        let jobs = MaintenanceJobs.shared
        if jobs.runner.isActive(action) { return "This job is running or queued — see Activity." }
        return jobs.blockedReason(action, drive: LibraryDriveState.current(.shared),
                                  toolMissing: DownloadToolsModel.shared.isMissing(.fpcalc))
    }
}

/// Library ▸ Back Up Now: a manual backup through the same service call as Settings ▸ Backup,
/// confirmed in the status bar (UC-STATUS-04) and registered in Activity (quiet: the status bar
/// already says it).
@MainActor
@Observable
final class BackupNowCommand {
    static let shared = BackupNowCommand()

    private(set) var isRunning = false

    func run(statusBar: StatusBarCenter, openSettings: OpenSettingsAction, container: DependencyContainer = .shared) {
        guard !isRunning, let service = container.backupService else { return }
        isRunning = true
        let token = statusBar.beginLoading("Backing up…")
        Task {
            defer {
                statusBar.endLoading(token)
                isRunning = false
            }
            // W3-SET: the same Activity operation as Settings ▸ Backup ▸ Back Up Now (UC-JOB-01);
            // written with its result only, like there.
            let job = ActivityCenter.shared.begin(.backup, title: "Back Up Now", subject: .settings(.backup),
                                                  quiet: true, recordsStart: false)
            do {
                let info = try await service.createBackup(reason: .manual)
                job.finish(.backup(info))
                statusBar.post(BackupSettingsViewModel.Copy.backupCreated, actions: [
                    StatusAction("Show") { openSettings(tab: .backup) },
                ])
            } catch {
                job.fail(cause: BackupSettingsViewModel.message(for: error, context: .backup),
                         fix: .openSettings(SettingsTab.backup.rawValue))
                AppLogger.shared.error("Back Up Now failed: \(error.localizedDescription)", source: "Backup")
                statusBar.post(BackupSettingsViewModel.message(for: error, context: .backup), actions: [
                    StatusAction("Show") { openSettings(tab: .backup) },
                ])
            }
        }
    }
}
