import Foundation
import Observation

// MARK: - Folders (V-FOLD, DEC-024)

/// The model of the Folders place: one hierarchical outline of the library folder — folders
/// with counts, the library tracks where their files are, and the audio files on disk that
/// aren't in the library — rooted at the library folder or at a folder opened with `Open ⌘↓`.
///
/// Where things come from:
/// - **Counts, folders that hold tracks, the tracks of a folder:** the database
///   (`FolderCatalog`, one query; track rows only for open folders). Works with the drive away.
/// - **Folders without library tracks and files not in the library:** the disk, read off the
///   main actor — the open folders' listings when they open, and one background walk of the
///   library folder for the `‹n› not in library` counts and folder names in the filter. While
///   the drive is away nothing is read (the banner says why).
/// - **What is open and the root:** `FolderUIState`, per library, in `UserDefaults`.
///
/// The track rows live in `trackList` (a `TrackListModel` fed with the shown tracks in display
/// order): selection, context menu, selection bar, Info, Space and ↩ work on them exactly as in
/// every other track list. Folder and file rows have negative ids in the same selection.
@MainActor
@Observable
final class FolderViewModel {
    // MARK: Phase

    enum Phase: Equatable {
        /// The first load (placeholder rows, UC-TABLE-09).
        case loading
        /// No library folder is set (`No library folder · Open Settings ▸ Library`).
        case noLibraryFolder
        case ready
        /// The library folder can't be read although its drive is there (V-FOLD.N08), or the
        /// library file couldn't be read. `details` is the raw text.
        case failed(FailureKind, details: String)
    }

    enum FailureKind: Equatable {
        case libraryFolderUnreadable(reason: String)
        case database
    }

    private(set) var phase: Phase = .loading

    // MARK: State

    /// The library folder (absolute), once known.
    private(set) var libraryRoot: String?
    private(set) var catalog = FolderCatalog.empty
    private(set) var listings: [String: FolderListingResult] = [:]
    /// The whole library folder was read (counts of files not in the library are known).
    private(set) var isWalkComplete = false
    private(set) var notInLibraryFiles: [String: [String]] = [:]
    private(set) var isOffline = false
    private(set) var uiState = FolderUIState()
    private(set) var sortOrder: TrackSortOrder? = TrackSortOrder(column: .title, ascending: true)
    private(set) var filter = SearchFilter()
    private(set) var filterMatch: FolderFilterMatch?
    private(set) var scanning: Set<String> = []
    /// The built outline the table shows.
    private(set) var outline = FolderOutline()

    /// The shown track rows (display order) and the table's selection — the shared track-table
    /// model. Folder and file rows are selected through the same set (negative ids).
    let trackList = TrackListModel()

    @ObservationIgnored let ids = FolderOutlineIDs()
    @ObservationIgnored private var trackRows: [Int64: TrackRow] = [:]
    @ObservationIgnored private var loadedTrackFolders: Set<String> = []
    @ObservationIgnored private var loadingTrackFolders: Set<String> = []
    @ObservationIgnored private var listingFolders: Set<String> = []
    @ObservationIgnored private var walkTask: Task<Void, Never>?
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var rowsVersion = 0
    /// Folders the current filter opened that the user closed.
    @ObservationIgnored private var filterCollapsed: Set<String> = []

    // MARK: Dependencies

    /// What the model reads; live values in the app, fakes in tests.
    struct Environment {
        var queries: () -> FolderQueries?
        var libraryRoot: () async -> String?
        var libraryID: () -> String?
        var isDriveOffline: () -> Bool
        var defaults: UserDefaults
        var listDirectory: @Sendable (URL) -> FolderListingResult = { FolderDiskReader.list($0) }
        var walkDirectory: @Sendable (URL) -> [String: FolderListingResult] = { FolderDiskReader.walk($0) }

        @MainActor
        static func live(_ container: DependencyContainer = .shared) -> Environment {
            Environment(
                queries: { FolderQueries.current(container) },
                libraryRoot: {
                    if let root = container.mountObserver?.watchedLibraryRoot, !root.isEmpty { return root }
                    return (try? await container.configRepository?.getLibraryRoot()) ?? nil
                },
                libraryID: { container.activeLibrary?.libraryId },
                isDriveOffline: { LibraryDriveState.current(container).isOffline },
                defaults: .standard
            )
        }
    }

