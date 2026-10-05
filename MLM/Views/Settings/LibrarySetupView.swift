import SwiftUI

/// Settings view for library root configuration and folder management.
///
/// Allows the user to:
/// - View and change the library root folder
/// - See library statistics (track count, disk usage)
/// - Re-scan/re-import the library
/// - View scan folders
///
/// Part of Phase 4 (Import & Metadata). Inserted into the Settings
/// window and also accessible from the main Settings section.
struct LibrarySetupView: View {
    @Environment(\.container) private var container
    @State private var viewModel: ImportViewModel?
    @State private var trackCount: Int = 0
    @State private var libraryRoot: String?
    @State private var isLoaded = false
    /// `Write tags to files` (W2-E; THOUGHTS §10 Q7: on by default). Per library.
    @State private var writesTags = true

    var body: some View {
        Form {
            // MARK: - Library File Section (A3)
            if let package = container.activeLibrary?.packageURL {
                // `Open the last library at launch` moved to Settings ▸ General (W1-2, ST-LIB.E04).
                Section {
                    libraryFileRow(package)
                } header: {
                    Label("Library file", systemImage: "opticaldisc")
                }
            }

            // MARK: - Library Root Section
            Section {
                libraryRootRow
            } header: {
                Label("Library Root", systemImage: "folder.fill")
            } footer: {
                Text("The root folder containing your music files. MLM will scan this folder recursively for audio files.")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
            }

            // MARK: - Tags (W2-E; restyled with the pane by W3-SET)
            Section {
                Toggle("Write tags to files", isOn: Binding(
                    get: { writesTags },
                    set: { setWritesTags($0) }
                ))
                .disabled(container.configRepository == nil)
            } footer: {
                Text("Tag edits also go into the audio files, so copies outside MLM show them. A track’s source is never written.")
            }

            // MARK: - Statistics Section
            if libraryRoot != nil {
                Section {
                    statisticsView
                } header: {
                    Label("Statistics", systemImage: "chart.bar")
                }
            }

            Section {
                storageLayoutView
            } header: {
                Label("Storage layout", systemImage: "folder.badge.gearshape")
            }

            // MARK: - Import Section
            if libraryRoot != nil {
                Section {
                    importSection
                } header: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }

            // MARK: - Supported Formats
            Section {
                supportedFormatsView
            } header: {
                Label("Supported Formats", systemImage: "waveform")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            setupViewModel()
            loadState()
        }
    }

    // MARK: - Library Root Row

    /// Library name, path of the library file and `Show in Finder`.
    private func libraryFileRow(_ package: URL) -> some View {
        LabeledContent(LibraryLaunchCoordinator.shared.activeLibraryName
                       ?? package.deletingPathExtension().lastPathComponent) {
            HStack(spacing: 8) {
                Text(package.path)
                    .font(MLMFont.data)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([package])
                }
            }
        }
    }

    private var libraryRootRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let root = libraryRoot {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.mlmAccent)
                    Text(root)
                        .font(MLMFont.data)
                        .foregroundColor(.mlmInk)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Change...") {
                        selectFolder()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                HStack {
                    Text("No library folder selected")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkMuted)

                    Spacer()

