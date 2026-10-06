import Foundation
import GRDB

// MARK: - Playlist folders (v45, DEC-003, UC-SIDE-08)

/// A playlist folder: a sidebar row that groups playlists (DEC-003). One level — folders hold
/// playlists, never other folders (`playlists.html` shows one level; `parent_id` is reserved).
/// Not to be confused with the disk folders of the Folders section.
struct PlaylistFolder: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    var id: Int64?
    var name: String
    /// Reserved for nesting; always nil (one level, enforced by `PlaylistFolderRepository`).
    var parentId: Int64? = nil
    /// Its place among the top-level rows (folders and top-level playlists share one order).
    var position: String?

    static let databaseTableName = "playlist_folders"

    enum CodingKeys: String, CodingKey {
        case id, name, position
        case parentId = "parent_id"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A row of the sidebar's Playlists section that has a place in the user's order.
enum PlaylistSidebarItemID: Hashable, Sendable {
    case playlist(Int64)
    case folder(Int64)
}

/// Where one playlist or folder sits: its folder (playlists only) and its position.
struct PlaylistPlacementState: Equatable, Sendable {
    let item: PlaylistSidebarItemID
    let folderID: Int64?
    let position: String?
}

/// Rows a reorder or move touched, as they were before and after — for exact undo / redo.
struct PlaylistOrderChange: Equatable, Sendable {
    var before: [PlaylistPlacementState]
    var after: [PlaylistPlacementState]

    var isEmpty: Bool { before == after }

    var inverted: PlaylistOrderChange { PlaylistOrderChange(before: after, after: before) }
}

/// A deleted folder and where its playlists were before and after the delete.
struct PlaylistFolderSnapshot: Equatable, Sendable {
    let folder: PlaylistFolder
    /// Its playlists inside it, in order (before the delete).
    let members: [PlaylistPlacementState]
    /// The same playlists at the top level, where the delete put them.
    let movedOut: [PlaylistPlacementState]
    /// Top-level rows the delete had to re-key to make room (restored first on undo).
    var relevel = PlaylistOrderChange(before: [], after: [])
}

/// The order of the sidebar's Playlists section — one comparator for the repository and the
/// tree the views draw (`PlaylistSidebarTree`), so both agree: placed rows by position (byte
/// order, as SQLite sorts), unplaced rows after them by name; ties: folders first, then name, id.
enum PlaylistSidebarOrder {
    struct Key: Equatable {
        let position: String?
        let isFolder: Bool
        let name: String
        let id: Int64
    }

    static func precedes(_ a: Key, _ b: Key) -> Bool {
        switch (a.position, b.position) {
        case (nil, .some): return false
        case (.some, nil): return true
        case let (pa?, pb?) where pa != pb:
            return Array(pa.utf8).lexicographicallyPrecedes(Array(pb.utf8))
        default:
            if a.isFolder != b.isFolder { return a.isFolder }
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.id < b.id
        }
    }

    static func key(_ playlist: Playlist) -> Key {
        Key(position: playlist.position, isFolder: false, name: playlist.name, id: playlist.id ?? 0)
    }

    static func key(_ folder: PlaylistFolder) -> Key {
        Key(position: folder.position, isFolder: true, name: folder.name, id: folder.id ?? 0)
    }
}

enum PlaylistFolderError: LocalizedError, PlainCauseError, Equatable {
    case folderNotFound
    case nameTaken(String)

    var errorDescription: String? { plainCause }

    var plainCause: String {
        switch self {
        case .folderNotFound: "the playlist folder no longer exists"
        case .nameTaken(let name): "another playlist folder is called “\(name)”"
        }
    }
}

/// Playlist folders and the manual order of the Playlists section (v45). Foreign keys stay
/// disabled, so the cascades are written here: deleting a folder moves its playlists up to the
/// top level (UC-SIDE-08) — it never deletes a playlist.
final class PlaylistFolderRepository: Sendable {
    private let database: any DatabaseWriter

    /// Default name of a new folder (Finder's `untitled folder`, `playlists.html` S-PLFOLDER-NEW).
    static let untitledFolderName = "untitled folder"

    init(database: any DatabaseWriter) {
        self.database = database
    }

    // MARK: Reading

    /// Every folder, in sidebar order.
    func fetchFolders() async throws -> [PlaylistFolder] {
        try await database.read { db in try Self.folders(db) }
    }

    func fetchFolder(id: Int64) async throws -> PlaylistFolder? {
        try await database.read { db in try PlaylistFolder.fetchOne(db, id: id) }
    }

    // MARK: Create, rename

    /// `untitled folder` (numbered when taken), placed first among the top-level rows.
    func createFolder(baseName: String = PlaylistFolderRepository.untitledFolderName) async throws -> PlaylistFolder {
        try await database.write { db in
            let taken = Set(try String.fetchAll(db, sql: "SELECT name FROM playlist_folders").map { $0.lowercased() })
            var folder = PlaylistFolder(
                id: nil,
                name: PlaylistRepository.numberedName(base: baseName, taken: taken),
                parentId: nil,
                position: try Self.firstPosition(db, folderID: nil)
            )
            try folder.insert(db)
            return folder
        }
    }

    /// Renames a folder; a name another folder has (any letter case) is refused.
    func renameFolder(id: Int64, to name: String) async throws {
        try await database.write { db in
            guard try PlaylistFolder.fetchOne(db, id: id) != nil else { throw PlaylistFolderError.folderNotFound }
            if let other = try PlaylistFolder.fetchOne(db, sql: """
                SELECT * FROM playlist_folders WHERE LOWER(name) = LOWER(?) AND id != ?
            """, arguments: [name, id]) {
                throw PlaylistFolderError.nameTaken(other.name)
            }
            try db.execute(sql: "UPDATE playlist_folders SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    // MARK: Delete, restore (UC-SIDE-08, UC-UNDO-02)

    /// Deletes the folder; its playlists move up to the top level, in their order, where the
    /// folder was. Returns everything an undo needs.
    func deleteFolderReturningSnapshot(id: Int64) async throws -> PlaylistFolderSnapshot {
        try await database.write { db in
            guard let folder = try PlaylistFolder.fetchOne(db, id: id) else { throw PlaylistFolderError.folderNotFound }
            let members = try Self.playlists(db, inFolder: id)
            let before = members.map { PlaylistPlacementState(item: .playlist($0.id ?? 0), folderID: id, position: $0.position) }
            // Where the folder was: just before the folder itself.
            let memberIDs = members.compactMap(\.id)
            let (keys, rekeyed) = try Self.levelKeys(db, folderID: nil, count: memberIDs.count, before: .folder(id), excluding: [])
            let relevel = try Self.change(db, from: rekeyed)
            var movedOut: [PlaylistPlacementState] = []
            for (memberID, position) in zip(memberIDs, keys) {
                try db.execute(sql: "UPDATE playlists SET folder_id = NULL, position = ? WHERE id = ?",
                               arguments: [position, memberID])
                movedOut.append(PlaylistPlacementState(item: .playlist(memberID), folderID: nil, position: position))
            }
            try db.execute(sql: "DELETE FROM playlist_folders WHERE id = ?", arguments: [id])
            return PlaylistFolderSnapshot(folder: folder, members: before, movedOut: movedOut, relevel: relevel)
        }
    }

    /// Puts a deleted folder back — same id when free, same name unless another folder took it
    /// meanwhile (then numbered), same position — and moves back the playlists that are still
    /// where the delete left them (one moved elsewhere since stays there).
    func restoreFolder(_ snapshot: PlaylistFolderSnapshot) async throws -> PlaylistFolder {
        try await database.write { db in
            // Top-level rows the delete re-keyed go back first (where nothing moved them since).
            _ = try Self.revert(db, snapshot.relevel)
            var folder = snapshot.folder
            if let id = folder.id, try PlaylistFolder.fetchOne(db, id: id) != nil {
                folder.id = nil
            }
            let taken = Set(try String.fetchAll(db, sql: "SELECT name FROM playlist_folders").map { $0.lowercased() })
            folder.name = PlaylistRepository.numberedName(base: folder.name, taken: taken)
            try folder.insert(db)
            guard let folderID = folder.id else { throw PlaylistFolderError.folderNotFound }
            let movedOut = Dictionary(snapshot.movedOut.map { ($0.item, $0) }, uniquingKeysWith: { first, _ in first })
            for member in snapshot.members {
                guard case .playlist(let playlistID) = member.item,
                      let expected = movedOut[member.item],
                      try Self.currentState(db, of: member.item) == expected else { continue }
                try db.execute(sql: "UPDATE playlists SET folder_id = ?, position = ? WHERE id = ?",
                               arguments: [folderID, member.position, playlistID])
            }
            return folder
        }
    }

    // MARK: Order and move (D-PL-CARD-REORDER, D-PL-PLAYLIST-TO-FOLDER, CM-SUB-MOVE)

    /// Places `items`, in this order, into `folderID` (nil = the top level) before `before` (nil =
    /// at the end of that level). Folders only move among the top-level rows (one level): a
    /// folder asked into a folder, and the folder itself as its own target, are left out.
    /// Rows of the target level without a position get one first (in their shown order), so
    /// the result is exact; every row whose folder or position changed is in the result.
    func move(_ items: [PlaylistSidebarItemID], into folderID: Int64?, before: PlaylistSidebarItemID?) async throws -> PlaylistOrderChange {
        try await database.write { db in
            try Self.move(db, items, into: folderID, before: before)
        }
    }

    /// The end of a level (`before: nil`) or its start, for `move`.
    func firstItem(inFolder folderID: Int64?) async throws -> PlaylistSidebarItemID? {
        try await database.read { db in try Self.level(db, folderID: folderID).first?.item }
    }

    /// Puts rows back where a change found them (undo) or left them (redo). Only rows that are
    /// still exactly where the change left them move; a row moved by something else since is
    /// left alone, and a playlist whose folder is gone goes to the top level. Returns the change
    /// actually applied (empty when nothing was left to move).
    func revert(_ change: PlaylistOrderChange) async throws -> PlaylistOrderChange {
        try await database.write { db in try Self.revert(db, change) }
    }

    static func revert(_ db: Database, _ change: PlaylistOrderChange) throws -> PlaylistOrderChange {
        let expected = Dictionary(change.after.map { ($0.item, $0) }, uniquingKeysWith: { first, _ in first })
        var applied = PlaylistOrderChange(before: [], after: [])
        for target in change.before {
            guard let now = try currentState(db, of: target.item), now == expected[target.item] else { continue }
            var folderID = target.folderID
            if let id = folderID, try PlaylistFolder.fetchOne(db, id: id) == nil { folderID = nil }
            let state = PlaylistPlacementState(item: target.item, folderID: folderID, position: target.position)
            try write(db, state)
            applied.before.append(now)
            applied.after.append(state)
        }
        return applied
    }

    // MARK: - Shared with PlaylistRepository (same transaction)

    /// Every folder, in sidebar order.
    static func folders(_ db: Database) throws -> [PlaylistFolder] {
        try PlaylistFolder.fetchAll(db).sorted { PlaylistSidebarOrder.precedes(PlaylistSidebarOrder.key($0), PlaylistSidebarOrder.key($1)) }
    }

    /// A position before every row of the level (a new playlist or folder goes first, Finder's
    /// new-folder behaviour, `playlists.html`).
    /// A re-keying it needs isn't recorded: it keeps the order, and undoing the creation only
    /// removes the new row.
    static func firstPosition(_ db: Database, folderID: Int64?) throws -> String {
        try normalizeLevel(db, folderID: folderID)
        let first = try level(db, folderID: folderID).first?.item
        return try levelKeys(db, folderID: folderID, count: 1, before: first, excluding: []).keys[0]
    }

    /// A position after every row of the level (New Playlist in Folder appends).
    static func lastPosition(_ db: Database, folderID: Int64?) throws -> String {
        try levelKeys(db, folderID: folderID, count: 1, before: nil, excluding: []).keys[0]
    }

    /// Keys for `count` rows placed, in order, before `before` (nil = at the end) among the
    /// level's rows other than `moving`. Rows without a position get one first; when no key
    /// fits, or a key is longer than `FractionalIndexer.renumberLength`, the whole level is
    /// re-keyed evenly in its shown order. Returns the re-keyed rows as they were before (for
    /// exact undo). Never an out-of-order key: throws when even that fails.
    static func levelKeys(_ db: Database, folderID: Int64?, count: Int, before: PlaylistSidebarItemID?,
                          excluding moving: Set<PlaylistSidebarItemID>) throws -> (keys: [String], rekeyed: [PlaylistPlacementState]) {
        func attempt(_ entries: [LevelEntry]) -> [String]? {
            let remaining = entries.filter { !moving.contains($0.item) }
            let insertAt = before.flatMap { target in remaining.firstIndex { $0.item == target } } ?? remaining.count
            var left = insertAt > 0 ? remaining[insertAt - 1].position : nil
            let right = insertAt < remaining.count ? remaining[insertAt].position : nil
            var keys: [String] = []
            for _ in 0..<count {
                guard let key = FractionalIndexer.key(between: left, and: right) else { return nil }
                keys.append(key)
                left = key
            }
            return keys
        }
        var rekeyed = try normalizeLevel(db, folderID: folderID)
        var entries = try level(db, folderID: folderID)
        var renumbered = false
        if entries.contains(where: { ($0.position?.utf8.count ?? 0) > FractionalIndexer.renumberLength }) {
            rekeyed += try renumberLevel(db, folderID: folderID, entries: entries)
            entries = try level(db, folderID: folderID)
            renumbered = true
        }
        if let keys = attempt(entries) { return (keys, firstStates(rekeyed)) }
        if !renumbered {
            rekeyed += try renumberLevel(db, folderID: folderID, entries: entries)
            entries = try level(db, folderID: folderID)
            if let keys = attempt(entries) { return (keys, firstStates(rekeyed)) }
        }
        throw PlaylistRepositoryError.noRoomForPosition
    }

    /// Evenly spaced keys for the level in its shown order; returns the rows' earlier states.
    private static func renumberLevel(_ db: Database, folderID: Int64?, entries: [LevelEntry]) throws -> [PlaylistPlacementState] {
        let keys = FractionalIndexer.evenlySpaced(count: entries.count)
        var before: [PlaylistPlacementState] = []
        for (entry, key) in zip(entries, keys) where entry.position != key {
            let folder = entry.item.isFolder ? nil : folderID
            before.append(PlaylistPlacementState(item: entry.item, folderID: folder, position: entry.position))
            try write(db, PlaylistPlacementState(item: entry.item, folderID: folder, position: key))
        }
        return before
    }

    /// The earliest recorded state per row (a row both placed and renumbered keeps its first).
    private static func firstStates(_ states: [PlaylistPlacementState]) -> [PlaylistPlacementState] {
        var seen = Set<PlaylistSidebarItemID>()
        return states.filter { seen.insert($0.item).inserted }
    }

    /// A change from rows' earlier states to their current ones.
    static func change(_ db: Database, from before: [PlaylistPlacementState]) throws -> PlaylistOrderChange {
        var change = PlaylistOrderChange(before: [], after: [])
        for state in before {
            guard let now = try currentState(db, of: state.item) else { continue }
            change.before.append(state)
            change.after.append(now)
        }
        return change
    }

    struct LevelEntry: Equatable {
        let item: PlaylistSidebarItemID
        let position: String?
        let name: String
    }

    /// The rows of one level in sidebar order. The top level holds the folders and the
    /// playlists without a folder — or with a folder that no longer exists (no foreign keys).
    static func level(_ db: Database, folderID: Int64?) throws -> [LevelEntry] {
        var keyed: [(PlaylistSidebarOrder.Key, LevelEntry)] = []
        if let folderID {
            for playlist in try playlists(db, inFolder: folderID) {
                guard let id = playlist.id else { continue }
                keyed.append((PlaylistSidebarOrder.key(playlist), LevelEntry(item: .playlist(id), position: playlist.position, name: playlist.name)))
            }
        } else {
            for folder in try PlaylistFolder.fetchAll(db) {
                guard let id = folder.id else { continue }
                keyed.append((PlaylistSidebarOrder.key(folder), LevelEntry(item: .folder(id), position: folder.position, name: folder.name)))
            }
            let topLevel = try Playlist.fetchAll(db, sql: """
                SELECT * FROM playlists
                WHERE folder_id IS NULL OR folder_id NOT IN (SELECT id FROM playlist_folders)
            """)
            for playlist in topLevel {
                guard let id = playlist.id else { continue }
                keyed.append((PlaylistSidebarOrder.key(playlist), LevelEntry(item: .playlist(id), position: playlist.position, name: playlist.name)))
            }
        }
        return keyed.sorted { PlaylistSidebarOrder.precedes($0.0, $1.0) }.map(\.1)
    }

    static func playlists(_ db: Database, inFolder folderID: Int64) throws -> [Playlist] {
        try Playlist.fetchAll(db, sql: "SELECT * FROM playlists WHERE folder_id = ?", arguments: [folderID])
            .sorted { PlaylistSidebarOrder.precedes(PlaylistSidebarOrder.key($0), PlaylistSidebarOrder.key($1)) }
    }

    /// Gives every row of the level without a position one after the placed rows, in the order
    /// they are shown (by name). Returns the rows it placed, as they were before.
    @discardableResult
    static func normalizeLevel(_ db: Database, folderID: Int64?) throws -> [PlaylistPlacementState] {
        let entries = try level(db, folderID: folderID)
        let unplaced = entries.filter { $0.position == nil }
        guard !unplaced.isEmpty else { return [] }
        var tail = entries.last { $0.position != nil }?.position
        var before: [PlaylistPlacementState] = []
        for entry in unplaced {
            // After the last key a key always exists (`strictBetween(left, nil)`).
            let position = FractionalIndexer.key(between: tail, and: nil) ?? "a0"
            before.append(PlaylistPlacementState(item: entry.item, folderID: folderID, position: nil))
            try write(db, PlaylistPlacementState(item: entry.item, folderID: folderID, position: position))
            tail = position
        }
        return before
    }

    static func currentState(_ db: Database, of item: PlaylistSidebarItemID) throws -> PlaylistPlacementState? {
        switch item {
        case .playlist(let id):
            guard let row = try Row.fetchOne(db, sql: "SELECT folder_id, position FROM playlists WHERE id = ?", arguments: [id]) else { return nil }
            var folderID: Int64? = row["folder_id"]
            if let folder = folderID, try PlaylistFolder.fetchOne(db, id: folder) == nil { folderID = nil }
            return PlaylistPlacementState(item: item, folderID: folderID, position: row["position"])
        case .folder(let id):
            guard let folder = try PlaylistFolder.fetchOne(db, id: id) else { return nil }
            return PlaylistPlacementState(item: item, folderID: nil, position: folder.position)
        }
    }

    private static func write(_ db: Database, _ state: PlaylistPlacementState) throws {
        switch state.item {
        case .playlist(let id):
            try db.execute(sql: "UPDATE playlists SET folder_id = ?, position = ? WHERE id = ?",
                           arguments: [state.folderID, state.position, id])
        case .folder(let id):
            try db.execute(sql: "UPDATE playlist_folders SET position = ? WHERE id = ?", arguments: [state.position, id])
        }
    }

    static func move(_ db: Database, _ items: [PlaylistSidebarItemID], into folderID: Int64?,
                     before: PlaylistSidebarItemID?) throws -> PlaylistOrderChange {
        if let folderID, try PlaylistFolder.fetchOne(db, id: folderID) == nil { throw PlaylistFolderError.folderNotFound }
        var seen = Set<PlaylistSidebarItemID>()
        let moving = try items.filter { item in
            guard seen.insert(item).inserted else { return false }
            switch item {
            case .folder(let id):
                // One level: a folder stays at the top level and is never its own target.
                guard folderID == nil, try PlaylistFolder.fetchOne(db, id: id) != nil else { return false }
                return true
            case .playlist(let id):
                return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM playlists WHERE id = ?)", arguments: [id]) ?? false
            }
        }
        guard !moving.isEmpty else { return PlaylistOrderChange(before: [], after: []) }
        let movingSet = Set(moving)
        // Nothing changes (`Move to Folder ▸` its own folder, a row dropped into its own gap):
        // no write, no step (W3-PL review S5).
        let current = try level(db, folderID: folderID).map(\.item)
        // "Before a row that moves itself" = before the first row after it that stays.
        var before = before
        if let target = before, movingSet.contains(target), let index = current.firstIndex(of: target) {
            before = current[index...].first { !movingSet.contains($0) }
        }
        if moving.allSatisfy(current.contains) {
            let remaining = current.filter { !movingSet.contains($0) }
            let insertAt = before.flatMap { remaining.firstIndex(of: $0) } ?? remaining.count
            var result = remaining
            result.insert(contentsOf: moving, at: insertAt)
            if result == current { return PlaylistOrderChange(before: [], after: []) }
        }
        var beforeStates: [PlaylistSidebarItemID: PlaylistPlacementState] = [:]
        for item in moving {
            beforeStates[item] = try currentState(db, of: item)
        }
        let (keys, rekeyed) = try levelKeys(db, folderID: folderID, count: moving.count, before: before, excluding: movingSet)
        var after: [PlaylistPlacementState] = []
        for (item, position) in zip(moving, keys) {
            let state = PlaylistPlacementState(item: item, folderID: item.isFolder ? nil : folderID, position: position)
            try write(db, state)
            after.append(state)
        }
        // The rows placed or re-keyed to make room are part of the change (exact undo).
        var change = PlaylistOrderChange(before: [], after: [])
        for state in rekeyed where !movingSet.contains(state.item) {
            change.before.append(state)
            if let now = try currentState(db, of: state.item) { change.after.append(now) }
        }
        for state in after {
            if let old = beforeStates[state.item] {
                change.before.append(old)
                change.after.append(state)
            }
        }
        return change
    }
}

extension PlaylistRepository {
    /// The folders and order of the same library database (no container entry of its own).
    var folders: PlaylistFolderRepository { PlaylistFolderRepository(database: database) }
}

extension PlaylistSidebarItemID {
    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}
