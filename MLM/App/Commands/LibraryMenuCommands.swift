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
            CommandButton(.refreshFromSources)
            CommandButton(.scanLibraryFolder,
                          enabled: shellActions?.isScanningLibraryFolder == false,
                          disabledReason: hasLibrary ? "The library folder is being scanned." : nil) {
                shellActions?.scanLibraryFolder()
            }

            Divider()

            CommandButton(.findDuplicates)
            CommandButton(.findAlbums)

            Divider()

            CommandSubmenu(.maintenance, enabled: hasLibrary) {
                CommandButton(.fingerprintAllTracks)
                CommandButton(.replayGainAnalysis)
                CommandButton(.danceabilityAnalysis)
                CommandButton(.similarityAnalysis)
                Divider()
                CommandButton(.refreshEmbeddedArtwork)
                CommandButton(.fetchArtworkFromMusicBrainz)
                CommandButton(.rereadTagsFromFiles)
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
}

/// Library ▸ Back Up Now: a manual backup through the same service call as Settings ▸ Backup,
/// confirmed in the status bar (UC-STATUS-04). The Activity operation for it arrives with
/// W3-ACT / W3-SET.
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
            do {
                _ = try await service.createBackup(reason: .manual)
                statusBar.post(BackupSettingsViewModel.Copy.backupCreated, actions: [
                    StatusAction("Show") { openSettings(tab: .backup) },
                ])
            } catch {
                AppLogger.shared.error("Back Up Now failed: \(error.localizedDescription)", source: "Backup")
                statusBar.post(BackupSettingsViewModel.message(for: error, context: .backup), actions: [
                    StatusAction("Show") { openSettings(tab: .backup) },
                ])
            }
        }
    }
}
