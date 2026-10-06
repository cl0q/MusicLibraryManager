import Foundation

// MARK: - The outline's rows (V-FOLD.E04, DEC-024)

/// A folder row: triangle, name, `48 tracks`, `Managed by MLM`, its Status.
struct FolderRowInfo: Equatable, Sendable {
    /// Relative to the library folder.
    let path: String
    let name: String
    /// Library tracks inside, subfolders included (SQL catalog).
    let trackCount: Int
    let isManaged: Bool
    /// Audio files inside (subfolders included) that aren't in the library; nil = not known
    /// (the drive is away, or the folder hasn't been read yet).
    let notInLibraryCount: Int?
    /// `Can’t read this folder` — the reason in plain words.
    let unreadableReason: String?
    /// A scan of this folder runs.
    let isScanning: Bool
    let isExpanded: Bool
}

/// An audio file on disk that isn't in the library (`Not in library`, V-FOLD.N02).
struct FolderFileInfo: Equatable, Sendable {
    /// The file, relative to the library folder.
    let path: String
    let name: String
    /// The folder it lies in.
    let folder: String
}

/// One row of the hierarchical table. Ids: library tracks keep their track id (> 0), so the
/// track-table machinery (selection, menus, selection bar, Info) works on them unchanged;
/// folders, files and placeholders get stable negative ids (`FolderOutlineIDs`).
struct FolderOutlineRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case folder(FolderRowInfo)
        case track(TrackRow)
        case file(FolderFileInfo)
        /// The children of an expanded folder are still being read (or, inside a collapsed
        /// folder, the hidden child that gives it its disclosure triangle).
        case loading
    }

    let id: Int64
    let kind: Kind
    /// A folder's rows when expanded; nil for every other row.
    var children: [FolderOutlineRow]? = nil

    var folder: FolderRowInfo? {
        if case .folder(let info) = kind { return info }
        return nil
    }

    var track: TrackRow? {
        if case .track(let row) = kind { return row }
        return nil
    }

    var file: FolderFileInfo? {
        if case .file(let info) = kind { return info }
        return nil
    }
}

/// Stable negative ids for folders, files and placeholders, per path — the table's selection
/// and expansion survive every rebuild.
final class FolderOutlineIDs: @unchecked Sendable {
    private var ids: [String: Int64] = [:]
    private var next: Int64 = -1_000_000
    private let lock = NSLock()

    func folder(_ path: String) -> Int64 { id("d:" + path) }
    func file(_ path: String) -> Int64 { id("f:" + path) }
    func loading(_ folder: String) -> Int64 { id("l:" + folder) }

    private func id(_ key: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        if let id = ids[key] { return id }
        let id = next
        next -= 1
        ids[key] = id
        return id
    }
}

// MARK: - The filter in place (UC-SEARCH-01, V-FOLD.E02)

/// What the toolbar search matches in Folders: tracks (the track filter, SQL) and folders and
/// files by name. A folder stays visible when it or anything inside matches; folders that hold
/// matches open by themselves (not remembered).
struct FolderFilterMatch: Equatable, Sendable {
    /// Matching library tracks.
    var trackIDs: Set<Int64> = []
    /// Folders whose name matches (everything inside them shows when they are opened).
    var nameMatchedFolders: Set<String> = []
    /// Files not in the library whose name matches (relative paths).
    var nameMatchedFiles: Set<String> = []

    /// Folders shown: the name-matched ones and every folder above a match.
    func visibleFolders(catalog: FolderCatalog, root: String) -> Set<String> {
        var visible = Set<String>()
        func addChain(_ folder: String, includingSelf: Bool) {
            guard FolderPath.isWithin(folder, root) else { return }
            if includingSelf { visible.insert(folder) }
            for ancestor in FolderPath.ancestors(of: folder) where FolderPath.isWithin(ancestor, root) {
                visible.insert(ancestor)
            }
        }
        for id in trackIDs {
            if let folder = catalog.folderByTrackID[id] { addChain(folder, includingSelf: true) }
        }
        for folder in nameMatchedFolders { addChain(folder, includingSelf: true) }
        for file in nameMatchedFiles { addChain(FolderPlacement.folder(ofFile: file), includingSelf: true) }
        return visible
    }

