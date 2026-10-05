import Foundation
import Observation

/// Window-level commands shared by the menu bar, the toolbar Add menu and the sidebar, so a
/// command has one implementation wherever it is offered. In the environment
/// (`@Environment(ShellActions.self)`) and as `@FocusedValue(\.shellActions)`.
///
/// Presentation flags (`isChoosingImportFolder`, `isCreatingSyncProfile`) are read by
/// `ContentView`, which owns the file panel and the sheet.
@MainActor
@Observable
final class ShellActions {
    /// `Import Files or Folder…` file panel is up.
    var isChoosingImportFolder = false
    /// `New Sync Profile…` sheet is up.
    var isCreatingSyncProfile = false

    @ObservationIgnored private let container: DependencyContainer
    @ObservationIgnored private let navigation: NavigationModel
    @ObservationIgnored private let sidebar: SidebarModel
    @ObservationIgnored private let statusBar: StatusBarCenter
    @ObservationIgnored private var importViewModel: ImportViewModel?

    /// The undoable playlist and sync-profile edits (W2-F), on the library's `UndoCenter`.
    @ObservationIgnored let edits: ShellEdits

    init(
        container: DependencyContainer,
        navigation: NavigationModel,
        sidebar: SidebarModel,
        statusBar: StatusBarCenter,
        undo: UndoCenter
    ) {
        self.container = container
        self.navigation = navigation
        self.sidebar = sidebar
        self.statusBar = statusBar
        edits = ShellEdits(dependencies: .live(container), undo: undo, window: .main)
    }

    var hasLibrary: Bool { container.isInitialized }

    /// The window's track activation — double-click / Return: play with the rows after it as the
    /// queue, and make it the Info track (installed by `ContentView`). The menu bar uses the same
    /// path (Playback ▸ Play All Tracks).
    @ObservationIgnored var activateTrack: ((Track, [Track]) -> Void)?

    // MARK: New

    /// `New Playlist` ⌘N (File menu, sidebar ＋, Add menu): creates `Untitled Playlist`
    /// (numbered when taken), opens it and puts its sidebar name into edit mode. Undoable.
    func newPlaylist() {
        Task { await edits.newPlaylist() }
    }

    /// `New Playlist from Selection` ⇧⌘N / Add to Playlist ▸ New Playlist…: one undoable
    /// step, tracks in the order given (S-SEL-NEWPLAYLIST: no sheet, no navigation).
    func newPlaylistFromSelection(trackIDs: [Int64]) {
        guard !trackIDs.isEmpty else { return }
        Task { await edits.newPlaylist(fromTrackIDs: trackIDs) }
    }

    /// `Add to Playlist ▸ ‹playlist›`: appends the tracks; undoable.
    func addToPlaylist(_ playlistID: Int64, trackIDs: [Int64]) {
        guard !trackIDs.isEmpty else { return }
        Task { await edits.addTracks(trackIDs, toPlaylist: playlistID) }
    }

    /// `New Sync Profile…` (Sync section ＋, track and playlist menus).
    func newSyncProfile() {
        isCreatingSyncProfile = true
    }

    // MARK: Import

    /// `Import Files or Folder…`: opens the folder panel; the import runs as an Activity
    /// operation through the existing `ImportViewModel`.
    func chooseImportFolder() {
        isChoosingImportFolder = true
    }

    func importFolder(_ url: URL) {
        let name = url.lastPathComponent
        guard let viewModel = makeImportViewModel() else {
            statusBar.post(Self.importUnavailableMessage(folder: name))
            return
        }
        statusBar.post("Import started — “\(name)”")
        Task {
            await viewModel.importFromDirectory(url)
            if let error = viewModel.errorMessage, viewModel.lastResult == nil {
                AppLogger.shared.error("Importing “\(name)” failed: \(error)", source: "Shell")
            }
            let message = Self.importMessage(folder: name, result: viewModel.lastResult)
            statusBar.post(message.text, actions: message.offersShow ? [Self.showActivityAction()] : [])
        }
    }

