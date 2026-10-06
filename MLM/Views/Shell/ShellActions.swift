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
    /// The Add menu's sheets (`Add from Link…`, `Import Playlist from Source…`) and `Refresh
    /// from Sources` (W3-ADD); also the search field's `QuickAddPresenting`.
    let imports: ImportSheetsPresenter
    @ObservationIgnored private let undo: UndoCenter

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
        self.undo = undo
        edits = ShellEdits(dependencies: .live(container), undo: undo, window: .main)
        imports = ImportSheetsPresenter(container: container, statusBar: statusBar, navigation: navigation)
        let edits = self.edits
        imports.addToPlaylist = { playlistID, trackID in
            Task { await edits.addTracks([trackID], toPlaylist: playlistID) }
        }
    }

    // MARK: Add menu (W3-ADD)

    /// `Add from Link…` ⌘U (S-QUICKADD).
    func addFromLink() {
        imports.addFromLink()
    }

    /// `Import Playlist from Source…` ⇧⌘I (S-IMPORT).
    func importPlaylistFromSource() {
        imports.importPlaylistFromSource()
    }

    /// `Refresh from Sources` (enabled only with a connected source, UC-TB-05).
    func refreshFromSources() {
        imports.refreshFromSources()
    }

    var canRefreshFromSources: Bool { imports.canRefreshFromSources }

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

    /// `Import Files or Folder…`: opens the system panel (files and folders); the import runs
    /// as an Activity operation through the existing `ImportViewModel`.
    func chooseImportFolder() {
        isChoosingImportFolder = true
    }

    /// The panel's choice (W3-ADD; it took only folders before), and the one behaviour of every
    /// file import gesture — Finder drops (`importDropped`) and, for W3-SET, Settings ▸ Library
    /// `Import Files or Folder…` call it too (review S6). A folder inside the library folder is
    /// scanned where it is, as before. Everything else — files, folders elsewhere — is
    /// **copied** into the library folder's organised layout and imported from there
    /// (`LibraryFileCopier`; originals are never moved or deleted), one `Scan` operation. Files
    /// that already are tracks are not imported again. Undo removes the imported tracks from the
    /// library; the copied files stay (said in the confirmation). Without a library folder the
    /// files are imported where they are.
    func importChosen(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { await importFiles(urls) }
    }

    /// `importChosen`'s work. Returns the chosen files' tracks in order — imported now or
    /// already in the library — so a drop on a playlist can add them.
    @discardableResult
    func importFiles(_ urls: [URL], intoPlaylist playlistName: String? = nil,
                     scanFoldersInLibraryInPlace: Bool = true) async -> [Int64] {
        let rootPath = (try? await container.configRepository?.getLibraryRoot()) ?? nil
        let root = rootPath.map { URL(fileURLWithPath: $0) }
        var copyItems: [URL] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if scanFoldersInLibraryInPlace, isDirectory, url.pathExtension.lowercased() != "mlibm",
               root.map({ LibraryFileCopier.isInside(url, root: $0) }) ?? true {
                importFolder(url)
            } else {
                copyItems.append(url)
            }
        }
        guard !copyItems.isEmpty else { return [] }
        let files = await Task.detached(priority: .userInitiated) { Self.audioFiles(in: copyItems) }.value
        guard !files.isEmpty else {
            statusBar.post(DropWords.notAudio(copyItems.map(\.lastPathComponent)))
            return []
        }
        let isOneFolder = copyItems.count == 1 && (try? copyItems[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        guard let viewModel = makeImportViewModel() else {
            statusBar.post(Self.importUnavailableMessage(folder: copyItems[0].lastPathComponent))
            return []
        }
        let title = playlistName != nil || isOneFolder
            ? DropWords.importTitle(files: files.count, folderName: isOneFolder ? copyItems[0].lastPathComponent : nil,
                                    playlist: playlistName)
            : "Import \(ActivityNoun.file.counted(files.count))"
        guard let root else {
            // No library folder: nothing to copy into; imported where they are (as before).
            guard await viewModel.importFiles(files, title: title) != nil else { return [] }
            return await trackIDs(forPaths: files.map(\.path))
        }
        let drive = LibraryDriveState.current(container)
        if drive.isOffline, let name = drive.volumeName {
            statusBar.post("Can’t import — “\(name)” is not connected")
            return []
        }
        // Tracks this import adds carry a `date_added` from now on (ISO 8601 sorts as text).
        let startedAt = ISO8601DateFormatter().string(from: Date())
        let queries = container.databaseManager.map { ImportLibraryQueries(database: $0.pool) }
        let tracks = container.trackRepository
        let copier = LibraryFileCopier(libraryRoot: root, knownPaths: { await queries?.knownOriginalPaths($0) ?? [] })
        guard let outcome = await viewModel.importFilesCopyingIntoLibrary(
            files, title: title, copier: copier,
            repoint: { original, organized in
                // A renamed copy (`Title 2.ext`) points at itself, not at the plain name (S5).
                guard var track = try? await tracks?.fetchTracksByOriginalPaths([original]).first else { return }
                track.organizedPath = organized
                try? await tracks?.update(track)
            }) else { return [] }
        await recordCopiedImportUndo(paths: outcome.placement.toImport.map(\.path), since: startedAt,
                                     copied: outcome.placement.copied)
        return await trackIDs(forPaths: files.compactMap { outcome.placement.importedPath[$0.path] })
    }

    private func trackIDs(forPaths paths: [String]) async -> [Int64] {
        guard let tracks = container.trackRepository, !paths.isEmpty else { return [] }
        let known = (try? await tracks.fetchTracksByOriginalPaths(paths)) ?? []
        return Self.orderedIDs(of: known, paths: paths)
    }

    /// Undo of a copying import (database only): removes the tracks this import added; the
    /// copied files stay in the library folder. Redo imports them again.
    private func recordCopiedImportUndo(paths: [String], since startedAt: String, copied: Int) async {
        guard let tracks = container.trackRepository, let service = container.importService else { return }
        let added = ((try? await tracks.fetchTracksByOriginalPaths(paths)) ?? [])
            .filter { ($0.dateAdded ?? "") >= startedAt }
            .compactMap(\.id)
        guard !added.isEmpty else { return }
        let files = paths.map { URL(fileURLWithPath: $0) }
        undo.record(
            "Import \(ActivityNoun.track.counted(added.count).capitalized)",
            message: Self.copiedImportMessage(imported: added.count, copied: copied),
            done: added,
            undo: { ids in
                try await tracks.delete(ids: ids)
                NotificationCenter.default.post(name: .libraryDidDeleteTracks, object: nil, userInfo: ["deletedIDs": ids])
                return files
            },
            redo: { files in
                _ = try await service.importFiles(files, onProgress: nil)
                NotificationCenter.default.post(name: .libraryDidImport, object: nil)
                return ((try? await tracks.fetchTracksByOriginalPaths(files.map(\.path))) ?? []).compactMap(\.id)
            }
        )
    }

    /// `Imported 4 tracks · 4 files copied into the library folder (Undo keeps the files)`.
    nonisolated static func copiedImportMessage(imported: Int, copied: Int) -> String {
        var text = "Imported \(ActivityNoun.track.counted(imported))"
        if copied > 0 {
            text += " · \(ActivityNoun.file.counted(copied)) copied into the library folder (Undo keeps the files)"
        }
        return text
    }

    func importFolder(_ url: URL) {
        let name = url.lastPathComponent
        guard let viewModel = makeImportViewModel() else {
            statusBar.post(Self.importUnavailableMessage(folder: name))
            return
        }
        // The start and end messages come from Activity (`Import started — “‹folder›”`,
        // `Import finished — 35 imported, 2 failed`, UC-JOB-08) — one source of words.
        Task {
            await viewModel.importFromDirectory(url)
            if let error = viewModel.errorMessage, viewModel.lastResult == nil {
                AppLogger.shared.error("Importing “\(name)” failed: \(error)", source: "Shell")
            }
        }
    }

    /// Finder files and folders dropped on MLM (D-LIB-FINDER-IN, W2-H): the same import as
    /// Import Files or Folder… (review S6: files from outside the library folder are copied in,
    /// PATTERN-DND.N09) — one Activity operation (`Scan`, the import lane: it queues behind a
    /// running import), whose start and end messages come from Activity (UC-JOB-08). Folders
    /// are read for their audio files; other files are left out.
    ///
    /// - Returns: the dropped tracks' ids in drop order — imported now or already in the
    ///   library — so a drop on a playlist can add them; empty when nothing could be imported.
    @discardableResult
    func importDropped(_ urls: [URL], intoPlaylist playlistName: String? = nil) async -> [Int64] {
        await importFiles(urls, intoPlaylist: playlistName, scanFoldersInLibraryInPlace: false)
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

    static func importUnavailableMessage(folder: String) -> String {
        "Couldn’t import “\(folder)” — the library isn’t ready yet"
    }

    /// `Show`: opens the Activity popover (W3-ACT).
    static func showActivityAction() -> StatusAction {
        StatusAction("Show") {
            ActivityRouter.shared.showPopover()
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

    // MARK: -

    private func makeImportViewModel() -> ImportViewModel? {
        if let importViewModel { return importViewModel }
        guard let service = container.importService, let config = container.configRepository else { return nil }
        let viewModel = ImportViewModel(
            importService: service,
            configRepository: config,
            activity: ActivityCenter.shared
        )
        importViewModel = viewModel
        return viewModel
    }
}