    @ObservationIgnored private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    // MARK: - Derived

    /// The library folder's own name (`Music`).
    var libraryFolderName: String {
        libraryRoot.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Folders"
    }

    var root: String { uiState.root }

    /// The root's name: the opened folder, or the library folder.
    var rootName: String { FolderPath.name(of: root, libraryFolderName: libraryFolderName) }

    /// Library tracks under the root (status bar, SQL catalog).
    var rootTrackCount: Int { catalog.trackCount(under: root) }

    /// Folders under the root: those holding library tracks, and — once read — every folder
    /// on disk.
    var rootFolderCount: Int {
        var folders = Set(catalog.folders.keys.filter { $0 != root && FolderPath.isWithin($0, root) })
        if !isOffline {
            for (path, result) in listings where FolderPath.isWithin(path, root) {
                for name in result.listing?.subfolders ?? [] { folders.insert(FolderPath.join(path, name)) }
            }
        }
        return folders.count
    }

    /// `12 folders · 1,204 tracks` (UC-STATUS-02 for Folders).
    var statusText: String? {
        guard phase == .ready else { return nil }
        return "\(StatusBarText.folders(rootFolderCount)) · \(StatusBarText.tracks(rootTrackCount))"
    }

    /// The folder the `‹n› files … aren’t in the library · Import` line is about: the selected
    /// folder (or the folder of the selected row), else the root (V-FOLD.E08).
    var headerFolder: String {
        guard let first = outline.order.first(where: { trackList.selection.contains($0) }) else { return root }
        if let folder = outline.foldersByID[first] { return folder.path }
        return outline.parentByID[first] ?? root
    }

    /// The not-in-library files of `folder` and below; nil while unknown (drive away, not read yet).
    func notInLibraryFiles(under folder: String) -> [String]? {
        guard !isOffline, isWalkComplete else { return nil }
        return FolderNotInLibrary.files(under: folder, in: notInLibraryFiles)
    }

    /// The row with `id` as the outline knows it.
    func folder(id: Int64) -> FolderRowInfo? { outline.foldersByID[id] }
    func file(id: Int64) -> FolderFileInfo? { outline.filesByID[id] }

    /// The absolute URL of a folder or file inside the library folder.
    func url(_ relative: String) -> URL? {
        libraryRoot.map { FolderPath.url(relative, libraryRoot: $0) }
    }

    /// The path-bar segments from the library folder to the root, then to the selected row's
    /// folder (V-FOLD.E07): `(path, name)`.
    var pathSegments: [(path: String, name: String)] {
        let target = headerFolder
        var result = [(path: "", name: libraryFolderName)]
        var current = ""
        for part in FolderPath.components(target) {
            current = FolderPath.join(current, part)
            result.append((current, part))
        }
        return result
    }

    // MARK: - Loading

    /// First load and every full reload (Try Again, another library folder).
    func load() async {
        generation += 1
        let token = generation
        isOffline = environment.isDriveOffline()
        guard let root = await environment.libraryRoot(), !root.isEmpty else {
            guard token == generation else { return }
            libraryRoot = nil
            catalog = .empty
            phase = .noLibraryFolder
            rebuild()
            return
        }
        let trimmed = FolderPath.trimmedRoot(root)
        if libraryRoot != trimmed {
            // Another library folder: fresh outline, nothing read from the old one.
            libraryRoot = trimmed
            uiState = FolderUIState.load(libraryID: environment.libraryID(), libraryRoot: trimmed, defaults: environment.defaults)
            FolderUIState.forgetOtherFolders(libraryID: environment.libraryID(), keeping: trimmed, defaults: environment.defaults)
            resetDisk()
            trackRows = [:]
            loadedTrackFolders = []
        }
        guard let queries = environment.queries() else {
            phase = .failed(.database, details: "The library isn’t open.")
            return
        }
        do {
            let catalog = try await queries.catalog(libraryRoot: trimmed)
            guard token == generation else { return }
            self.catalog = catalog
        } catch {
            guard token == generation else { return }
            phase = .failed(.database, details: error.localizedDescription)
            return
        }
        // A stored root that no longer exists falls back to the library folder.
        if !uiState.root.isEmpty, catalog.folders[uiState.root] == nil {
            let exists = isOffline ? false : await listedNow(uiState.root)
            guard token == generation else { return }
            if !exists { setRootState("") }
        }
        if !isOffline {
            // The library folder itself must be readable (V-FOLD.N08).
            let rootURL = FolderPath.url("", libraryRoot: trimmed)
            let list = environment.listDirectory
            let result = await Task.detached(priority: .userInitiated) { list(rootURL) }.value
            guard token == generation else { return }
            if case .unreadable(let reason) = result {
                phase = .failed(.libraryFolderUnreadable(reason: reason), details: "\(trimmed): \(reason)")
                return
            }
            listings[""] = result
        }
        phase = .ready
        await reloadLoadedTracks()
        rebuild()
        startWalk()
    }

