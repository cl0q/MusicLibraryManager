import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Library (ST-LIB, DEC-035, F-19): which library file is open, where the music is,
/// importing, and whether tag edits are written to files. Everything here belongs to the open
/// library (dimmed with the UC-WIN-05 line when none is open).
///
/// - `Rename…` (S-SET-RENAMELIB) renames the library file, its manifest and its list entry
///   together and relaunches into it (`LibraryRename`); refused while work runs.
/// - `Change…` (S-SET-LIBFOLDER) first states the consequences and checks the chosen folder;
///   nothing is saved until `Change Folder`. A folder dropped on the row starts the same sheet.
/// - The drive state is said in words (PP-SETTINGS-06).
struct LibrarySetupView: View {
    @Environment(\.container) private var container
    @State private var viewModel: ImportViewModel?
    @State private var libraryRoot: String?
    @State private var totalTracks: Int?
    @State private var tracksWithFile: Int?
    @State private var reach: LocationReach = .notSet
    /// `Write tags to files` (W2-E). Per library; off unless turned on (fails closed).
    @State private var writesTags = false
    @State private var showsRename = false
    @State private var folderSheet: FolderChange?
    @State private var choosesImport = false

    private var activity: ActivityCenter { .shared }

    var body: some View {
        Form {
            libraryFileSection
            libraryFolderSection
            managedFoldersSection
            importSection
            tagsSection
        }
        .formStyle(.grouped)
        .task(id: container.isInitialized) {
            setupViewModel()
            await loadState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryRootDidChange)) { _ in
            Task { await loadState() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDriveDidMount)) { _ in
            Task { await loadState() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDriveDidUnmount)) { _ in
            Task { await loadState() }
        }
        .sheet(isPresented: $showsRename) {
            RenameLibrarySheet()
        }
        .sheet(item: $folderSheet) { change in
            LibraryFolderSheet(currentRoot: libraryRoot, tracksWithFile: tracksWithFile ?? 0,
                               initialFolder: change.initialFolder) { folder, scan in
                Task {
                    await viewModel?.changeLibraryFolder(to: folder, scanAfterwards: scan)
                    await loadState()
                }
            }
        }
        .fileImporter(isPresented: $choosesImport, allowedContentTypes: [.folder, .audio],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            importChosen(urls)
        }
        .fileDialogMessage("Choose audio files or a folder to import.")
    }

    /// The folder sheet is an item so a dropped folder can start it preselected.
    private struct FolderChange: Identifiable {
        let id = UUID()
        let initialFolder: URL?
    }

    // MARK: Library file

    @ViewBuilder
    private var libraryFileSection: some View {
        if let package = container.activeLibrary?.packageURL {
            Section("Library file") {
                LabeledContent {
                    HStack {
                        ShowInFinderButton(url: package)
                        Button("Rename…") { showsRename = true }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LibraryLaunchCoordinator.shared.activeLibraryName
                             ?? package.deletingPathExtension().lastPathComponent)
                        SettingsPath(package)
                    }
                }
                LabeledContent {
                    Button("Choose Library…") { MainWindowPresenter.shared.show() }
                } label: {
                    Text("Open or create another library").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Library folder

    private var libraryFolderSection: some View {
        Section {
            LabeledContent {
                HStack {
                    ShowInFinderButton(url: libraryRoot.map { URL(fileURLWithPath: $0) },
                                       disabledReason: reach.isReachable ? nil : reach.text)
                    Button(libraryRoot == nil ? "Choose…" : "Change…") {
                        folderSheet = FolderChange(initialFolder: nil)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if let libraryRoot { SettingsPath(libraryRoot) }
                    Group {
                        switch reach {
                        case .notConnected:
                            HStack(spacing: 4) {
                                SettingsState(reach: reach)
                                Text("· playback and file actions are paused")
                            }
                        default:
                            SettingsState(reach: reach)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .acceptsFolderDrop { url in folderSheet = FolderChange(initialFolder: url) }
            if libraryRoot != nil {
                LabeledContent("Tracks") {
                    Text(trackLine).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } header: {
            Text("Library folder")
        } footer: {
            Text("The folder that contains your music files. MLM scans it and its subfolders for audio files. Track locations are stored relative to this folder.")
        }
    }

    /// `12,935 in the library · 8,902 with a file in this folder`.
    private var trackLine: String {
        guard let totalTracks, let tracksWithFile else { return "" }
        return "\(totalTracks.formatted()) in the library · \(tracksWithFile.formatted()) with a file in this folder"
    }

    // MARK: Managed folders

    private var managedFoldersSection: some View {
        Section("Folders MLM creates inside the library folder") {
            managedRow(ManagedLibraryLayout.soundCloudDownloads, "Music downloaded from SoundCloud.")
            managedRow(ManagedLibraryLayout.youtubeDownloads, "Music downloaded from YouTube and fallback sources.")
            managedRow(ManagedLibraryLayout.transcodeOriginals, "Original files kept while MLM creates a transcode.")
        }
    }

    private func managedRow(_ name: String, _ purpose: String) -> some View {
        LabeledContent {
            Text("Managed by MLM").font(.caption).foregroundStyle(.secondary)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                SettingsPath(name)
                Text(purpose).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Import

    private var scanEcho: ActivityEcho? {
        libraryRoot.flatMap { activity.echo(for: .folder(URL(fileURLWithPath: $0))) }
    }

    private var importSection: some View {
        Section("Import") {
            if let echo = scanEcho, echo.state.isActive {
                LabeledContent {
                    Button("Cancel") { activity.cancel(echo.operationID) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(echo.toolbarText)
                        if let fraction = echo.fraction {
                            ProgressView(value: fraction).frame(maxWidth: 340)
                        }
                        Button("Show in Activity") { ActivityWindowOpener.open() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            } else {
                LabeledContent {
                    HStack {
                        Button("Scan Library Folder") { Task { await viewModel?.importLibrary() } }
                            .disabled(!reach.isReachable || viewModel == nil)
                        Button("Import Files or Folder…") { choosesImport = true }
                            .disabled(viewModel == nil)
                    }
                } label: {
                    SettingsRowLabel("Scan the library folder for new files") {
                        if let last = lastScan {
                            HStack(spacing: 4) {
                                if last.failedCount > 0 {
                                    SettingsState(text: last.text, systemImage: "exclamationmark.triangle", tone: .error)
                                } else {
                                    Text(last.text)
                                }
                                Text("·")
                                Button(last.failedCount > 0 ? "Show failed files" : "Show") { ActivityWindowOpener.open() }
                                    .buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            if case .notConnected(let volume) = reach {
                Label("Can’t scan — “\(volume)” is not connected.", systemImage: "externaldrive.badge.xmark")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Supported formats") {
                Text("MP3 · FLAC · AAC · M4A · OGG · WAV · AIFF · ALAC").foregroundStyle(.secondary)
            }
        }
    }

    /// `Last scan 28 Sep 2026 — 212 imported · 8,690 already in the library` (ST-LIB.E14/E15).
    private var lastScan: (text: String, failedCount: Int)? {
        guard let root = libraryRoot else { return nil }
        let path = URL(fileURLWithPath: root).path
        guard let op = activity.finishedOperations.first(where: { $0.kind == .folderScan && $0.subject.detail == path })
        else { return nil }
        let date = (op.endedAt ?? op.startedAt).formatted(date: .abbreviated, time: .omitted)
        let failed = op.result?.counts.first(where: { $0.outcome == .failed })?.count ?? 0
        return ("Last scan \(date) — \(ActivityPresentation.resultText(op) ?? op.state.word)", failed)
    }

    // MARK: Tags

    private var tagsSection: some View {
        Section("Tags") {
            Toggle(isOn: Binding(get: { writesTags }, set: { setWritesTags($0) })) {
                Text("Write tags to files")
                Text("Tag edits in Info are also written into the audio files. Files with tag data MLM can’t keep intact (such as DJ cue points) are left unchanged, and a track’s source is never written.")
            }
            .disabled(container.configRepository == nil)
        }
    }

    // MARK: Actions

    private func setupViewModel() {
        guard viewModel == nil,
              let importService = container.importService,
              let configRepo = container.configRepository else { return }
        viewModel = ImportViewModel(importService: importService, configRepository: configRepo, activity: ActivityCenter.shared)
    }

    private func setWritesTags(_ enabled: Bool) {
        writesTags = enabled
        // Off stops a running write at once (the current file finishes or is left untouched).
        if !enabled { TagWriteQueue.shared.cancel() }
        guard let config = container.configRepository else { return }
        Task {
            try? await TagWriteSetting.setEnabled(enabled, config: config)
            // Waiting changes are written once it is on again (nothing is written while off).
            if enabled { TagWriteQueue.shared.requestFlush() }
        }
    }

    private func loadState() async {
        writesTags = await TagWriteSetting.isEnabled(container.configRepository)
        await viewModel?.loadLibraryRoot()
        let root = viewModel?.libraryRoot.flatMap { $0.isEmpty ? nil : $0 }
        libraryRoot = root
        let folder = root.map { URL(fileURLWithPath: $0) }
        reach = await Task.detached {
            LocationReach.of(folder, isVolumeMounted: DataLocationsViewModel.isVolumeMounted,
                             exists: { FileManager.default.fileExists(atPath: $0.path) })
        }.value
        tracksWithFile = try? await container.trackRepository?.countLocalTracks()
        totalTracks = try? await container.databaseManager?.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks")
        }
    }

    /// `Import Files or Folder…` (S-SET-IMPORTFOLDER): the same Activity operation as the Add menu.
    private func importChosen(_ urls: [URL]) {
        guard let viewModel else { return }
        Task {
            if urls.count == 1, (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                await viewModel.importFromDirectory(urls[0])
            } else {
                await viewModel.importFiles(urls, title: "Import \(ActivityNoun.file.counted(urls.count))")
            }
            await loadState()
        }
    }
}

// MARK: - S-SET-LIBFOLDER

/// `Change the library folder?` — what changes, the chosen folder checked against the library's
/// files, and the optional scan. Nothing is saved until `Change Folder` (UC-SHEET-03).
private struct LibraryFolderSheet: View {
    let currentRoot: String?
    let tracksWithFile: Int
    let initialFolder: URL?
    let change: (URL, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container
    @State private var chosen: URL?
    @State private var choosing = false
    @State private var comparison: ImportViewModel.FolderComparison?
    @State private var comparing = false
    /// Off by default (review B2): the user opts in to adding files.
    @State private var scanAfterwards = false

    var body: some View {
        SettingsSheet(title: "Change the library folder?") {
            Section {
                Text("MLM looks for every track’s file inside the library folder. After the change it looks for the same \(tracksWithFile.formatted()) files in the new folder. No files are moved or deleted.")
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Now") {
                    if let currentRoot { SettingsPath(currentRoot) } else { Text("No library folder set").foregroundStyle(.secondary) }
                }
                LabeledContent("New") {
                    HStack {
                        if let chosen { SettingsPath(chosen) } else { Text("Not chosen").foregroundStyle(.secondary) }
                        Button("Choose…") { choosing = true }
                    }
                }
            }
            if comparing {
                Section {
                    HStack(spacing: Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text("Comparing the folder with the library…").foregroundStyle(.secondary)
                    }
                }
            } else if let comparison, let chosen {
                Section {
                    HStack(spacing: 4) {
                        SettingsState(reach: LocationReach.of(chosen, isVolumeMounted: DataLocationsViewModel.isVolumeMounted,
                                                              exists: { FileManager.default.fileExists(atPath: $0.path) }))
                        Text("· \(comparison.found.formatted()) of \(comparison.total.formatted()) files found in the new folder.")
                    }
                    if comparison.missing > 0 {
                        Text("\(comparison.missing == 1 ? "1 track" : "\(comparison.missing.formatted()) tracks") will show File missing until their files are there. You can change back at any time.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle(isOn: $scanAfterwards) {
                        Text("Scan the new folder for more files afterwards")
                        Text("Adds the folder’s files that aren’t in the library yet. A file at the same place as a library track is that track: it is only re-pointed, never added twice.")
                    }
                    .toggleStyle(.checkbox)
                }
            }
            if let refusal = runningWorkRefusal {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red, .primary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let currentRoot, !DataLocationsViewModel.isVolumeMounted(URL(fileURLWithPath: currentRoot)),
               let volume = LibraryDriveState.volumeName(fromVolumePath: MountObserver.extractVolumePath(from: currentRoot)) {
                Text("“\(volume)” is not connected, so the current folder can’t be compared.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Change Folder") {
                guard let chosen else { return }
                change(chosen, scanAfterwards)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(chosen == nil || comparison == nil || comparing || runningWorkRefusal != nil)
        }
        .frame(width: 520)
        .folderPanel(isPresented: $choosing, message: "Choose the folder that contains your music.",
                     directory: currentRoot.map { URL(fileURLWithPath: $0) }) { url in
            Task { await check(url) }
        }
        .task {
            if let initialFolder { await check(initialFolder) }
        }
    }

    /// Refused while downloads, scans, path migrations or syncs run (review S5).
    private var runningWorkRefusal: String? {
        ImportViewModel.folderChangeRefusal(operations: ActivityCenter.shared.activeOperations)
    }

    private func check(_ folder: URL) async {
        chosen = folder
        comparison = nil
        comparing = true
        let pool = container.databaseManager?.pool
        let paths = (try? await pool?.read { db in
            try String.fetchAll(db, sql: "SELECT organized_path FROM tracks WHERE organized_path IS NOT NULL")
        }) ?? []
        let oldRoot = currentRoot
        comparison = await Task.detached { ImportViewModel.compare(folder: folder, organizedPaths: paths, oldRoot: oldRoot) }.value
        comparing = false
    }
}

// MARK: - S-SET-RENAMELIB

/// `Rename library`: the library, its file and its list entry change together; MLM relaunches
/// into the renamed file. Problems appear inline above the buttons (UC-SHEET-05).
private struct RenameLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container
    @State private var name = LibraryLaunchCoordinator.shared.activeLibraryName ?? ""
    @State private var problem: LibraryRename.Problem?
    @State private var isRenaming = false

    private var currentName: String { LibraryLaunchCoordinator.shared.activeLibraryName ?? "" }
    private var package: URL? { container.activeLibrary?.packageURL }

    private var inlineProblem: LibraryRename.Problem? {
        guard let package else { return nil }
        return LibraryRename.problem(newName: name, currentName: currentName, package: package)
    }

    var body: some View {
        SettingsSheet(title: "Rename library") {
            Section {
                TextField("Name", text: $name)
                    .onChange(of: name) { _, _ in problem = nil }
                if let package {
                    Text("The library file becomes “\(LibraryRename.targetURL(for: package, newName: name).lastPathComponent)”. Its location doesn’t change. MLM relaunches to open it under the new name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Errors inline, directly above the buttons (UC-SHEET-05).
                if let shown = problem ?? visibleProblem {
                    Label(shown.message, systemImage: "exclamationmark.triangle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.red, .primary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } buttons: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Rename and Relaunch") { Task { await rename() } }
                .keyboardShortcut(.defaultAction)
                .disabled(inlineProblem != nil || isRenaming)
        }
        .frame(width: 460)
    }

    /// Only problems worth a sentence while typing (an empty or unchanged name just disables).
    private var visibleProblem: LibraryRename.Problem? {
        if case .nameTaken = inlineProblem { return inlineProblem }
        return nil
    }

    private func rename() async {
        guard !isRenaming, let package, let libraryId = container.activeLibrary?.libraryId else { return }
        isRenaming = true
        defer { isRenaming = false }
        await ActivityCenter.shared.flushPersistence()
        let pool = container.databaseManager?.pool
        let outcome = LibraryRename.renameOpenLibrary(
            package: package, currentName: currentName, to: name, libraryId: libraryId,
            store: LibraryLaunchCoordinator.shared.store,
            activeOperations: ActivityCenter.shared.activeOperations,
            closeDatabase: { try pool?.close() },
            pendingOpen: .userDefaults,
            relaunch: { BackupService.relaunchApp() })
        switch outcome {
        case .relaunching(let renamed):
            // Review S4: if MLM is still running a little later, the relaunch was cancelled — the
            // library is closed, so say so app-wide (not in the Settings window).
            let name = renamed.deletingPathExtension().lastPathComponent
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                RelaunchRequiredAlert.show(
                    title: "MLM needs to relaunch",
                    message: "The library was renamed to “\(name)”, but MLM didn’t quit. Relaunch to open it.")
            }
        case .refused(let refusal):
            problem = refusal
        case .relaunchRequired:
            dismiss()
            RelaunchRequiredAlert.show(
                title: "Rename didn’t finish",
                message: "MLM couldn’t rename the library file and needs to relaunch. The library keeps its name.")
        }
    }
}

// MARK: - Sheet frame (UC-SHEET-01…05)

/// A Settings sheet: the title (the task and its object), a grouped `Form`, and the buttons in
/// one row at the bottom (Cancel always works; one default button).
private struct SettingsSheet<Content: View, Buttons: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding([.top, .horizontal], Spacing.xl)
            Form { content() }
                .formStyle(.grouped)
                .scrollDisabled(true)
            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)
                buttons()
            }
            .padding([.bottom, .horizontal], Spacing.xl)
        }
    }
}

// MARK: - Relaunch required (app-wide)

/// `Rename didn’t finish` · `Relaunch`: MLM can't continue without relaunching (the library is
/// closed), so the alert is app-modal — independent of the Settings window (review S4).
enum RelaunchRequiredAlert {
    @MainActor
    static func show(title: String, message: String) {
        MainWindowPresenter.shared.show()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Relaunch")
        alert.runModal()
        BackupService.relaunchApp()
    }
}