                    Button("Select Folder...") {
                        selectFolder()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.mlmAccent)
                }
            }
        }
    }

    // MARK: - Statistics

    private var storageLayoutView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MLM creates these folders inside your library when they are needed:")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
            storageLayoutRow(ManagedLibraryLayout.soundCloudDownloads, "Music downloaded from SoundCloud.")
            storageLayoutRow(ManagedLibraryLayout.youtubeDownloads, "Music downloaded from YouTube and fallback sources.")
            storageLayoutRow(ManagedLibraryLayout.transcodeOriginals, "Original files retained while MLM creates a transcode.")
        }
    }

    private func storageLayoutRow(_ name: String, _ purpose: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(MLMFont.mono)
            Text(purpose).font(MLMFont.muted).foregroundColor(.mlmInkMuted)
        }
    }

    private var statisticsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tracks in library")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkSecondary)
                Spacer()
                Text("\(trackCount)")
                    .font(MLMFont.data)
                    .foregroundColor(.mlmInk)
            }

            if let root = libraryRoot {
                HStack {
                    Text("Library path")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkSecondary)
                    Spacer()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)])
                    } label: {
                        Label("Show in Finder", systemImage: "arrow.right.circle")
                            .font(MLMFont.muted)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.mlmAccent)
                }
            }
        }
    }

    // MARK: - Import Section

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let vm = viewModel, vm.isImporting {
                // Import in progress
                VStack(alignment: .leading, spacing: 8) {
                    if let progress = vm.progress {
                        ProgressView(value: progress.fraction) {
                            Text(progress.phase)
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkSecondary)
                        }
                        .tint(.mlmAccent)

                        if progress.total > 0 {
                            Text("\(progress.processed) / \(progress.total) files")
                                .font(MLMFont.dataSmall)
                                .foregroundColor(.mlmInkMuted)
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }

                    HStack {
                        Spacer()
                        Button {
                            vm.cancelImport()
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .tint(.mlmError)
                    }
                }
            } else {
                // Import actions
                HStack {
                    Button {
                        Task { await rescanLibrary() }
                    } label: {
                        Label("Re-scan Library", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        importFromFolder()
                    } label: {
                        Label("Import Folder...", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.bordered)
                }

                // Last import result
                if let result = viewModel?.lastResult {
                    HStack(spacing: 12) {
                        Label("\(result.succeeded) imported", systemImage: "checkmark.circle")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmSuccess)

                        if result.skipped > 0 {
                            Label("\(result.skipped) skipped", systemImage: "arrow.right.circle")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkMuted)
                        }

                        if result.failed > 0 {
                            Label("\(result.failed) failed", systemImage: "exclamationmark.triangle")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmWarning)
                        }
                    }
                }

                if let error = viewModel?.errorMessage {
                    Text(error)
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmError)
                }
            }
        }
    }

    // MARK: - Supported Formats

    private var supportedFormatsView: some View {
        let formats = ["MP3", "FLAC", "AAC", "M4A", "OGG", "WAV", "AIFF", "ALAC"]
        return LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 60))
        ], spacing: 6) {
            ForEach(formats, id: \.self) { format in
                Text(format)
                    .font(MLMFont.badge)
                    .foregroundColor(.mlmInkSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.mlmRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    // MARK: - Actions

    private func setupViewModel() {
        guard viewModel == nil,
              let importService = container.importService,
              let configRepo = container.configRepository else { return }
        viewModel = ImportViewModel(
            importService: importService,
            configRepository: configRepo,
            activityViewModel: container.activityViewModel
        )
    }

    private func setWritesTags(_ enabled: Bool) {
        writesTags = enabled
        guard let config = container.configRepository else { return }
        Task {
            try? await TagWriteSetting.setEnabled(enabled, config: config)
            // Waiting changes are written once it is on again (nothing is written while off).
            if enabled { TagWriteQueue.shared.requestFlush() }
        }
    }

    private func loadState() {
        Task {
            writesTags = await TagWriteSetting.isEnabled(container.configRepository)
            await viewModel?.loadLibraryRoot()
            libraryRoot = viewModel?.libraryRoot

            if let trackRepo = container.trackRepository {
                trackCount = (try? await trackRepo.countLocalTracks()) ?? 0
            }

            isLoaded = true
        }
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Music Library Folder"
        panel.message = "Choose the root folder of your music library"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await viewModel?.setLibraryRoot(url.path)
                libraryRoot = url.path
            }
        }
    }

    private func rescanLibrary() async {
        await viewModel?.importLibrary()
        // Refresh track count after import
        if let trackRepo = container.trackRepository {
            trackCount = (try? await trackRepo.countLocalTracks()) ?? 0
        }
    }

    private func importFromFolder() {
        let panel = NSOpenPanel()
        panel.title = "Import Audio Files"
        panel.message = "Choose a folder to import audio files from"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await viewModel?.importFromDirectory(url)
                if let trackRepo = container.trackRepository {
                    trackCount = (try? await trackRepo.countLocalTracks()) ?? 0
                }
            }
        }
    }
}
