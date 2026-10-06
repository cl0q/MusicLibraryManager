import Charts
import SwiftUI

/// Settings ▸ Storage Location (ST-STORAGE, DEC-035): where MLM keeps things, how big, reachable
/// or not — grouped by what moves with the library file, what lives with the music and what stays
/// on this Mac, with one small sizes chart (UC-KIT allows Swift Charts). Transparency only:
/// nothing is moved here; each hint links to the tab that changes it.
///
/// Without a library the per-library groups are dimmed and the rows for this Mac stay usable.
/// All state and copy that depends on it lives in `DataLocationsViewModel`.
struct DataLocationsView: View {
    @Environment(\.container) private var container
    @State private var viewModel: DataLocationsViewModel?

    var body: some View {
        Group {
            if let viewModel {
                DataLocationsForm(viewModel: viewModel, hasLibrary: container.isInitialized)
            } else {
                Form {}.formStyle(.grouped)
            }
        }
        .task(id: container.isInitialized) { makeViewModel() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDriveDidMount)) { _ in
            Task { await viewModel?.refresh() }
        }
    }

    private func makeViewModel() {
        let manager = container.databaseManager
        let configRepository = container.configRepository
        let backupService = container.backupService
        let databasePath = manager?.databasePath
        let coversDirectory = manager?.playlistCoversDirectory
        let libraryFile = container.activeLibrary?.packageURL
        let transcodeCache = container.transcodeCache
        let trackRepository = container.trackRepository
        let artworkCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mlm.artwork_cache")
        let appSupport = DatabaseManager.legacyDatabaseURL.deletingLastPathComponent()

        viewModel = DataLocationsViewModel(
            locations: {
                let root = (try? await configRepository?.getLibraryRoot()).flatMap { $0 }
                let previous = ((try? FileManager.default.contentsOfDirectory(
                    at: appSupport, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix("legacy-adopted-") }
                return DataLocations(
                    database: databasePath,
                    playlistCovers: coversDirectory,
                    credentialsFile: CredentialsLoader.envFilePath,
                    transcodeCache: transcodeCache?.cacheDir,
                    libraryFolder: root.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) },
                    libraryFile: libraryFile,
                    libraryList: LibraryRegistryStore.defaultFileURL,
                    caches: [artworkCache, ActiveLibrary.defaultWaveformCacheRoot],
                    pathMigrations: OrganizedPathMigrationService.defaultArtifactsDirectory(),
                    logFile: AppLogger.shared.logFileURL,
                    previousInstalls: previous
                )
            },
            backupStatus: {
                guard let backupService else { return BackupStatus(destination: nil, count: 0, lastBackupDate: nil) }
                let destination = await backupService.destinationDirectory()
                let backups = (try? await backupService.listBackups()) ?? []
                return BackupStatus(destination: destination, count: backups.count,
                                    lastBackupDate: backups.first(where: \.isComplete)?.createdAt)
            },
            countTracks: { try? await trackRepository?.countLocalTracks() },
            sizeStore: configRepository.map { .config($0) }
                ?? LibrarySizeStore(load: { nil }, save: { _ in })
        )
    }
}

private struct DataLocationsForm: View {
    let viewModel: DataLocationsViewModel
    let hasLibrary: Bool

    var body: some View {
        Form {
            chartSection
            libraryFileSection
                .disabled(!hasLibrary)
            libraryFolderSection
                .disabled(!hasLibrary)
            macSection
        }
        .formStyle(.grouped)
        .task { await viewModel.refresh() }
    }

    // MARK: Chart