    private func listedNow(_ folder: String) async -> Bool {
        guard let url = url(folder) else { return false }
        let list = environment.listDirectory
        let result = await Task.detached(priority: .userInitiated) { list(url) }.value
        if result.listing != nil { listings[folder] = result }
        return result.listing != nil
    }

    private func resetDisk() {
        walkTask?.cancel()
        walkTask = nil
        listings = [:]
        notInLibraryFiles = [:]
        isWalkComplete = false
        listingFolders = []
    }

    /// The drive came or went (`LibraryDriveState`): rows from the database stay; disk facts are
    /// read again when it is back.
    func driveStateChanged() {
        let offline = environment.isDriveOffline()
        guard offline != isOffline else { return }
        isOffline = offline
        if offline {
            resetDisk()
            rebuild()
        } else {
            Task { await load() }
        }
    }

    /// Files were added, moved or re-pointed, an import finished, tracks were deleted: the
    /// catalog and (when connected) the disk are read again; the outline updates in place.
    func libraryFilesDidChange() {
        Task {
            await refreshCatalog()
            if !isOffline {
                for folder in Array(listings.keys) where isShownOrOpen(folder) { listings[folder] = nil }
                rebuild()
                restartWalk()
            }
        }
    }

    /// Tags changed (`.trackMetadataDidChange`): the shown tracks' rows are rebuilt in place.
    func trackMetadataDidChange() {
        Task {
            await reloadLoadedTracks()
            rebuild()
            if filterMatch != nil { scheduleFilter(filter, delay: .zero) }
        }
    }

    /// Tracks were removed from the library: out of the outline at once, then the catalog.
    func removeTracks(ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        for id in ids { trackRows[id] = nil }
        trackList.selection.subtract(ids)
        Task {
            await refreshCatalog()
        }
        rebuild()
    }

    private func refreshCatalog() async {
        guard let root = libraryRoot, let queries = environment.queries() else { return }
        guard let catalog = try? await queries.catalog(libraryRoot: root) else { return }
        self.catalog = catalog
        notInLibraryFiles = FolderNotInLibrary.files(listings: listings, catalog: catalog)
        loadedTrackFolders = []
        await reloadLoadedTracks()
        rebuild()
    }

    private func isShownOrOpen(_ folder: String) -> Bool {
        folder == root || uiState.expanded.contains(folder)
    }

    // MARK: - Rebuilding the outline

    /// Rebuilds the rows from what is known (cheap: open folders only) and asks for what is
    /// missing — track rows of open folders, listings of open folders.
    func rebuild() {
        let counts: [String: Int]? = isWalkComplete && !isOffline
            ? FolderNotInLibrary.recursiveCounts(notInLibraryFiles, folders: listings.keys)
            : nil
        let input = FolderOutlineInput(
            root: root,
            catalog: catalog,
            listings: listings,
            isOffline: isOffline,
            trackRows: trackRows,
            loadedFolders: loadedTrackFolders,
            expanded: uiState.expanded,
            collapsedByUser: filterCollapsed,
            sort: sortOrder,
            filter: filterMatch,
            notInLibraryCounts: counts,
            scanning: scanning
        )
        let built = FolderOutline.build(input, ids: ids)
        outline = built
        let rows = built.trackRows
        rowsVersion += 1
        let version = rowsVersion
        Task {
            // Only the newest rows reach the table (rebuilds can follow each other quickly).
            guard version == rowsVersion else { return }
            await trackList.setRows(rows)
        }
        for folder in built.foldersMissingTracks where !loadingTrackFolders.contains(folder) {
            loadTracks(in: folder)
        }
        if !isOffline, phase == .ready {
            for folder in built.foldersToList where !listingFolders.contains(folder) {
                list(folder)
            }
        }
    }