    /// Folders opened by the filter: those holding a matching track or file, and every folder
    /// above a match (a name-matched folder itself stays as the user left it).
    func openedFolders(catalog: FolderCatalog, root: String) -> Set<String> {
        var opened = Set<String>()
        func open(_ folder: String, includingSelf: Bool) {
            if includingSelf, FolderPath.isWithin(folder, root) { opened.insert(folder) }
            for ancestor in FolderPath.ancestors(of: folder) where FolderPath.isWithin(ancestor, root) {
                opened.insert(ancestor)
            }
        }
        for id in trackIDs {
            if let folder = catalog.folderByTrackID[id] { open(folder, includingSelf: true) }
        }
        for file in nameMatchedFiles { open(FolderPlacement.folder(ofFile: file), includingSelf: true) }
        for folder in nameMatchedFolders { open(folder, includingSelf: false) }
        return opened
    }

    /// `folder` or a folder above it (within the root) matched by name.
    func isInsideNameMatch(_ folder: String) -> Bool {
        if nameMatchedFolders.contains(folder) { return true }
        return FolderPath.ancestors(of: folder).contains { nameMatchedFolders.contains($0) }
    }
}

// MARK: - Building the outline (pure, unit-tested)

/// Everything the outline is built from — the catalog (database), what was read from disk,
/// the loaded track rows and the user's choices.
struct FolderOutlineInput {
    /// The outline's root (`""` = the library folder; `Open ⌘↓` sets another).
    var root: String = ""
    var catalog: FolderCatalog = .empty
    /// Directories read from disk (ignored while the drive is away).
    var listings: [String: FolderListingResult] = [:]
    var isOffline = false
    /// Built rows of the tracks of expanded folders.
    var trackRows: [Int64: TrackRow] = [:]
    /// Folders whose tracks were fetched: an id still without a row there is gone (deleted
    /// meanwhile) and is left out instead of being asked for again.
    var loadedFolders: Set<String> = []
    var expanded: Set<String> = []
    /// Folders the filter opened that the user closed again (only while that filter is on).
    var collapsedByUser: Set<String> = []
    /// The table's sort, applied within each folder (`nil` = by title).
    var sort: TrackSortOrder? = TrackSortOrder(column: .title, ascending: true)
    var filter: FolderFilterMatch? = nil
    /// Not-in-library files per folder, subfolders included (nil until the disk was read).
    var notInLibraryCounts: [String: Int]? = nil
    var scanning: Set<String> = []
}

/// The built outline.
struct FolderOutline: Equatable, Sendable {
    /// The rows at the top (the root's contents).
    var rows: [FolderOutlineRow] = []
    /// Ids of the rows the table shows, in display order (expanded folders only).
    var order: [Int64] = []
    /// The folder each shown row lies in.
    var parentByID: [Int64: String] = [:]
    /// Shown folder rows by id.
    var foldersByID: [Int64: FolderRowInfo] = [:]
    /// Shown file rows by id.
    var filesByID: [Int64: FolderFileInfo] = [:]
    /// Shown track rows in display order, `position` 1…n (the queue context of ↩ and the
    /// track-table model's rows).
    var trackRows: [TrackRow] = []
    /// Expanded folders whose tracks aren't loaded yet.
    var foldersMissingTracks: Set<String> = []
    /// Expanded folders not read from disk yet (drive connected).
    var foldersToList: Set<String> = []