    /// Finder files and folders dropped on MLM (D-LIB-FINDER-IN, W2-H): the same import as
    /// Import Files or Folder… — one Activity operation, start and finish in the status bar.
    /// Folders are read for their audio files; other files are left out.
    ///
    /// - Returns: the dropped tracks' ids in drop order — imported now or already in the
    ///   library — so a drop on a playlist can add them; empty when nothing could be imported.
    @discardableResult
    func importDropped(_ urls: [URL], intoPlaylist playlistName: String? = nil) async -> [Int64] {
        let files = await Task.detached(priority: .userInitiated) { Self.audioFiles(in: urls) }.value
        guard !files.isEmpty else {
            statusBar.post(DropWords.notAudio(urls.map(\.lastPathComponent)))
            return []
        }
        let isOneFolder = urls.count == 1 && (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let folder = isOneFolder ? urls[0].lastPathComponent : nil
        guard let viewModel = makeImportViewModel() else {
            statusBar.post(Self.importUnavailableMessage(folder: folder ?? urls[0].lastPathComponent))
            return []
        }
        statusBar.post(DropWords.importStarted(files: files.count, folderName: folder, playlist: playlistName),
                       actions: [Self.showActivityAction()])
        await viewModel.importFiles(files, title: folder.map { "“\($0)”" } ?? StatusBarText.count(files.count, "file", "files"))
        let message = Self.importMessage(folder: folder ?? urls[0].lastPathComponent, result: viewModel.lastResult)
        statusBar.post(message.text, actions: message.offersShow ? [Self.showActivityAction()] : [])
        guard viewModel.lastResult != nil, let tracks = container.trackRepository else { return [] }
        let known = (try? await tracks.fetchTracksByOriginalPaths(files.map(\.path))) ?? []
        return Self.orderedIDs(of: known, paths: files.map(\.path))
    }

    /// The audio files of dropped items, in drop order: a folder's files sorted by path, a file
    /// itself when it is audio. Reads only the dropped files and folders.
    nonisolated static func audioFiles(in urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory, url.pathExtension.lowercased() != "mlibm" {
                files.append(contentsOf: (try? ImportService.scanDirectory(url)) ?? [])
            } else if MetadataExtractor.isAudioFile(url) {
                files.append(url)
            }
        }
        var seen = Set<String>()
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Track ids in the order of `paths` (a track's original path, standardized).
    nonisolated static func orderedIDs(of tracks: [Track], paths: [String]) -> [Int64] {
        var byPath: [String: Int64] = [:]
        for track in tracks {
            guard let id = track.id else { continue }
            let path = URL(fileURLWithPath: track.originalPath).standardizedFileURL.path
            byPath[path] = id
            byPath[path.precomposedStringWithCanonicalMapping] = id
        }
        var seen = Set<Int64>()
        return paths.compactMap { path -> Int64? in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            return byPath[standardized] ?? byPath[standardized.precomposedStringWithCanonicalMapping]
        }.filter { seen.insert($0).inserted }
    }

    /// The status-bar sentence after an import (UC-STATUS-05 shape, UC-COPY-11: no raw error
    /// text — the cause is in Activity and the logs).
    static func importMessage(folder: String, result: ImportService.ImportResult?) -> (text: String, offersShow: Bool) {
        guard let result else {
            return ("Couldn’t import “\(folder)” — the details are in Activity", true)
        }
        if result.cancelled {
            return ("Import of “\(folder)” cancelled — \(result.committed.formatted(.number)) imported", false)
        }
        return (importFinishedMessage(imported: result.succeeded, skipped: result.skipped, failed: result.failed),
                result.failed > 0)
    }

    /// `Import finished — 35 imported, 2 failed` (UC-STATUS-05 shape; `·` stays reserved for
    /// the separator before buttons).
    static func importFinishedMessage(imported: Int, skipped: Int, failed: Int) -> String {
        var parts = ["\(imported.formatted(.number)) imported"]
        if failed > 0 { parts.append("\(failed.formatted(.number)) failed") }
        if skipped > 0 { parts.append("\(skipped.formatted(.number)) already in the library") }
        return "Import finished — " + parts.joined(separator: ", ")
    }

    static func importUnavailableMessage(folder: String) -> String {
        "Couldn’t import “\(folder)” — the library isn’t ready yet"
    }

    /// `Show`: opens the Activity panel (the Activity popover replaces it in W3-ACT).
    static func showActivityAction() -> StatusAction {
        StatusAction("Show") {
            UserDefaults.standard.set(true, forKey: ActivityPanelHosting.expandedKey)
        }
    }

    // MARK: Scan

    /// A `Scan Library Folder` is running (Library menu, ⌘R).
    private(set) var isScanningLibraryFolder = false

    /// `Scan Library Folder` (Library menu, ⌘R in All Tracks / Albums / Genres; All Tracks has
    /// no header buttons, DEC-048): re-reads the library folder through the existing import
    /// pipeline, then refreshes All Tracks in its current scope. One scan at a time.
    func scanLibraryFolder() {
        guard !isScanningLibraryFolder, let viewModel = makeImportViewModel() else { return }
        isScanningLibraryFolder = true
        Task {
            // The import view model only knows the library folder after loading it; without
            // this the scan stopped with "No library root configured".
            await viewModel.loadLibraryRoot()
            await viewModel.importLibrary()
            await container.libraryViewModel?.refresh()
            isScanningLibraryFolder = false
        }
    }

    // MARK: Sources (temporary)

    /// Shows the former Sources section (accounts, playlist import) as a pushed page until
    /// W3-SET / W3-ADD replace it.
    func showSources() {
        if navigation.currentRoute != .sources {
            navigation.push(.sources)
        }
    }

    // MARK: -

    private func makeImportViewModel() -> ImportViewModel? {
        if let importViewModel { return importViewModel }
        guard let service = container.importService, let config = container.configRepository else { return nil }
        let viewModel = ImportViewModel(
            importService: service,
            configRepository: config,
            activityViewModel: container.activityViewModel
        )
        importViewModel = viewModel
        return viewModel
    }
}
