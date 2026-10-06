import Foundation

// MARK: - A folder as its tracks (CM-FOLD-TREE, D-FOLD-FOLDER-TO-PLAYLIST)

/// Every library track in a folder (subfolders included) in the order the outline shows them:
/// the folders inside first (by name), each with its own contents, then the folder's own
/// tracks in the table's sort. Used by the folder menu (Play, Add to Playlist ▸, …) and by a
/// dragged folder row.
enum FolderTrackOrder {
    /// Pure: the ids in outline order from the catalog and the built rows of its tracks.
    static func orderedTrackIDs(in folder: String, catalog: FolderCatalog, rows: [Int64: TrackRow],
                                sort: TrackSortOrder?) -> [Int64] {
        guard let entry = catalog.folders[folder] else { return [] }
        let descending = sort?.column == .title && sort?.ascending == false
        let names = entry.childNames.sorted { descending ? FolderSort.nameAscending($1, $0) : FolderSort.nameAscending($0, $1) }
        var result: [Int64] = []
        for name in names {
            result += orderedTrackIDs(in: FolderPath.join(folder, name), catalog: catalog, rows: rows, sort: sort)
        }
        let own = entry.directTrackIDs.enumerated().compactMap { index, id in rows[id]?.repositioned(index + 1) }
        result += TrackRowSorter.sorted(own, by: sort ?? TrackSortOrder(column: .title, ascending: true)).map(\.id)
        return result
    }

    /// Several folders and tracks of one selection, in that order, each track once.
    static func merged(_ lists: [[Int64]]) -> [Int64] {
        var seen = Set<Int64>()
        return lists.flatMap { $0 }.filter { seen.insert($0).inserted }
    }
}

/// Loads a folder's tracks from the database (no disk access).
struct FolderTrackLoader: Sendable {
    let queries: FolderQueries
    let libraryRoot: String

    @MainActor
    static func current(_ container: DependencyContainer = .shared) -> FolderTrackLoader? {
        guard let queries = FolderQueries.current(container),
              let root = container.mountObserver?.watchedLibraryRoot, !root.isEmpty else { return nil }
        return FolderTrackLoader(queries: queries, libraryRoot: root)
    }

    /// The tracks of `folders` in outline order, each once.
    func tracks(in folders: [String], sort: TrackSortOrder?, catalog: FolderCatalog? = nil) async -> [Track] {
        guard let catalog = await resolvedCatalog(catalog) else { return [] }
        var ids: [Int64] = []
        for folder in folders {
            ids += collectIDs(folder, catalog: catalog)
        }
        let tracks = (try? await queries.tracks(ids: FolderTrackOrder.merged([ids]))) ?? []
        let rows = Dictionary(TrackRowBuilder.build(tracks).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = FolderTrackOrder.merged(folders.map {
            FolderTrackOrder.orderedTrackIDs(in: $0, catalog: catalog, rows: rows, sort: sort)
        })
        let byID = Dictionary(tracks.compactMap { track in track.id.map { ($0, track) } }, uniquingKeysWith: { first, _ in first })
        return ordered.compactMap { byID[$0] }
    }

    private func resolvedCatalog(_ catalog: FolderCatalog?) async -> FolderCatalog? {
        if let catalog { return catalog }
        return try? await queries.catalog(libraryRoot: libraryRoot)
    }

    private func collectIDs(_ folder: String, catalog: FolderCatalog) -> [Int64] {
        guard let entry = catalog.folders[folder] else { return [] }
        return entry.childNames.flatMap { collectIDs(FolderPath.join(folder, $0), catalog: catalog) } + entry.directTrackIDs
    }
}

/// A dragged folder row becomes its tracks when it is dropped (`DropLoader`): one item per
/// track, in outline order, from the same library. Items of another library are kept as they
/// are (the target refuses them).
@MainActor
enum FolderDragExpansion {
    static func expand(_ items: [TrackDragItem], container: DependencyContainer = .shared) async -> [TrackDragItem] {
        let libraryID = container.activeLibrary?.libraryId
        let loader = FolderTrackLoader.current(container)
        var result: [TrackDragItem] = []
        for item in items {
            guard let folder = item.folderPath else {
                result.append(item)
                continue
            }
            if let itemLibrary = item.libraryId, let libraryID, itemLibrary != libraryID {
                result.append(item)
                continue
            }
            guard let loader else { continue }
            let sort = item.folderSort.flatMap(TrackSortOrder.init(rawValue:))
            let tracks = await loader.tracks(in: [folder], sort: sort)
            let context = TrackDragContext.current(container)
            result += tracks.compactMap { context.item(for: $0) }
        }
        return result
    }
}
