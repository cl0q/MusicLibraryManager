import SwiftUI
import AppKit

/// Settings → Backup: backup folder, the list of backups, manual backups, and restore.
///
/// All state and copy that depends on it lives in `BackupSettingsViewModel`.
struct BackupSettingsView: View {
    @Environment(\.container) private var container
    @State private var viewModel: BackupSettingsViewModel?

    var body: some View {
        Group {
            if let viewModel {
                BackupSettingsForm(viewModel: viewModel)
            } else {
                Form {
                    Section {
                        Text("Backups are available once the library has loaded.")
                            .font(MLMFont.body)
                            .foregroundStyle(Color.mlmInkSecondary)
                    }
                }
                .formStyle(.grouped)
                .padding()
            }
        }
        .task(id: container.backupService == nil) {
            guard viewModel == nil,
                  let service = container.backupService,
                  let configRepository = container.configRepository else { return }
            viewModel = BackupSettingsViewModel(service: service, configRepository: configRepository)
        }
    }
}

private struct BackupSettingsForm: View {
    let viewModel: BackupSettingsViewModel
    @State private var pendingRestore: BackupInfo?

    var body: some View {
        Form {
            if viewModel.phase == .relaunching || isRestoring {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(viewModel.phase == .relaunching ? "Relaunching…" : "Restoring…")
                            .font(MLMFont.body)
                    }
                }
            }

            if let message = viewModel.errorMessage, !viewModel.isRelaunchRequired {
                Section {
                    errorLine(message)
                }
            }

            Group {
                statusSection
                backupsSection
                actionsSection
            }
            .disabled(viewModel.isBusy)
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await viewModel.refresh()
        }
        .alert(
            restoreTitle,
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            presenting: pendingRestore
        ) { info in
            Button("Restore and relaunch", role: .destructive) {
                Task { await viewModel.restore(info) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("MLM first saves a copy of your current library, then replaces the library database and playlist covers with this backup and relaunches. Audio files are not changed. Finish active downloads and syncs first. To undo, restore the \"Before restore\" backup.")
        }
        .alert(
            BackupSettingsViewModel.Copy.relaunchRequiredTitle,
            isPresented: Binding(
                get: { viewModel.isRelaunchRequired },
                set: { _ in }
            )
        ) {
            Button("Relaunch") {
                viewModel.acknowledgeRelaunchRequired()
            }
        } message: {
            Text(BackupSettingsViewModel.Copy.relaunchRequired)
        }
    }

    private var isRestoring: Bool {
        if case .restoring = viewModel.phase { return true }
        return false
    }

    private var restoreTitle: String {
        guard let pendingRestore else { return "" }
        return "Restore backup from \(BackupSettingsViewModel.formatDate(pendingRestore.createdAt))?"
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            LabeledContent("Backup folder") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(viewModel.destination?.path ?? "")
                        .font(MLMFont.data)
                        .foregroundStyle(Color.mlmInkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if viewModel.isDefaultDestination {
                        Text("Default location")
                            .font(MLMFont.muted)
                            .foregroundStyle(Color.mlmInkMuted)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Change…") {
                    chooseDestination()
                }
                if !viewModel.isDefaultDestination {
                    Button("Use default") {
                        Task { await viewModel.resetDestinationToDefault() }
                    }
                }
                Button("Show in Finder") {
                    if let destination = viewModel.destination {
                        showInFinder(destination)
                    }
                }
                .disabled(viewModel.destination == nil)
            }

            LabeledContent("Last backup", value: viewModel.lastBackupText)
            LabeledContent("Backups", value: "\(viewModel.backups.count)")
            LabeledContent("Total size", value: BackupSettingsViewModel.formatBytes(viewModel.totalSizeBytes))
        } header: {
            Text("Status")
        } footer: {
            Text("Each backup contains the library database and playlist covers. Audio files and account credentials are never included.")
                .font(MLMFont.muted)
                .foregroundStyle(Color.mlmInkSecondary)
        }
    }

    // MARK: - Backups

    private var backupsSection: some View {
        Section("Backups") {
            if viewModel.backups.isEmpty {
                Text("No backups yet. MLM backs up automatically at launch, at most once a day.")
                    .font(MLMFont.body)
                    .foregroundStyle(Color.mlmInkSecondary)
            } else {
                ForEach(viewModel.backups, id: \.url) { info in
                    backupRow(info)
                }
            }
        }
    }

    private func backupRow(_ info: BackupInfo) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(BackupSettingsViewModel.formatDate(info.createdAt))
                    .font(MLMFont.body)
                Text(viewModel.detailLine(for: info))
                    .font(MLMFont.muted)
                    .foregroundStyle(Color.mlmInkSecondary)
                if !info.isComplete {
                    Label("Incomplete — can't be restored", systemImage: "exclamationmark.circle")
                        .font(MLMFont.muted)
                        .foregroundStyle(Color.mlmAttention)
                }
            }
            Spacer()
            if info.isComplete {
                Button("Restore…") {
                    pendingRestore = info
                }
            }
            Button("Show in Finder") {
                showInFinder(info.url)
            }
        }
        .help(info.schemaVersion.map { "Database version: \($0)" } ?? "")
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            HStack(spacing: 8) {
                Button("Back up now") {
                    Task { await viewModel.backUpNow() }
                }
                if viewModel.phase == .backingUp {
                    ProgressView()
                        .controlSize(.small)
                    Text("Backing up…")
                        .font(MLMFont.muted)
                        .foregroundStyle(Color.mlmInkSecondary)
                } else if let result = viewModel.lastResult {
                    Label(result, systemImage: "checkmark.circle")
                        .font(MLMFont.muted)
                        .foregroundStyle(Color.mlmSuccess)
                }
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("The 10 most recent backups are kept. MLM also backs up at launch (at most once a day) and before updating the library database.")
                .font(MLMFont.muted)
                .foregroundStyle(Color.mlmInkSecondary)
        }
    }

    // MARK: - Pieces

    private func errorLine(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(MLMFont.body)
                .foregroundStyle(Color.mlmError)
            if let details = viewModel.errorDetails {
                DisclosureGroup("Details") {
                    Text(details)
                        .font(MLMFont.dataSmall)
                        .foregroundStyle(Color.mlmInkSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(MLMFont.muted)
            }
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = viewModel.destination
        panel.prompt = "Choose folder"

        if panel.runModal() == .OK, let url = panel.url {
            Task { await viewModel.changeDestination(to: url) }
        }
    }

    private func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