    static func build(_ input: FolderOutlineInput, ids: FolderOutlineIDs) -> FolderOutline {
        var builder = Builder(input: input, ids: ids)
        builder.prepareFilter()
        var outline = FolderOutline()
        outline.rows = builder.children(of: input.root)
        outline.foldersMissingTracks = builder.missingTracks
        outline.foldersToList = builder.toList
        var shownTracks: [TrackRow] = []
        func walk(_ rows: [FolderOutlineRow], parent: String) {
            // Only expanded folders are walked into: a collapsed folder's hidden child is
            // never shown.
            for row in rows {
                outline.order.append(row.id)
                outline.parentByID[row.id] = parent
                switch row.kind {
                case .folder(let info):
                    outline.foldersByID[row.id] = info
                    if info.isExpanded, let children = row.children { walk(children, parent: info.path) }
                case .track(let track):
                    shownTracks.append(track)
                case .file(let file):
                    outline.filesByID[row.id] = file
                case .loading:
                    break
                }
            }
        }
        walk(outline.rows, parent: input.root)
        outline.trackRows = shownTracks.enumerated().map { $0.element.repositioned($0.offset + 1) }
        return outline
    }

    private struct Builder {
        let input: FolderOutlineInput
        let ids: FolderOutlineIDs
        var missingTracks: Set<String> = []
        var toList: Set<String> = []
        var visibleFolders: Set<String>?
        var openedByFilter: Set<String> = []

        init(input: FolderOutlineInput, ids: FolderOutlineIDs) {
            self.input = input
            self.ids = ids
        }

        mutating func prepareFilter() {
            guard let filter = input.filter else { return }
            visibleFolders = filter.visibleFolders(catalog: input.catalog, root: input.root)
            openedByFilter = filter.openedFolders(catalog: input.catalog, root: input.root)
        }

        private func listing(_ folder: String) -> FolderListing? {
            input.isOffline ? nil : input.listings[folder]?.listing
        }

        private func isExpanded(_ folder: String) -> Bool {
            input.expanded.contains(folder) || (openedByFilter.contains(folder) && !input.collapsedByUser.contains(folder))
        }

        private func subfolderNames(_ folder: String) -> [String] {
            var names = input.catalog.folders[folder]?.childNames ?? []
            if let listing = listing(folder) { names.formUnion(listing.subfolders) }
            let descending = input.sort?.column == .title && input.sort?.ascending == false
            return names.filter(FolderPath.isListable).sorted { descending ? FolderSort.nameAscending($1, $0) : FolderSort.nameAscending($0, $1) }
        }

        private func unlistedFiles(_ folder: String) -> [String] {
            guard let listing = listing(folder) else { return [] }
            return listing.audioFiles.filter { !input.catalog.isKnownFile(FolderPath.join(folder, $0)) }
        }

        private func hasContent(_ folder: String) -> Bool {
            if let entry = input.catalog.folders[folder], !entry.childNames.isEmpty || !entry.directTrackIDs.isEmpty {
                return true
            }
            if input.isOffline { return false }
            guard let result = input.listings[folder] else { return true }  // not read yet: maybe
            guard let listing = result.listing else { return false }
            return !listing.subfolders.isEmpty || !unlistedFiles(folder).isEmpty
        }

        mutating func children(of folder: String) -> [FolderOutlineRow] {
            let filter = input.filter
            let insideMatch = filter?.isInsideNameMatch(folder) ?? true
            var rows: [FolderOutlineRow] = []

            if !input.isOffline, input.listings[folder] == nil { toList.insert(folder) }

            for name in subfolderNames(folder) {
                let path = FolderPath.join(folder, name)
                if let visibleFolders, !insideMatch, !visibleFolders.contains(path) { continue }
                rows.append(folderRow(path, name: name))
            }

            // Tracks directly in the folder, in the table's sort.
            let ids = input.catalog.folders[folder]?.directTrackIDs ?? []
            if !ids.isEmpty {
                var loaded: [TrackRow] = []
                var missing = false
                for (index, id) in ids.enumerated() {
                    if let filter, !insideMatch, !filter.trackIDs.contains(id) { continue }
                    guard let row = input.trackRows[id] else {
                        if !input.loadedFolders.contains(folder) { missing = true }
                        continue
                    }
                    loaded.append(row.repositioned(index + 1))
                }
                if missing { missingTracks.insert(folder) }
                let sorted = TrackRowSorter.sorted(loaded, by: input.sort ?? TrackSortOrder(column: .title, ascending: true))
                rows += sorted.map { FolderOutlineRow(id: $0.id, kind: .track($0)) }
                if missing, sorted.isEmpty {
                    rows.append(FolderOutlineRow(id: self.ids.loading(folder), kind: .loading))
                }
            }

            // Files on disk that aren't in the library (dimmed, `Not in library`).
            for name in unlistedFiles(folder) {
                let path = FolderPath.join(folder, name)
                if let filter, !insideMatch, !filter.nameMatchedFiles.contains(path) { continue }
                rows.append(FolderOutlineRow(id: self.ids.file(path), kind: .file(FolderFileInfo(path: path, name: name, folder: folder))))
            }
            return rows
        }

