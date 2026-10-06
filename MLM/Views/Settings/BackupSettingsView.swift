import GRDB
import AppKit
import SwiftUI

/// Settings ▸ Backup (ST-BACKUP, DEC-036, F-16): is the library safe, how often, how many,
/// where — and a restore that says exactly what happens. Backups belong to the open library.
///
/// All state and copy that depends on it lives in `BackupSettingsViewModel`; the schedule and
/// retention are implemented in `BackupService`.
struct BackupSettingsView: View {
    @Environment(\.container) private var container
    @State private var viewModel: BackupSettingsViewModel?

    var body: some View {
        Group {
            if let viewModel {
                BackupSettingsForm(viewModel: viewModel)
            } else {
                // No library: the window-level line says why (UC-WIN-05).
                Form {}.formStyle(.grouped)
            }
        }
        .task(id: container.backupService == nil) {
            guard viewModel == nil,
                  let service = container.backupService,
                  let configRepository = container.configRepository else { return }
            let pool = container.databaseManager?.pool
            viewModel = BackupSettingsViewModel(
                service: service,
                configRepository: configRepository,
                // The restored library opens after the relaunch (PP-SETTINGS-16).
                relaunch: BackupSettingsViewModel.relaunchIntoLibrary(package: container.activeLibrary?.packageURL),
                // Counted like a backup's manifest counts its tracks.
                countTracks: { try? await pool?.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") } }
            )
        }
    }
}

private struct BackupSettingsForm: View {
    let viewModel: BackupSettingsViewModel
    @State private var pendingRestore: BackupInfo?
    @State private var refusal: String?
    @State private var choosesFolder = false
    @State private var showsAll = false

    /// Rows before `Show All`.
    private static let visibleRows = 7

    private var libraryName: String {
        LibraryLaunchCoordinator.shared.activeLibraryName ?? "the library"
    }

