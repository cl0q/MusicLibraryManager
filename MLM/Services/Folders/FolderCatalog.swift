import Foundation
import GRDB

// MARK: - The library's tracks by folder (SQL, never the disk — UC-TABLE-21, DEC-014)

/// Every library track that lies in the library folder, grouped by folder — built from one
/// query over `tracks` per library folder (and per refresh). Counts per folder (`48 tracks`),
/// the folders that hold library tracks, the tracks directly in a folder and the status bar's
/// totals all come from here, so the outline works the same with the drive away (V-FOLD.N06).
///
/// Pure value; `FolderQueries.catalog(libraryRoot:)` builds it off the main actor.
struct FolderCatalog: Sendable, Equatable {
    struct Folder: Sendable, Equatable {
        /// Library tracks in this folder and every folder inside it.
        var trackCount = 0
        /// Names of the folders directly inside that hold library tracks.
        var childNames: Set<String> = []
        /// Library tracks directly in this folder, in database order.
        var directTrackIDs: [Int64] = []
    }

    /// Relative folder path → folder. The library folder (`""`) is always present.
    var folders: [String: Folder] = ["": Folder()]
    /// The folder each library track lies in.
    var folderByTrackID: [Int64: String] = [:]
    /// Match keys (`FolderPath.matchKey`) of every path a library file may have — a file on
    /// disk with one of them is in the library (`Not in library` = none of them).
    var knownFileKeys: Set<String> = []

    static let empty = FolderCatalog()

    /// One stored track: id and its two paths.
    struct Row: Sendable, Equatable {
        let id: Int64
        let organizedPath: String?
        let originalPath: String
    }

    static func build(_ rows: [Row], libraryRoot: String) -> FolderCatalog {
        var catalog = FolderCatalog()
        for row in rows {
            for key in FolderPlacement.knownFileKeys(organizedPath: row.organizedPath, originalPath: row.originalPath,
                                                      libraryRoot: libraryRoot) {
                catalog.knownFileKeys.insert(key)
            }
            guard let file = FolderPlacement.relativeFilePath(organizedPath: row.organizedPath,
                                                              originalPath: row.originalPath,
                                                              libraryRoot: libraryRoot) else { continue }
            let folder = FolderPlacement.folder(ofFile: file)
            catalog.folderByTrackID[row.id] = folder
            catalog.folders[folder, default: Folder()].directTrackIDs.append(row.id)
            // Count it in its folder and every folder above; register each folder with its parent.
            var current = folder
            while true {
                catalog.folders[current, default: Folder()].trackCount += 1
                guard let parent = FolderPath.parent(of: current) else { break }
                let name = FolderPath.components(current).last ?? current
                catalog.folders[parent, default: Folder()].childNames.insert(name)
                current = parent
            }
        }
        return catalog
    }

    func folder(_ path: String) -> Folder? { folders[path] }

    /// Library tracks in `folder` and below.
    func trackCount(under folder: String) -> Int { folders[folder]?.trackCount ?? 0 }

    /// Folders inside `folder` (any depth) that hold library tracks.
    func folderCount(under folder: String) -> Int {
        folders.keys.reduce(0) { count, path in
            count + (path != folder && FolderPath.isWithin(path, folder) ? 1 : 0)
        }
    }

    /// Track ids in `folder` and below, in outline order: the folders inside first (by name),
    /// then the folder's own tracks in `order` (ids → sort key given by the caller).
    func trackIDs(under folder: String, ordering: (([Int64]) -> [Int64])? = nil) -> [Int64] {
        guard let entry = folders[folder] else { return [] }
        var result: [Int64] = []
        for name in entry.childNames.sorted(by: FolderSort.nameAscending) {
            result += trackIDs(under: FolderPath.join(folder, name), ordering: ordering)
        }
        result += ordering?(entry.directTrackIDs) ?? entry.directTrackIDs
        return result
    }

    /// Whether the file at `relative` (in the library folder) is a library track's file.
    func isKnownFile(_ relative: String) -> Bool {
        knownFileKeys.contains(FolderPath.matchKey(relative))
    }
}

/// Folder names sort like Finder: numbers by value, case-insensitive.
enum FolderSort {
    static func nameAscending(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

// MARK: - Queries

/// Read-only queries of the Folders place. A sibling of `TrackRepository` like
/// `TrackScopeQueries` (the repository keeps its database private to its file).
struct FolderQueries: Sendable {
    let database: any DatabaseReader

    @MainActor
    static func current(_ container: DependencyContainer = .shared) -> FolderQueries? {
        container.databaseManager.map { FolderQueries(database: $0.pool) }
    }

    /// The catalog of the library folder: one query, placement and grouping off the main actor.
    func catalog(libraryRoot: String) async throws -> FolderCatalog {
        let rows = try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, organized_path, original_path FROM tracks
                WHERE organized_path IS NOT NULL AND organized_path <> ''
                """).map { row in
                FolderCatalog.Row(id: row["id"], organizedPath: row["organized_path"], originalPath: row["original_path"] ?? "")
            }
        }
        return await Task.detached(priority: .userInitiated) {
            FolderCatalog.build(rows, libraryRoot: libraryRoot)
        }.value
    }

    /// Full tracks for `ids` (the rows of expanded folders).
    func tracks(ids: [Int64]) async throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        return try await database.read { db in
            var result: [Track] = []
            // SQLite's variable limit: fetch in chunks.
            var start = 0
            while start < ids.count {
                let chunk = Array(ids[start..<min(start + 900, ids.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                result += try Track.fetchAll(db, sql: "SELECT * FROM tracks WHERE id IN (\(placeholders))",
                                             arguments: StatementArguments(chunk))
                start += 900
            }
            return result
        }
    }

    /// Ids of the tracks the search filter matches (the in-place filter, UC-SEARCH-01) —
    /// the same predicate as All Tracks (`TrackSearchSQL`).
    func matchingTrackIDs(_ filter: SearchFilter) async throws -> Set<Int64> {
        let (predicate, arguments) = TrackSearchSQL.predicate(for: filter)
        return try await database.read { db in
            Set(try Int64.fetchAll(db, sql: """
                SELECT id FROM tracks
                WHERE organized_path IS NOT NULL AND organized_path <> '' AND (\(predicate))
                """, arguments: arguments))
        }
    }
}
