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