    private var chartSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.m) {
                bar(title: "On this Mac", trailing: DataLocationsViewModel.formatBytes(viewModel.macTotalBytes),
                    segments: viewModel.macSegments)
                if hasLibrary, viewModel.row(.libraryFolder).url != nil {
                    if viewModel.row(.libraryFolder).state == .notConnected {
                        HStack {
                            Text(viewModel.driveTitle).fontWeight(.medium)
                            Spacer()
                            Text("Not connected").foregroundStyle(.secondary)
                        }
                    } else if !viewModel.driveSegments.isEmpty {
                        bar(title: viewModel.driveTitle, trailing: viewModel.driveCapacityText ?? "",
                            segments: viewModel.driveSegments)
                    }
                }
            }
            .padding(.vertical, Spacing.xs)
        }
    }

    private func bar(title: String, trailing: String, segments: [StorageSegment]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Text(trailing).foregroundStyle(.secondary).monospacedDigit()
            }
            if segments.isEmpty {
                Text("Nothing measured yet").font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(segments) { segment in
                    BarMark(x: .value("Size", segment.bytes), y: .value("Where", title))
                        .foregroundStyle(by: .value("Kind", "\(segment.name) \(DataLocationsViewModel.formatBytes(segment.bytes))"))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(position: .bottom, alignment: .leading, spacing: Spacing.xs)
                .frame(height: 56)
                .accessibilityLabel("\(title): " + segments.map { "\($0.name) \(DataLocationsViewModel.formatBytes($0.bytes))" }.joined(separator: ", "))
            }
        }
    }

    // MARK: In this library file

    private var libraryFileSection: some View {
        Section {
            if viewModel.showsLibraryFile {
                row(.libraryFile, title: "Library file", size: viewModel.libraryFileDetail)
            }
            LabeledContent {
                sizeText(viewModel.row(.database).sizeBytes)
            } label: {
                SettingsRowLabel("Database") {
                    Text(databaseLine)
                }
            }
            .help(DataLocationsViewModel.Copy.recentChangesHelp)
            LabeledContent {
                sizeText(viewModel.row(.playlistCovers).sizeBytes)
            } label: {
                SettingsRowLabel("Playlist covers") {
                    Text(coversLine)
                }
            }
        } header: {
            header("In this library file", "Moves with the file")
        }
    }

    private var databaseLine: String {
        guard let file = viewModel.databaseFileBytes else { return "Inside the library file" }
        return "Inside the library file · database file \(DataLocationsViewModel.formatBytes(file)) · recent changes \(DataLocationsViewModel.formatBytes(viewModel.walBytes ?? 0))"
    }

    private var coversLine: String {
        let count = viewModel.row(.playlistCovers).itemCount ?? 0
        return "Inside the library file · " + DataLocationsViewModel.countText(count, singular: "file", plural: "files")
    }

    // MARK: Library folder

    private var libraryFolderSection: some View {
        Section {
            let folder = viewModel.row(.libraryFolder)
            LabeledContent {
                HStack {
                    Button("Calculate Size") { Task { await viewModel.calculateLibrarySize() } }
                        .disabled(!viewModel.canCalculateLibrarySize)
                    ShowInFinderButton(url: folder.url, disabledReason: reason(folder.state))
                }
            } label: {
                SettingsRowLabel("Library folder") {
                    if let url = folder.url { SettingsPath(url) }
                    if folder.state != .available, let text = DataLocationsViewModel.stateText(folder.state) {
                        SettingsState(text: text, systemImage: DataLocationsViewModel.stateSymbol(folder.state), tone: .problem)
                    }
                    HStack(spacing: 4) {
                        if let tracks = viewModel.trackCountText { Text("\(tracks) ·") }
                        if viewModel.isCalculatingLibrarySize {
                            ProgressView().controlSize(.small)
                            Text(DataLocationsViewModel.Copy.calculating)
                            Button("Cancel") { viewModel.cancelLibrarySizeCalculation() }.buttonStyle(.link)
                        } else if let error = viewModel.errorMessage {
                            Text(error)
                        } else {
                            Text(viewModel.librarySizeText)
                        }
                    }
                    Button("Change the library folder in Library") { SettingsRouter.shared.select(.library) }
                        .buttonStyle(.link)
                }
            }
            let cache = viewModel.row(.transcodeCache)
            LabeledContent {
                HStack {
                    sizeText(cache.sizeBytes)
                    ShowInFinderButton(url: cache.url, disabledReason: reason(cache.state))
                }
            } label: {
                SettingsRowLabel("Transcode cache") {
                    if let url = cache.url { SettingsPath(url) }
                    if cache.state != .available, let text = DataLocationsViewModel.stateText(cache.state) {
                        SettingsState(text: text, systemImage: DataLocationsViewModel.stateSymbol(cache.state), tone: .problem)
                    }
                    Button("Change the location or clear it in Maintenance") { SettingsRouter.shared.select(.maintenance) }
                        .buttonStyle(.link)
                }
            }
        } header: {
            header("Library folder", "This library")
        }
    }

    // MARK: On this Mac

    private var macSection: some View {
        Section {
            let backups = viewModel.row(.backups)
            LabeledContent {
                HStack {
                    sizeText(backups.sizeBytes)
                    ShowInFinderButton(url: backups.url, disabledReason: reason(backups.state))
                }
            } label: {
                SettingsRowLabel("Backups") {
                    if let url = backups.url { SettingsPath(url) }
                    Text("\(DataLocationsViewModel.countText(viewModel.backupCount, singular: "backup", plural: "backups")) · last backup \(viewModel.lastBackupDate.map { SettingsDate.text($0) } ?? "never")")
                    Button("Change the backup folder in Backup") { SettingsRouter.shared.select(.backup) }
                        .buttonStyle(.link)
                }
            }
            .disabled(!hasLibrary)
            row(.libraryList, title: "List of libraries", tag: "All libraries")
            row(.credentialsFile, title: "Credentials file", tag: "All libraries", size: viewModel.credentialsDetail,
                notFoundText: "Not found")
            LabeledContent {
                EmptyView()
            } label: {
                SettingsRowLabel("Sign-in tokens") { Text(DataLocationsViewModel.Copy.storedInKeychain) }
            }
            row(.caches, title: "Artwork and waveform caches", tag: "Can be rebuilt")
            row(.pathMigrations, title: "Path migration backups")
            row(.logs, title: "Logs")
            ForEach(viewModel.previousInstalls, id: \.url) { previous in
                LabeledContent {
                    HStack {
                        sizeText(previous.sizeBytes)
                        ShowInFinderButton(url: previous.url)
                    }
                } label: {
                    SettingsRowLabel("Previous install") {
                        if let url = previous.url { SettingsPath(url) }
                        Text("Kept after library file setup until you delete it. Can be deleted.")
                    }
                }
            }
        } header: {
            header("On this Mac", "Stays when a library file is moved")
        } footer: {
            Text("\(DataLocationsViewModel.Copy.footer) \(DataLocationsViewModel.Copy.refreshNote)")
        }
    }

    // MARK: Pieces

    private func header(_ title: String, _ tag: String) -> some View {
        HStack {
            Text(title)
            Text(tag).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ location: DataLocationsViewModel.Location, title: String, tag: String? = nil,
                     size: String? = nil, notFoundText: String? = nil) -> some View {
        let row = viewModel.row(location)
        return LabeledContent {
            HStack {
                if let size { Text(size).foregroundStyle(.secondary).monospacedDigit() } else { sizeText(row.sizeBytes) }
                ShowInFinderButton(url: row.url, disabledReason: reason(row.state))
            }
        } label: {
            SettingsRowLabel(tag.map { "\(title) — \($0)" } ?? title) {
                if let url = row.url { SettingsPath(url) }
                if row.state != .available, let text = notFoundText ?? DataLocationsViewModel.stateText(row.state) {
                    Text(text)
                }
            }
        }
    }

    private func sizeText(_ bytes: Int64?) -> some View {
        Text(bytes.map(DataLocationsViewModel.formatBytes) ?? "")
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private func reason(_ state: DataLocationsViewModel.LocationState) -> String? {
        state == .available ? nil : DataLocationsViewModel.stateText(state)
    }
}