    var body: some View {
        Form {
            if viewModel.phase == .relaunching || isRestoring {
                Section {
                    HStack(spacing: Spacing.s) {
                        ProgressView().controlSize(.small)
                        SettingsRowLabel(viewModel.phase == .relaunching ? "Relaunching…" : "Restoring…") {
                            Text("MLM quits and reopens in the restored “\(libraryName)”.")
                        }
                    }
                }
            }

            if let message = viewModel.errorMessage, !viewModel.isRelaunchRequired {
                Section { errorLine(message) }
            }

            Group {
                statusSection
                scheduleSection
                folderSection
                backupsSection
            }
            .disabled(viewModel.isBusy)
        }
        .formStyle(.grouped)
        .task { await viewModel.refresh() }
        .folderPanel(isPresented: $choosesFolder, message: "Choose a folder for backups.",
                     directory: viewModel.destination) { url in
            Task { await viewModel.changeDestination(to: url) }
        }
        // A-SET-RESTORE: the consequence first; Cancel is the default (UC-SHEET-15).
        .alert(
            pendingRestore.map(BackupSettingsViewModel.restoreTitle) ?? "",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            presenting: pendingRestore
        ) { info in
            Button("Restore and Relaunch", role: .destructive) {
                Task { await viewModel.restore(info) }
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { info in
            Text(viewModel.restoreMessage(for: info, libraryName: libraryName))
        }
        // Restore refused while work runs (PP-SETTINGS-15): the work is listed.
        .alert("Can’t restore while work is running",
               isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button("Show in Activity") { ActivityWindowOpener.open() }
            Button("OK", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(refusal ?? "")
        }
        // A-SET-RESTOREFAILED: MLM can't continue; one way forward.
        .alert(
            BackupSettingsViewModel.Copy.relaunchRequiredTitle,
            isPresented: Binding(get: { viewModel.isRelaunchRequired }, set: { _ in })
        ) {
            Button("Relaunch") { viewModel.acknowledgeRelaunchRequired() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("MLM couldn’t replace the library files and needs to relaunch. If your library looks wrong afterwards, restore the “Before restore” backup.")
        }
    }

    private var isRestoring: Bool {
        if case .restoring = viewModel.phase { return true }
        return false
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: Spacing.s) {
                    if viewModel.phase == .backingUp {
                        ProgressView().controlSize(.small)
                        Text("Backing up…").foregroundStyle(.secondary)
                    } else if let result = viewModel.lastResult {
                        Text(result).foregroundStyle(.secondary)
                    }
                    Button("Back Up Now") { Task { await viewModel.backUpNow() } }
                        .disabled(viewModel.phase != .idle || !viewModel.destinationReach.isReachable && !viewModel.isDefaultDestination)
                }
            } label: {
                SettingsRowLabel("Last backup") { Text(lastBackupLine) }
            }
        } header: {
            Text("Status")
        } footer: {
            Text(BackupSettingsViewModel.Copy.footer)
        }
    }

    /// `Today, 09:14 · Automatic` or `Never`.
    private var lastBackupLine: String {
        guard let last = viewModel.backups.first(where: \.isComplete) else { return BackupSettingsViewModel.Copy.never }
        return "\(SettingsDate.capitalized(last.createdAt)) · \(BackupSettingsViewModel.reasonLabel(last.reason))"
    }

    // MARK: Schedule

    private var scheduleSection: some View {
        Section {
            Picker("Back up automatically", selection: Binding(
                get: { viewModel.schedule },
                set: { schedule in Task { await viewModel.setSchedule(schedule) } }
            )) {
                ForEach(BackupSchedule.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker(selection: Binding(
                get: { viewModel.retention },
                set: { retention in Task { await viewModel.setRetention(retention) } }
            )) {
                ForEach(BackupRetention.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Text("Keep")
                Text(BackupSettingsViewModel.Copy.keepFooter)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Schedule")
        } footer: {
            Text(BackupSettingsViewModel.Copy.scheduleFooter)
        }
    }

    // MARK: Folder

    private var folderSection: some View {
        Section("Backup folder") {
            LabeledContent {
                HStack {
                    Button("Change…") { choosesFolder = true }
                    if !viewModel.isDefaultDestination {
                        Button("Use Default") { Task { await viewModel.resetDestinationToDefault() } }
                    }
                    ShowInFinderButton(url: viewModel.destination,
                                       disabledReason: viewModel.destinationReach.isReachable ? nil : viewModel.destinationReach.text)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if let destination = viewModel.destination { SettingsPath(destination) }
                    Group {
                        if viewModel.isDefaultDestination {
                            Text(BackupSettingsViewModel.Copy.defaultLocation)
                        } else {
                            switch viewModel.destinationReach {
                            case .notConnected, .notFound:
                                HStack(spacing: 4) {
                                    SettingsState(reach: viewModel.destinationReach)
                                    Text("· automatic backups are skipped until it is connected; the backups stored there are not listed")
                                }
                            default:
                                SettingsState(reach: viewModel.destinationReach)
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .acceptsFolderDrop(enabled: !viewModel.isBusy) { url in
                Task { await viewModel.changeDestination(to: url) }
            }
        }
    }

    // MARK: Backups

    private var backupsSection: some View {
        Section {
            if viewModel.backups.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            } else {
                let rows = showsAll ? viewModel.backups : Array(viewModel.backups.prefix(Self.visibleRows))
                ForEach(rows, id: \.url) { info in
                    backupRow(info)
                }
                if !showsAll, viewModel.backups.count > Self.visibleRows {
                    let more = viewModel.backups.count - Self.visibleRows
                    LabeledContent {
                        Button("Show All") { showsAll = true }
                    } label: {
                        Text(more == 1 ? "1 older backup" : "\(more) older backups").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            HStack {
                Text("Backups of “\(libraryName)”")
                if !viewModel.backups.isEmpty {
                    Text(viewModel.backups.count == 1 ? "1 backup" : "\(viewModel.backups.count) backups")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(BackupSettingsViewModel.formatBytes(viewModel.totalSizeBytes))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(BackupSettingsViewModel.Copy.listFooter)
        }
    }

    private var emptyText: String {
        switch viewModel.schedule {
        case .daily, .weekly:
            "No backups yet. With the schedule set to \(viewModel.schedule.title), the first one is made the next time MLM opens this library."
        case .onQuit:
            "No backups yet. With the schedule set to On quit, the first one is made when MLM quits."
        case .off:
            "No backups yet. Automatic backups are off — use Back Up Now."
        }
    }

    private func backupRow(_ info: BackupInfo) -> some View {
        LabeledContent {
            HStack {
                if info.isComplete {
                    Button("Restore…") { requestRestore(info) }
                }
                ShowInFinderButton(url: info.url)
            }
        } label: {
            SettingsRowLabel(SettingsDate.capitalized(info.createdAt)) {
                if info.isComplete {
                    Text(viewModel.detailLine(for: info))
                } else {
                    HStack(spacing: 4) {
                        Text(viewModel.detailLine(for: info) + " ·")
                        SettingsState(text: "Incomplete — can’t be restored", systemImage: "exclamationmark.triangle", tone: .problem)
                    }
                }
            }
        }
        .help(info.schemaVersion.map { "Database version: \($0)" } ?? "")
        // ST-BACKUP.N04: the row's context menu.
        .contextMenu {
            Button("Restore…") { requestRestore(info) }
                .disabled(!info.isComplete)
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([info.url]) }
        }
    }

    /// `Restore…`: refused with the list of running work, else A-SET-RESTORE.
    private func requestRestore(_ info: BackupInfo) {
        if let blockers = viewModel.restoreBlockers() {
            refusal = BackupSettingsViewModel.restoreRefusal(blockers)
        } else {
            pendingRestore = info
        }
    }

    // MARK: Pieces

    private func errorLine(_ message: String) -> some View {
        LabeledContent {
            Button("Show Logs") { ActivityWindowOpener.open(tab: .logs) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                SettingsState(text: message, systemImage: "exclamationmark.triangle", tone: .problem)
                if let details = viewModel.errorDetails {
                    DisclosureGroup("Details") {
                        Text(details)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }
            }
        }
    }
}