        private mutating func folderRow(_ path: String, name: String) -> FolderOutlineRow {
            let expanded = isExpanded(path)
            let result = input.isOffline ? nil : input.listings[path]
            var unreadable: String?
            if case .unreadable(let reason) = result { unreadable = reason }
            let info = FolderRowInfo(
                path: path,
                name: name,
                trackCount: input.catalog.trackCount(under: path),
                isManaged: ManagedFolders.isManaged(path),
                notInLibraryCount: input.isOffline ? nil : input.notInLibraryCounts?[path],
                unreadableReason: unreadable,
                isScanning: input.scanning.contains(path),
                isExpanded: expanded
            )
            let id = ids.folder(path)
            let children: [FolderOutlineRow]?
            if expanded {
                children = self.children(of: path)
            } else if hasContent(path) {
                // Hidden while collapsed; gives the row its triangle without reading anything.
                children = [FolderOutlineRow(id: ids.loading(path), kind: .loading)]
            } else {
                children = nil
            }
            return FolderOutlineRow(id: id, kind: .folder(info), children: children)
        }
    }
}

// MARK: - Files not in the library (V-FOLD.E08)

enum FolderNotInLibrary {
    /// Per folder read from disk: its audio files that no library track points at.
    static func files(listings: [String: FolderListingResult], catalog: FolderCatalog) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (folder, listed) in listings {
            guard let listing = listed.listing else { continue }
            let files = listing.audioFiles
                .map { FolderPath.join(folder, $0) }
                .filter { !catalog.isKnownFile($0) }
            if !files.isEmpty { result[folder] = files }
        }
        return result
    }

    /// Per folder: not-in-library files in it and every folder inside (only folders read).
    static func recursiveCounts(_ files: [String: [String]], folders: some Sequence<String>) -> [String: Int] {
        var counts: [String: Int] = [:]
        for folder in folders { counts[folder] = 0 }
        for (folder, names) in files {
            counts[folder, default: 0] += names.count
            for ancestor in FolderPath.ancestors(of: folder) {
                counts[ancestor, default: 0] += names.count
            }
        }
        return counts
    }

    /// The not-in-library files in `folder` and below, in path order.
    static func files(under folder: String, in files: [String: [String]]) -> [String] {
        files.filter { FolderPath.isWithin($0.key, folder) }
            .sorted { FolderSort.nameAscending($0.key, $1.key) }
            .flatMap(\.value)
    }

    /// `14 files in this folder aren’t in the library` (§15.9); the library folder at the root.
    static func headerText(count: Int, isLibraryFolder: Bool) -> String {
        let place = isLibraryFolder ? "the library folder" : "this folder"
        return "\(StatusBarText.count(count, "file", "files")) in \(place) \(count == 1 ? "isn’t" : "aren’t") in the library"
    }
}

// MARK: - Rows in a new place

extension TrackRow {
    /// The same row at another position (the outline numbers its shown tracks 1…n).
    func repositioned(_ position: Int) -> TrackRow {
        TrackRow(id: id, track: track, position: position, availability: availability, fileLocation: fileLocation,
                 title: title, artistText: artistText, albumText: albumText, genreText: genreText, timeText: timeText,
                 bpmText: bpmText, yearText: yearText, formatText: formatText, kbpsText: kbpsText, addedText: addedText,
                 addedSortValue: addedSortValue, energyLevel: energyLevel, danceLevel: danceLevel,
                 failureDetail: failureDetail)
    }
}
