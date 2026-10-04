import SwiftUI
import AppKit

/// Settings → Storage Location: where MLM keeps its files, with sizes and `Show in Finder`.
///
/// Transparency only — moving locations happens in the Backup and Maintenance tabs.
/// All state and copy that depends on it lives in `DataLocationsViewModel`.
struct DataLocationsView: View {
    @Environment(\.container) private var container
    @State private var viewModel: DataLocationsViewModel?

    var body: some View {
        Group {
            if let viewModel {
                DataLocationsForm(viewModel: viewModel)
            } else {
                Form {
                    Section {
                        Text(DataLocationsViewModel.Copy.notLoaded)
                            .font(MLMFont.body)
                            .foregroundStyle(Color.mlmInkSecondary)
                    }
                }
                .formStyle(.grouped)
                .padding()
            }
        }
        .task(id: container.databaseManager == nil || container.backupService == nil) {
            guard viewModel == nil,
                  let manager = container.databaseManager,
                  let configRepository = container.configRepository,
                  let backupService = container.backupService else { return }
            let databasePath = manager.databasePath
            let coversDirectory = manager.playlistCoversDirectory
            let libraryFile = container.activeLibrary?.packageURL
            let transcodeCache = container.transcodeCache
            let trackRepository = container.trackRepository

            viewModel = DataLocationsViewModel(
                locations: {
                    let root = (try? await configRepository.getLibraryRoot()).flatMap { $0 }
                    return DataLocations(
                        database: databasePath,
                        playlistCovers: coversDirectory,
                        credentialsFile: CredentialsLoader.envFilePath,
                        transcodeCache: transcodeCache?.cacheDir,
                        libraryFolder: root.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) },
                        libraryFile: libraryFile
                    )
                },
                backupStatus: {
                    let destination = await backupService.destinationDirectory()
                    let backups = (try? await backupService.listBackups()) ?? []
                    return BackupStatus(
                        destination: destination,
                        count: backups.count,
                        lastBackupDate: backups.first(where: \.isComplete)?.createdAt
                    )
                },
                countTracks: {
                    try? await trackRepository?.countLocalTracks()
                },
                sizeStore: .config(configRepository)
            )
        }
    }
}

private struct DataLocationsForm: View {
    let viewModel: DataLocationsViewModel

    var body: some View {
        Form {
            Section("Library data") {
                if viewModel.showsLibraryFile {
                    locationRow("Library file", .libraryFile, detail: viewModel.libraryFileDetail)
                }
                locationRow("Database", .database, detail: viewModel.databaseDetail)
                    .help(DataLocationsViewModel.Copy.recentChangesHelp)
                locationRow("Playlist covers", .playlistCovers, detail: viewModel.playlistCoversDetail)
                locationRow(
                    "Backups", .backups,
                    detail: viewModel.backupsDetail,
                    hint: DataLocationsViewModel.Copy.backupHint
                )
                LabeledContent("Last backup", value: viewModel.lastBackupText)
                locationRow("Credentials file", .credentialsFile, detail: viewModel.credentialsDetail)
            }

            Section("Music") {
                libraryFolderRow
                locationRow(
                    "Transcode cache", .transcodeCache,
                    detail: viewModel.transcodeCacheDetail,
                    hint: DataLocationsViewModel.Copy.transcodeHint
                )
            }

            Section {
                LabeledContent("Sign-in tokens", value: DataLocationsViewModel.Copy.storedInKeychain)
            } header: {
                Text("Sign-in")
            } footer: {
                Text(DataLocationsViewModel.Copy.footer)
                    .font(MLMFont.muted)
                    .foregroundStyle(Color.mlmInkSecondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await viewModel.refresh()
        }
    }

    // MARK: - Rows

    private func locationRow(
        _ label: String,
        _ location: DataLocationsViewModel.Location,
        detail: String?,
        hint: String? = nil
    ) -> some View {
        let row = viewModel.row(location)
        return LabeledContent(label) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    pathText(row.url)
                    stateLine(row.state)
                    if let detail {
                        mutedText(detail)
                    }
                    if let hint {
                        Text(hint)
                            .font(MLMFont.muted)
                            .foregroundStyle(Color.mlmInkMuted)
                    }
                }
                showInFinderButton(row)
            }
        }
    }

    private var libraryFolderRow: some View {
        let row = viewModel.row(.libraryFolder)
        return LabeledContent("Library folder") {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    pathText(row.url)
                    stateLine(row.state)
                    if let tracks = viewModel.trackCountText {
                        mutedText(tracks)
                    }
                    if row.state != .notSet {
                        mutedText(viewModel.librarySizeText)
                    }
                    librarySizeControls
                }
                if row.state != .notSet {
                    showInFinderButton(row)
                }
            }
        }
    }

    @ViewBuilder
    private var librarySizeControls: some View {
        if viewModel.isCalculatingLibrarySize {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                mutedText(DataLocationsViewModel.Copy.calculating)
                Button("Cancel") {
                    viewModel.cancelLibrarySizeCalculation()
                }
            }
        } else if viewModel.row(.libraryFolder).state != .notSet {
            Button("Calculate size") {
                Task { await viewModel.calculateLibrarySize() }
            }
            .disabled(!viewModel.canCalculateLibrarySize)
        }
        if let message = viewModel.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(MLMFont.muted)
                .foregroundStyle(Color.mlmError)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func pathText(_ url: URL?) -> some View {
        if let url {
            Text(url.path)
                .font(MLMFont.data)
                .foregroundStyle(Color.mlmInkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func stateLine(_ state: DataLocationsViewModel.LocationState) -> some View {
        if let text = DataLocationsViewModel.stateText(state),
           let symbol = DataLocationsViewModel.stateSymbol(state) {
            Label(text, systemImage: symbol)
                .font(MLMFont.muted)
                .foregroundStyle(Color.mlmInkSecondary)
        }
    }

    private func mutedText(_ text: String) -> some View {
        Text(text)
            .font(MLMFont.muted)
            .foregroundStyle(Color.mlmInkSecondary)
    }

    private func showInFinderButton(_ row: DataLocationsViewModel.LocationRow) -> some View {
        Button("Show in Finder") {
            if let url = row.url {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .disabled(!row.canShowInFinder)
    }
}