    private func loadTracks(in folder: String) {
        guard let queries = environment.queries() else { return }
        let ids = catalog.folders[folder]?.directTrackIDs ?? []
        guard !ids.isEmpty else { return }
        loadingTrackFolders.insert(folder)
        Task {
            defer { loadingTrackFolders.remove(folder) }
            guard let tracks = try? await queries.tracks(ids: ids) else { return }
            let rows = await Self.buildRows(tracks)
            for row in rows { trackRows[row.id] = row }
            loadedTrackFolders.insert(folder)
            rebuild()
        }
    }

    /// Rows of 1,500+ tracks are built off the main actor (a managed download folder).
    private static func buildRows(_ tracks: [Track]) async -> [TrackRow] {
        if tracks.count <= TrackListModel.backgroundThreshold { return TrackRowBuilder.build(tracks) }
        return await Task.detached(priority: .userInitiated) { TrackRowBuilder.build(tracks) }.value
    }

    /// Re-reads every loaded track row (tags, availability changed).
    private func reloadLoadedTracks() async {
        guard let queries = environment.queries(), !trackRows.isEmpty else { return }
        let ids = Array(trackRows.keys).filter { catalog.folderByTrackID[$0] != nil }
        guard let tracks = try? await queries.tracks(ids: ids) else { return }
        var rows: [Int64: TrackRow] = [:]
        for row in await Self.buildRows(tracks) { rows[row.id] = row }
        trackRows = rows
    }

    private func list(_ folder: String) {
        guard let url = url(folder) else { return }
        listingFolders.insert(folder)
        let list = environment.listDirectory
        let token = generation
        Task {
            let result = await Task.detached(priority: .userInitiated) { list(url) }.value
            listingFolders.remove(folder)
            guard token == generation, !isOffline else { return }
            listings[folder] = result
            if isWalkComplete { notInLibraryFiles = FolderNotInLibrary.files(listings: listings, catalog: catalog) }
            rebuild()
        }
    }

    // MARK: The background walk (files not in the library, folder names)

    private func startWalk() {
        guard !isOffline, walkTask == nil, let root = libraryRoot else { return }
        let walk = environment.walkDirectory
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let token = generation
        walkTask = Task {
            let result = await Task.detached(priority: .utility) { walk(rootURL) }.value
            guard !Task.isCancelled, token == generation, !isOffline else { return }
            listings.merge(result) { _, new in new }
            notInLibraryFiles = FolderNotInLibrary.files(listings: listings, catalog: catalog)
            isWalkComplete = true
            walkTask = nil
            rebuild()
            if !filter.isEmpty { scheduleFilter(filter, delay: .zero) }
        }
    }

    private func restartWalk() {
        walkTask?.cancel()
        walkTask = nil
        startWalk()
    }

    // MARK: - Expanding (Return / double-click / → ←, persisted)

    func isExpanded(_ folder: String) -> Bool { uiState.expanded.contains(folder) }

    /// Whether the folder shows open now (the user opened it, or the filter did).
    func isShownExpanded(_ folder: String) -> Bool {
        outline.foldersByID[ids.folder(folder)]?.isExpanded ?? isExpanded(folder)
    }

    func setExpanded(_ folder: String, _ expanded: Bool) {
        guard expanded != isShownExpanded(folder) || expanded != isExpanded(folder) else { return }
        if expanded {
            uiState.expanded.insert(folder)
            filterCollapsed.remove(folder)
        } else {
            uiState.expanded.remove(folder)
            // A folder the filter opened stays closed while this filter is on.
            if filterMatch != nil { filterCollapsed.insert(folder) }
        }
        persist()
        rebuild()
    }

    func toggle(_ folder: String) {
        setExpanded(folder, !isShownExpanded(folder))
    }

    /// ⌥→: the folder and every folder inside that holds library tracks or was read from disk.
    func expandAll(_ folder: String) {
        var paths: Set<String> = [folder]
        for path in catalog.folders.keys where FolderPath.isWithin(path, folder) { paths.insert(path) }
        if !isOffline {
            for (path, result) in listings where FolderPath.isWithin(path, folder) {
                paths.insert(path)
                for name in result.listing?.subfolders ?? [] { paths.insert(FolderPath.join(path, name)) }
            }
        }
        uiState.expanded.formUnion(paths)
        persist()
        rebuild()
    }

