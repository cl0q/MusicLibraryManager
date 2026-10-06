import AppKit
import SwiftUI

/// A library that couldn't be opened (V-LAUNCH-FAILED, DEC-031; fixes PP-SHELL-12 —
/// `Failed to Initialize` with the raw error as the only content): the sentence names the
/// library and what is safe, the raw text is behind `Details`, and there are ways out —
/// `Try Again`, `Choose Another Library`, `Restore from Backup…` (only when this library has
/// backups), `Show Logs` (UC-COPY-11, UC-EMPTY-05).
struct LibraryLaunchFailureView: View {
    let failure: LaunchFailure
    let launch: LibraryLaunchCoordinator

    @State private var isRestoring = false

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: "exclamationmark.triangle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.orange, .primary)
        } description: {
            Text(failure.message)
        } actions: {
            VStack(spacing: Spacing.m) {
                HStack(spacing: Spacing.s) {
                    Button("Try Again") { Task { await launch.retryFailedOpen() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    if failure.offersChooseAnother {
                        Button("Choose Another Library") { launch.chooseAnotherLibrary() }
                    }
                    if launch.restore != nil {
                        Button("Restore from Backup…") { isRestoring = true }
                    }
                    Button("Show Logs") { LaunchLogs.show() }
                }
                .controlSize(.large)
                DetailsDisclosure(text: failure.details)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: failure) { await launch.loadRestoreOptions() }
        .sheet(isPresented: $isRestoring) {
            if let restore = launch.restore {
                LaunchRestoreSheet(model: restore)
            }
        }
    }
}

/// A file that can't be a library (V-LAUNCH-INVALID): the cause in plain words, never added
/// to the list. `Choose Another Library` (was `OK`) and `Show in Finder`.
struct InvalidLibraryFileView: View {
    let file: InvalidLibraryFile
    let launch: LibraryLaunchCoordinator

    var body: some View {
        ContentUnavailableView {
            Label(file.title, systemImage: "exclamationmark.triangle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.orange, .primary)
        } description: {
            Text(file.message)
        } actions: {
            VStack(spacing: Spacing.m) {
                HStack(spacing: Spacing.s) {
                    Button("Choose Another Library") { launch.chooseAnotherLibrary() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                        .disabled(!FileManager.default.fileExists(atPath: file.url.path))
                }
                .controlSize(.large)
                DetailsDisclosure(text: file.details)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `Details` with the raw text, selectable (UC-COPY-11).
struct DetailsDisclosure: View {
    let text: String

    var body: some View {
        DisclosureGroup("Details") {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .frame(maxWidth: 520)
    }
}

/// `Show Logs`: the Activity window on Logs (available in every launch state, UC-JOB-06).
enum LaunchLogs {
    @MainActor
    static func show() {
        ActivityRouter.shared.showLogs(for: nil)
        ActivityRouter.shared.requestWindow(tab: .logs)
    }
}

/// Restore the library that failed to open from one of its backups (S-LAUNCH-RESTORE). The
/// restore is the existing one: a consequence-stating alert with Cancel as the default, a
/// `Before restore` backup first, then the relaunch into the restored library.
struct LaunchRestoreSheet: View {
    let model: LaunchRestoreModel

    @Environment(\.dismiss) private var dismiss
    @State private var selection: URL?
    @State private var confirming: BackupInfo?

    private var selected: BackupInfo? { model.restorable.first { $0.url == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Restore “\(model.libraryName)” from a backup")
                .font(.headline)
            Text("MLM first saves the current library as a “Before restore” backup, then replaces it with the backup you choose and relaunches. Audio files are not changed.")
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Backup", selection: $selection) {
                    ForEach(model.restorable, id: \.url) { info in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LaunchRestoreModel.dateText(info))
                            Text(model.detailText(info))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(info.url))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            .formStyle(.grouped)
            .frame(minHeight: 160)
            if let error = model.backups.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.orange, .primary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.backups.isBusy {
                    ProgressView().controlSize(.small)
                    Text("Restoring…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.backups.isBusy)
                Button("Restore and Open…") { confirming = selected }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || model.backups.isBusy)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 480)
        .interactiveDismissDisabled(model.backups.isBusy)
        .onAppear { selection = model.restorable.first?.url }
        .alert(
            confirming.map { "Restore “\(model.libraryName)” from \(LaunchRestoreModel.dateText($0))?" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { info in
            Button("Restore and Relaunch", role: .destructive) {
                Task { await model.restore(info) }
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { _ in
            Text("MLM first saves a copy of the current library, then replaces the library database and playlist covers with this backup and relaunches. Audio files are not changed. To undo, restore the “Before restore” backup.")
        }
        .alert(
            BackupSettingsViewModel.Copy.relaunchRequiredTitle,
            isPresented: Binding(get: { model.backups.isRelaunchRequired }, set: { _ in })
        ) {
            Button("Relaunch") { model.backups.acknowledgeRelaunchRequired() }
        } message: {
            Text(BackupSettingsViewModel.Copy.relaunchRequired)
        }
    }
}