    /// ⌥←: the folder and everything inside it.
    func collapseAll(_ folder: String) {
        uiState.expanded = uiState.expanded.filter { !FolderPath.isWithin($0, folder) }
        persist()
        rebuild()
    }

    // MARK: - Root (Open ⌘↓, ⌘↑, path bar)

    /// `Open ⌘↓`: the folder becomes the outline's root (DEC-053).
    func openAsRoot(_ folder: String) {
        guard folder != root else { return }
        trackList.selection = []
        setRootState(folder)
        rebuild()
    }

    /// ⌘↑: one level up; nothing at the library folder.
    @discardableResult
    func goUp() -> Bool {
        guard let parent = FolderPath.parent(of: root) else { return false }
        let previous = root
        setRootState(parent)
        rebuild()
        // The folder that was the root stays selected, so ⌘↓ goes back.
        trackList.selection = [ids.folder(previous)]
        return true
    }

    /// A path-bar segment: the folder shows (its parents open) and is selected; a folder above
    /// the root makes it the root.
    func jump(to folder: String) {
        if !FolderPath.isWithin(folder, root) {
            setRootState(folder)
        } else {
            openAncestors(of: folder)
        }
        rebuild()
        trackList.selection = folder == root ? [] : [ids.folder(folder)]
    }

    private func setRootState(_ folder: String) {
        uiState.root = folder
        persist()
    }

    private func openAncestors(of folder: String) {
        for ancestor in FolderPath.ancestors(of: folder) where FolderPath.isWithin(ancestor, root) && ancestor != root {
            uiState.expanded.insert(ancestor)
        }
        persist()
    }

    private func persist() {
        guard let libraryRoot else { return }
        uiState.save(libraryID: environment.libraryID(), libraryRoot: libraryRoot, defaults: environment.defaults)
    }

    // MARK: - Reveal (⌘L, the search field's Library results)

    /// Shows a library track (opening the folders above it) and selects it. Returns false when
    /// the track isn't in the library folder.
    @discardableResult
    func reveal(trackID: Int64) -> Bool {
        guard let folder = catalog.folderByTrackID[trackID] else { return false }
        if !FolderPath.isWithin(folder, root) { setRootState("") }
        openAncestors(of: folder)
        if folder != root { uiState.expanded.insert(folder) }
        persist()
        rebuild()
        trackList.selection = [trackID]
        return true
    }

    /// A folder chosen in the search field's Library results (absolute path): shown and selected.
    func revealFolder(absolutePath: String) {
        guard let libraryRoot, let relative = FolderPath.relative(absolutePath, libraryRoot: libraryRoot) else { return }
        if !FolderPath.isWithin(relative, root) { setRootState("") }
        openAncestors(of: relative)
        rebuild()
        trackList.selection = relative.isEmpty ? [] : [ids.folder(relative)]
    }

    // MARK: - Sort (within each folder, UC-TABLE-04)

    func setSortOrder(_ order: TrackSortOrder?) {
        guard order != sortOrder else { return }
        sortOrder = order
        rebuild()
    }

    // MARK: - Filter in place (UC-SEARCH-01, V-FOLD.E02)

    /// The toolbar search for Folders: tracks by the track filter, folders and files by name.
    func applyFilter(_ newFilter: SearchFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        scheduleFilter(newFilter, delay: .milliseconds(200))
    }

    private func scheduleFilter(_ filter: SearchFilter, delay: Duration) {
        filterTask?.cancel()
        filterCollapsed = []
        guard !filter.isEmpty else {
            filterMatch = nil
            rebuild()
            return
        }
        filterTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let match = await computeMatch(filter)
            guard !Task.isCancelled, filter == self.filter else { return }
            filterMatch = match
            rebuild()
        }
    }

    /// The matches under the root (also used directly by tests).
    func computeMatch(_ filter: SearchFilter) async -> FolderFilterMatch {
        var match = FolderFilterMatch()
        let inRoot: (String) -> Bool = { FolderPath.isWithin($0, self.root) }
        if let queries = environment.queries(), let ids = try? await queries.matchingTrackIDs(filter) {
            match.trackIDs = ids.filter { id in catalog.folderByTrackID[id].map(inRoot) ?? false }
        }
        // Names: free words only (tokens describe tracks).
        if !filter.freeTerms.isEmpty {
            var folders = Set(catalog.folders.keys)
            if !isOffline {
                for (path, result) in listings {
                    folders.insert(path)
                    for name in result.listing?.subfolders ?? [] { folders.insert(FolderPath.join(path, name)) }
                }
            }
            for path in folders where !path.isEmpty && path != root && inRoot(path) {
                if filter.matchesName(FolderPath.components(path).last ?? path) { match.nameMatchedFolders.insert(path) }
            }
            if !isOffline {
                for (folder, files) in notInLibraryFiles where inRoot(folder) {
                    for file in files where filter.matchesName(FolderPath.components(file).last ?? file) {
                        match.nameMatchedFiles.insert(file)
                    }
                }
            }
        }
        return match
    }

    /// The filter is on and nothing under the root matches (filtered-empty, UC-EMPTY-02).
    var isFilteredEmpty: Bool {
        guard let filterMatch else { return false }
        return filterMatch.trackIDs.isEmpty && filterMatch.nameMatchedFolders.isEmpty && filterMatch.nameMatchedFiles.isEmpty
    }

    /// `3 folders and 12 tracks match “dek”` (V-FOLD.E02 result line).
    var filterSummary: String? {
        guard let filterMatch, !isFilteredEmpty else { return nil }
        let folders = filterMatch.nameMatchedFolders.count
        let tracks = filterMatch.trackIDs.count + filterMatch.nameMatchedFiles.count
        let query = filter.displayText
        return "\(StatusBarText.folders(folders)) and \(StatusBarText.tracks(tracks)) match “\(query)”"
    }

    // MARK: - Scan and import (Activity operations)

    /// `Scan This Folder` ⌘R: the folder (or the root) is read and imported; its row says
    /// `Scanning…` meanwhile.
    func scan(_ folder: String) async {
        guard !isOffline, let url = url(folder), !scanning.contains(folder) else { return }
        scanning.insert(folder)
        rebuild()
        await FolderImports.scan(url)
        scanning.remove(folder)
        // The import posts `.libraryFilesDidChange`; a cancelled one may not have.
        libraryFilesDidChange()
    }

    /// `Import ‹n› Files`: the files of `folder` (and below) that aren't in the library.
    func importNotInLibrary(under folder: String) async {
        guard let files = notInLibraryFiles(under: folder), !files.isEmpty else { return }
        await importFiles(files)
    }

    /// `Import File` / `Import ‹n› Files` on file rows (relative paths).
    func importFiles(_ relativeFiles: [String]) async {
        guard !isOffline, let libraryRoot, !relativeFiles.isEmpty else { return }
        let urls = relativeFiles.map { FolderPath.url($0, libraryRoot: libraryRoot) }
        await FolderImports.importFiles(urls)
        libraryFilesDidChange()
    }

    // MARK: - A folder as its tracks

    /// The library tracks of the selected rows in display order: a folder stands for its
    /// tracks (subfolders included), a track for itself; each track once.
    func tracks(forRows rowIDs: Set<Int64>) async -> [Track] {
        guard let root = libraryRoot, let queries = environment.queries() else { return [] }
        let loader = FolderTrackLoader(queries: queries, libraryRoot: root)
        var result: [Track] = []
        var seen = Set<Int64>()
        for id in outline.order where rowIDs.contains(id) {
            if let folder = outline.foldersByID[id] {
                for track in await loader.tracks(in: [folder.path], sort: sortOrder, catalog: catalog) {
                    if let trackID = track.id, seen.insert(trackID).inserted { result.append(track) }
                }
            } else if let row = trackRows[id], seen.insert(id).inserted {
                result.append(row.track)
            }
        }
        return result
    }

    // MARK: - Snapshot fixtures

    /// Puts `tracks` at the top of an otherwise empty outline (snapshot fixture; no database).
    func showForFixture(_ tracks: [Track], libraryRoot: String) {
        self.libraryRoot = libraryRoot
        var rows: [FolderCatalog.Row] = []
        for track in tracks {
            guard let id = track.id else { continue }
            rows.append(FolderCatalog.Row(id: id, organizedPath: "\(id).m4a", originalPath: ""))
        }
        catalog = FolderCatalog.build(rows, libraryRoot: libraryRoot)
        for row in TrackRowBuilder.build(tracks) { trackRows[row.id] = row }
        isOffline = true
        phase = .ready
        rebuild()
        trackList.setTracksNow(outline.trackRows.map(\.track))
    }
}
