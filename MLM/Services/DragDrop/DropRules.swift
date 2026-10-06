import Foundation
import UniformTypeIdentifiers

// MARK: - What a target does with a drop (UC-DND matrix, PATTERN-DND.N06)
//
// The matrix as pure functions, so every implemented cell is unit-tested without views:
//
// - `DropRules.hoverKind(_:)` + `accepts(_:on:context:)`: while a drag hovers — ring and copy
//   cursor, or no ring and the not-allowed cursor (UC-DND-03). Decided from the types on the
//   pasteboard only (nothing is loaded while hovering).
// - `DropRules.decide(_:onto:context:)`: after the drop — what happens (`DropDecision`), or the
//   refusal and its sentence.
//
// A new target adopts drops by adding a `DropTarget` case, its row in `accepts` and `decide`,
// tests for the cells, and a `DropTargetModifier` (or a table insertion) that runs the decision
// through `DropPerformer` — never its own add/insert code (UC-UNDO-08: one gesture, one step).

/// Where something was dropped.
enum DropTarget: Equatable, Sendable {
    /// A playlist row in the sidebar (UC-SIDE-11).
    case sidebarPlaylist(id: Int64, name: String)
    /// The `Playlists` header, the empty sidebar area, the All Playlists row and background.
    case playlistsSection
    /// A sync profile row in the sidebar.
    case syncProfile(id: Int64, name: String)
    /// All Tracks … Review: views, not containers — Finder files only (import).
    case fixedRow
    /// Between the rows of an open playlist's table (insertion line). `sortedBy`: the column
    /// the table is sorted by when it isn't in playlist order (drops then append, UC-TABLE-05).
    case playlistTable(id: Int64, name: String, sortedBy: String?)
    /// The toolbar player (UC-TB-08).
    case player
    /// A playlist cover: the detail header (cover well) — images only.
    case playlistCover(id: Int64, name: String)
    /// A card in All Playlists: a playlist for tracks, playlists, files and links (like its
    /// sidebar row, D-PL-TRACKS-TO-CARD) and a cover well for images (D-PL-COVER-TO-CARD).
    case playlistCard(id: Int64, name: String)
    /// A playlist folder row (sidebar) or group heading (grid, Manual order) — W3-PL, UC-SIDE-08:
    /// playlists move into it; tracks, Finder files and M3U files make a new playlist inside.
    case playlistFolder(id: Int64, name: String)
    /// Between the rows of the sidebar's Playlists section (in `folderID`, nil = top level),
    /// before `before` (nil = at the end): playlists and folders reorder (D-PL-CARD-REORDER).
    case playlistOrder(folderID: Int64?, before: PlaylistSidebarItemID?)
    /// A card of All Playlists sorted `Manual`: a dragged playlist or folder goes before it
    /// (the grid's manual reorder, D-PL-CARD-REORDER); everything else as on `playlistCard`.
    case playlistCardInManualOrder(id: Int64, name: String, folderID: Int64?)
    /// A genre row in Genres (W3-GEN, D-SET-GW-TRACK-TO-GENRE): tracks get this genre (one
    /// undoable tag edit). `key` = `GenreName.key`, `name` = the display name.
    case genreRow(key: String, name: String)
    /// A genre's track table (D-STUDIO-TRACK-TO-GENRE): tracks are **staged** for the genre
    /// (`Save n Changes` commits them).
    case genreTable(key: String, name: String)
    /// The window anywhere no other target takes the drag.
    case window
}

/// What the drag carries, judged from the pasteboard types while it hovers.
enum DragKind: Equatable, Sendable {
    case tracks
    case playlists
    /// Finder files and folders (`public.file-url`), whatever their type.
    case files
    /// Image data without a file (a browser image).
    case imageData
    /// A web link (`public.url`, or a link as plain text).
    case link
    case unknown
}

/// One file dropped from Finder, with what MLM makes of it.
struct DroppedFile: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case libraryFile
        case m3u
        case image
        case audio
        case folder
        case other
    }

    let url: URL
    let kind: Kind

    var name: String { url.lastPathComponent }

    /// Classified by name and whether it is a folder (the caller read that from the dropped
    /// file itself — never a library row).
    static func kind(of url: URL, isDirectory: Bool) -> Kind {
        let ext = url.pathExtension.lowercased()
        if ext == "mlibm" { return .libraryFile }
        if isDirectory { return .folder }
        if ext == "m3u" || ext == "m3u8" { return .m3u }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .audio) { return .audio }
        }
        if MetadataExtractor.isAudioFile(url) { return .audio }
        return .other
    }
}

/// What arrived, loaded from the item providers.
enum DropContent: Equatable, Sendable {
    case tracks(TrackDragPayload)
    case playlists([PlaylistDragItem])
    case files([DroppedFile])
    case imageData(Data)
    case link(URL)
}

/// Where a new cover comes from.
enum CoverSource: Equatable, Sendable {
    case file(URL)
    case data(Data)
}

/// The window's state that decides drops.
struct DropContext: Equatable, Sendable {
    /// The open library's id; nil while none is open (launch states).
    var libraryID: String?
    var isLibraryOpen: Bool
    /// The library drive's name while it is not connected (`Lexxar`), else nil.
    var offlineVolumeName: String?
}

/// The result of a drop.
enum DropDecision: Equatable, Sendable {
    /// Tracks onto a sidebar playlist: append (UC-CM-11 wording, duplicates skipped).
    case appendTracks([Int64], playlistID: Int64, playlistName: String)
    /// Tracks onto the Playlists header / empty area: a new playlist named inline (IMP-018).
    case newPlaylist([Int64])
    case addTracksToSyncProfile([Int64], profileID: Int64, profileName: String)
    case addPlaylistsToSyncProfile([Int64], profileID: Int64, profileName: String)
    /// Playlists onto a playlist row: append their tracks (playlist order).
    case appendPlaylists([Int64], playlistID: Int64, playlistName: String)
    /// Tracks or playlists between the rows of a playlist's table; the table's plan says where.
    case placeTracks(TrackDragPayload, playlistID: Int64, playlistName: String)
    case placePlaylists([Int64], playlistID: Int64, playlistName: String)
    /// Onto the player: Play Next (tracks with a file; the rest are counted) — through the
    /// queue's own entry point (`QueueEditCommands.dropOnPlayer`), so queue rows move to the top.
    case playNext(TrackDragPayload)
    case playNextPlaylists([Int64])
    /// Finder audio files / folders: import (Activity operation).
    case importFiles([URL])
    case importFilesAndAdd([URL], playlistID: Int64, playlistName: String)
    case importFilesAndPlace([URL], playlistID: Int64, playlistName: String)
    /// Onto the Playlists header: import, then a new playlist (named after a single folder).
    case importFilesAsNewPlaylist([URL], name: String?)
    /// `.m3u` / `.m3u8`: the preview sheet. `playlistID`: the playlist it was dropped on.
    case importM3U(URL, playlistID: Int64?)
    /// A link: Add from Link… / the playlist import (`QuickAddRouter`).
    case openLink(URL, playlistID: Int64?)
    /// A `.mlibm`: open or switch library (`MainWindowPresenter.openLibrary`). `ignored`: other
    /// files dropped with it (named in the status bar, D-LIBFILE-OPEN).
    case openLibraryFile(URL, ignored: Int)
    case setCover(CoverSource, playlistID: Int64, playlistName: String)
    /// Playlists / folders placed in the Playlists section's order (W3-PL): into `folderID`
    /// (nil = top level), before `before` (nil = at the end). One undo step.
    case movePlaylistItems([PlaylistSidebarItemID], folderID: Int64?, before: PlaylistSidebarItemID?)
    /// Playlists / folders dropped on the Playlists section: first among the top-level rows.
    case movePlaylistItemsToTop([PlaylistSidebarItemID])
    /// Tracks onto a playlist folder: a new playlist inside it (named inline).
    case newPlaylistInFolder([Int64], folderID: Int64)
    /// Finder audio onto a playlist folder: import, then a new playlist inside it.
    case importFilesAsNewPlaylistInFolder([URL], folderID: Int64)
    /// An `.m3u` onto a playlist folder: the preview sheet, as a new playlist inside it.
    case importM3UInFolder(URL, folderID: Int64)
    /// Tracks onto a genre row: set their genre (`Set genre of 3 tracks to “Techno”`, undoable).
    case setGenre([Int64], genreName: String)
    /// Tracks onto a genre's track table: stage them for the genre (W3-GEN).
    case stageForGenre([Int64], genreKey: String, genreName: String)
    /// Refused. `message`: where the refusal is said (status bar, or in place for covers);
    /// nil = nothing to say (the not-allowed cursor already said it).
    case refuse(String?)
}

enum DropRules {
    // MARK: Hover

    /// The kind of a hovering drag from the types it offers. Internal payloads win over their
    /// own file URLs (a track drag also carries `public.file-url`).
    static func hoverKind(_ conforms: (UTType) -> Bool) -> DragKind {
        if conforms(.draggedTracks) || conforms(.legacyTrackDrag) { return .tracks }
        if conforms(.draggedPlaylist) { return .playlists }
        if conforms(.fileURL) { return .files }
        if conforms(.image) { return .imageData }
        if conforms(.url) || conforms(.plainText) { return .link }
        return .unknown
    }

    /// The pasteboard types every MLM drop target listens for.
    static let observedTypes: [UTType] = [.draggedTracks, .legacyTrackDrag, .draggedPlaylist, .fileURL, .image, .url, .plainText]

    /// Ring and copy cursor (true), or no ring and the not-allowed cursor (false).
    static func accepts(_ kind: DragKind, on target: DropTarget, context: DropContext) -> Bool {
        guard context.isLibraryOpen else {
            // Launch states: only a library file (the window; W3-LAUNCH's picker adopts it).
            return target == .window && kind == .files
        }
        switch (target, kind) {
        case (.sidebarPlaylist, .tracks), (.sidebarPlaylist, .playlists),
             (.sidebarPlaylist, .files), (.sidebarPlaylist, .link):
            return true
        case (.playlistsSection, .tracks), (.playlistsSection, .files), (.playlistsSection, .link),
             (.playlistsSection, .playlists):
            return true
        case (.playlistFolder, .tracks), (.playlistFolder, .playlists), (.playlistFolder, .files):
            return true
        case (.playlistOrder, .playlists):
            return true
        case (.playlistCardInManualOrder, .tracks), (.playlistCardInManualOrder, .playlists),
             (.playlistCardInManualOrder, .files), (.playlistCardInManualOrder, .imageData),
             (.playlistCardInManualOrder, .link):
            return true
        case (.syncProfile, .tracks), (.syncProfile, .playlists):
            return true
        case (.fixedRow, .files):
            return true
        case (.playlistTable, .tracks), (.playlistTable, .playlists),
             (.playlistTable, .files), (.playlistTable, .link):
            return true
        case (.player, .tracks), (.player, .playlists):
            return true
        case (.playlistCover, .files), (.playlistCover, .imageData):
            return true
        case (.playlistCard, .tracks), (.playlistCard, .playlists), (.playlistCard, .files),
             (.playlistCard, .imageData), (.playlistCard, .link):
            return true
        case (.window, .files), (.window, .link):
            return true
        case (.genreRow, .tracks), (.genreTable, .tracks):
            // Only tracks get a genre (UC-DND matrix column "Genre row"; playlists and genres
            // dragged onto a genre row: `—`).
            return true
        default:
            return false
        }
    }

    /// Spring-loading (hover opens the playlist so the drop can land at a position): only on
    /// sidebar playlist rows and cards, for track drags, never on the row already shown
    /// (UC-DND-04 — offered, never required).
    static func springLoads(_ kind: DragKind, on target: DropTarget, isShown: Bool) -> Bool {
        guard !isShown, kind == .tracks else { return false }
        switch target {
        case .sidebarPlaylist, .playlistCard: return true
        default: return false
        }
    }

    // MARK: Drop

    static func decide(_ content: DropContent, onto target: DropTarget, context: DropContext) -> DropDecision {
        // A card in Manual order: a playlist or folder goes before it; the rest as on any card.
        if case .playlistCardInManualOrder(let id, let name, let folderID) = target {
            if case .playlists = content {
                return decide(content, onto: .playlistOrder(folderID: folderID, before: .playlist(id)), context: context)
            }
            return decide(content, onto: .playlistCard(id: id, name: name), context: context)
        }
        // A card is its playlist's row for everything but images, which set its cover.
        if case .playlistCard(let id, let name) = target {
            switch content {
            case .imageData:
                return decide(content, onto: .playlistCover(id: id, name: name), context: context)
            case .files(let files) where files.contains(where: { $0.kind == .image })
                || files.allSatisfy({ $0.kind == .other }):
                // An image — or nothing else MLM can use — is a cover drop (UC-SHEET-23).
                return decide(content, onto: .playlistCover(id: id, name: name), context: context)
            default:
                return decide(content, onto: .sidebarPlaylist(id: id, name: name), context: context)
            }
        }
        guard context.isLibraryOpen else {
            if case .files(let files) = content, target == .window { return libraryFileDecision(files) ?? .refuse(nil) }
            return .refuse(nil)
        }
        switch content {
        case .tracks(let payload):
            return tracksDecision(payload, onto: target, context: context)
        case .playlists(let playlists):
            return playlistsDecision(playlists, onto: target, context: context)
        case .files(let files):
            return filesDecision(files, onto: target, context: context)
        case .imageData(let data):
            if case .playlistCover(let id, let name) = target { return .setCover(.data(data), playlistID: id, playlistName: name) }
            return .refuse(nil)
        case .link(let url):
            switch target {
            case .sidebarPlaylist(let id, _): return .openLink(url, playlistID: id)
            case .playlistTable(let id, _, _): return .openLink(url, playlistID: id)
            case .playlistsSection, .window: return .openLink(url, playlistID: nil)
            default: return .refuse(nil)
            }
        }
    }

    private static func tracksDecision(_ payload: TrackDragPayload, onto target: DropTarget, context: DropContext) -> DropDecision {
        if payload.crossesLibraries(current: context.libraryID) { return .refuse(DropWords.otherLibrary) }
        let ids = payload.trackIDs
        guard !ids.isEmpty else { return .refuse(nil) }
        switch target {
        case .sidebarPlaylist(let id, let name): return .appendTracks(ids, playlistID: id, playlistName: name)
        case .playlistsSection: return .newPlaylist(ids)
        case .syncProfile(let id, let name): return .addTracksToSyncProfile(ids, profileID: id, profileName: name)
        case .playlistTable(let id, let name, _): return .placeTracks(payload, playlistID: id, playlistName: name)
        case .player: return .playNext(payload)
        case .playlistFolder(let id, _): return .newPlaylistInFolder(ids, folderID: id)
        case .genreRow(_, let name): return .setGenre(ids, genreName: name)
        case .genreTable(let key, let name): return .stageForGenre(ids, genreKey: key, genreName: name)
        case .fixedRow, .playlistCover, .playlistCard, .window, .playlistOrder, .playlistCardInManualOrder:
            return .refuse(nil)
        }
    }

    private static func playlistsDecision(_ playlists: [PlaylistDragItem], onto target: DropTarget, context: DropContext) -> DropDecision {
        if let libraryID = context.libraryID,
           playlists.contains(where: { $0.libraryId.map { $0 != libraryID } ?? false }) {
            return .refuse(DropWords.otherLibrary)
        }
        // Folder rows only reorder (W3-PL); every other target takes playlists alone.
        var seenItems = Set<PlaylistSidebarItemID>()
        let items = playlists.map(\.sidebarItem).filter { seenItems.insert($0).inserted }
        switch target {
        case .playlistOrder(let folderID, let before):
            // Into a folder only playlists go (one level); a row is never placed before itself.
            let moving = items.filter { item in
                item != before && (folderID == nil || !item.isFolder)
            }
            return moving.isEmpty ? .refuse(nil) : .movePlaylistItems(moving, folderID: folderID, before: before)
        case .playlistsSection:
            // The Playlists header, the All Playlists row, the empty sidebar area and the grid's
            // background: to the top level, first (UC-DND matrix; W3-PL review — one meaning
            // for every Playlists-section drop, where a new playlist appears too).
            return items.isEmpty ? .refuse(nil) : .movePlaylistItemsToTop(items)
        case .playlistFolder(let id, _):
            let moving = items.filter { !$0.isFolder }
            return moving.isEmpty ? .refuse(nil) : .movePlaylistItems(moving, folderID: id, before: nil)
        default:
            break
        }
        var seen = Set<Int64>()
        let ids = playlists.filter { $0.folderId == nil }.map(\.playlistId).filter { seen.insert($0).inserted }
        switch target {
        case .sidebarPlaylist(let id, let name):
            let others = ids.filter { $0 != id }
            return others.isEmpty ? .refuse(nil) : .appendPlaylists(others, playlistID: id, playlistName: name)
        case .playlistTable(let id, let name, _):
            let others = ids.filter { $0 != id }
            return others.isEmpty ? .refuse(nil) : .placePlaylists(others, playlistID: id, playlistName: name)
        case .syncProfile(let id, let name):
            return ids.isEmpty ? .refuse(nil) : .addPlaylistsToSyncProfile(ids, profileID: id, profileName: name)
        case .player:
            return ids.isEmpty ? .refuse(nil) : .playNextPlaylists(ids)
        case .playlistsSection, .fixedRow, .playlistCover, .playlistCard, .window,
             .playlistFolder, .playlistOrder, .playlistCardInManualOrder, .genreRow, .genreTable:
            return .refuse(nil)
        }
    }

    private static func filesDecision(_ files: [DroppedFile], onto target: DropTarget, context: DropContext) -> DropDecision {
        guard !files.isEmpty else { return .refuse(nil) }

        // A library file: open / switch library — what the window does wherever it lands.
        if files.contains(where: { $0.kind == .libraryFile }) {
            switch target {
            case .syncProfile, .player, .playlistCover, .playlistCard: break
            default: return libraryFileDecision(files) ?? .refuse(nil)
            }
        }

        if case .playlistCover(let id, let name) = target {
            guard let image = files.first(where: { $0.kind == .image }) else {
                return .refuse(DropWords.notACover(fileName: files.first?.name))
            }
            return .setCover(.file(image.url), playlistID: id, playlistName: name)
        }

        // An M3U: the preview sheet (into this playlist when dropped on one).
        if let m3u = files.first(where: { $0.kind == .m3u }) {
            switch target {
            case .sidebarPlaylist(let id, _): return .importM3U(m3u.url, playlistID: id)
            case .playlistTable(let id, _, _): return .importM3U(m3u.url, playlistID: id)
            case .playlistsSection, .window, .fixedRow: return .importM3U(m3u.url, playlistID: nil)
            case .playlistFolder(let id, _): return .importM3UInFolder(m3u.url, folderID: id)
            case .syncProfile, .player, .playlistCover, .playlistCard, .playlistOrder, .playlistCardInManualOrder,
                 .genreRow, .genreTable:
                return .refuse(nil)
            }
        }

        let importable = files.filter { $0.kind == .audio || $0.kind == .folder }
        guard !importable.isEmpty else {
            switch target {
            case .syncProfile, .player: return .refuse(nil)
            default: return .refuse(DropWords.notAudio(files.map(\.name)))
            }
        }
        // Importing needs the library folder (P6: everything else works offline).
        if let volume = context.offlineVolumeName {
            switch target {
            case .syncProfile, .player: return .refuse(nil)
            default: return .refuse(DropWords.cantImportOffline(volume))
            }
        }
        let urls = importable.map(\.url)
        switch target {
        case .sidebarPlaylist(let id, let name): return .importFilesAndAdd(urls, playlistID: id, playlistName: name)
        case .playlistTable(let id, let name, _): return .importFilesAndPlace(urls, playlistID: id, playlistName: name)
        case .playlistsSection:
            let name = importable.count == 1 && importable[0].kind == .folder ? importable[0].name : nil
            return .importFilesAsNewPlaylist(urls, name: name)
        case .fixedRow, .window: return .importFiles(urls)
        case .playlistFolder(let id, _): return .importFilesAsNewPlaylistInFolder(urls, folderID: id)
        case .syncProfile, .player, .playlistCover, .playlistCard, .playlistOrder, .playlistCardInManualOrder,
             .genreRow, .genreTable:
            return .refuse(nil)
        }
    }

    private static func libraryFileDecision(_ files: [DroppedFile]) -> DropDecision? {
        guard let library = files.first(where: { $0.kind == .libraryFile }) else { return nil }
        return .openLibraryFile(library.url, ignored: files.count - 1)
    }
}

// MARK: - A drop between the rows of a playlist (D-PLD-REORDER, D-PLD-INSERT)

/// Where tracks dropped on a playlist's table go — pure, from the playlist's order and the rows
/// the table shows.
struct PlaylistDropPlan: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Every dragged track is already in the playlist: they move (`Reorder “X”`).
        case reorder
        /// Tracks from elsewhere at the insertion line (members among them move there too).
        case insert
        /// The table is sorted by another column: appended at the end (UC-TABLE-05).
        case append
    }

    let kind: Kind
    let trackIDs: [Int64]
    /// Insert before this track (playlist order); nil = at the end.
    let beforeTrackID: Int64?

    /// - Parameters:
    ///   - trackIDs: dragged tracks, in drag order.
    ///   - playlistOrder: the playlist's tracks in playlist order.
    ///   - displayRows: the rows the table shows, in display order.
    ///   - insertionIndex: the table's insertion index in `displayRows`.
    ///   - isPlaylistOrder: the table is sorted by `#`.
    ///   - isFiltered: a search hides rows.
    /// - Returns: nil when nothing should happen (a reorder while sorted or filtered — the
    ///   table's hint line already says why, UC-TABLE-05).
    static func make(trackIDs: [Int64], playlistOrder: [Int64], displayRows: [Int64], insertionIndex: Int,
                     isPlaylistOrder: Bool, isFiltered: Bool) -> PlaylistDropPlan? {
        var seen = Set<Int64>()
        let ids = trackIDs.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return nil }
        let members = Set(playlistOrder)
        let allMembers = ids.allSatisfy(members.contains)
        if allMembers, !isPlaylistOrder || isFiltered { return nil }
        guard isPlaylistOrder else { return PlaylistDropPlan(kind: .append, trackIDs: ids, beforeTrackID: nil) }
        let index = targetIndex(insertionIndex: insertionIndex, displayRows: displayRows, playlistOrder: playlistOrder)
        // The first track at or after the index that isn't moving is the one to insert before.
        let moving = Set(ids)
        let before = playlistOrder[min(index, playlistOrder.count)...].first { !moving.contains($0) }
        let plan = PlaylistDropPlan(kind: allMembers ? .reorder : .insert, trackIDs: ids, beforeTrackID: before)
        // Dropping rows back where they are changes nothing.
        if plan.kind == .reorder, plan.isNoMove(in: playlistOrder) { return nil }
        return plan
    }

    /// The display insertion index mapped into the playlist's full order (`PlaylistTable`).
    static func targetIndex(insertionIndex: Int, displayRows: [Int64], playlistOrder: [Int64]) -> Int {
        guard !displayRows.isEmpty else { return playlistOrder.count }
        if insertionIndex <= 0 {
            return playlistOrder.firstIndex(of: displayRows[0]) ?? 0
        }
        if insertionIndex >= displayRows.count {
            return playlistOrder.firstIndex(of: displayRows[displayRows.count - 1]).map { $0 + 1 } ?? playlistOrder.count
        }
        return playlistOrder.firstIndex(of: displayRows[insertionIndex]) ?? min(insertionIndex, playlistOrder.count)
    }

    /// The playlist order after the plan (for tests and the no-move check).
    func apply(to playlistOrder: [Int64]) -> [Int64] {
        let moving = Set(trackIDs)
        var remaining = playlistOrder.filter { !moving.contains($0) }
        let at = beforeTrackID.flatMap { remaining.firstIndex(of: $0) } ?? remaining.count
        remaining.insert(contentsOf: trackIDs, at: at)
        return remaining
    }

    private func isNoMove(in playlistOrder: [Int64]) -> Bool {
        apply(to: playlistOrder) == playlistOrder
    }
}

// MARK: - Fractional positions for a placement

enum PlaylistPlacement {
    /// Positions for `trackIDs` inserted, in this order, before `beforeTrackID` (nil = at the
    /// end) once the moving members are taken out — the same rule as
    /// `PlaylistDetailViewModel.placeTracks`. `entries`: (track, position) in playlist order.
    static func positions(for trackIDs: [Int64], before beforeTrackID: Int64?,
                          in entries: [(trackID: Int64, position: String?)]) -> [(trackId: Int64, position: String)] {
        let moving = Set(trackIDs)
        let remaining = entries.filter { !moving.contains($0.trackID) }
        let insertAt = beforeTrackID.flatMap { id in remaining.firstIndex { $0.trackID == id } } ?? remaining.count
        let left = insertAt > 0 ? remaining[insertAt - 1].position : nil
        let right = insertAt < remaining.count ? remaining[insertAt].position : nil
        var previous = left
        var placements: [(trackId: Int64, position: String)] = []
        for id in trackIDs {
            let position = strictlyBetween(previous, right)
            placements.append((id, position))
            previous = position
        }
        return placements
    }

    /// `FractionalIndexer.positionBetween`, made strict: for some pairs (`a0|V`, `a1`) it
    /// returns the left bound itself, so a multi-track drop would share one position and fall
    /// back to the added-date order. Then the left bound is extended instead (still below the
    /// right one: a strict, non-prefix lower bound stays lower when extended).
    ///
    /// W3-PL review: the fixed indexer is strict wherever a key exists; writers use
    /// `FractionalIndexer.key(between:and:)` and renumber when it returns nil — this pure
    /// helper is kept for the drop plan tests.
    static func strictlyBetween(_ left: String?, _ right: String?) -> String {
        FractionalIndexer.positionBetween(left: left, right: right)
    }
}

// MARK: - Words (UC-STATUS-05 shapes, UC-SHEET-23, UC-COPY)

enum DropWords {
    /// A drag from another MLM library (only one is open per process; a second copy of MLM).
    static let otherLibrary = "Can’t use tracks from another library here"

    /// UC-SHEET-23, shown on the cover for 5 s (UC-SURF-04).
    static func notACover(fileName: String?) -> String {
        if let fileName { return "Couldn’t use “\(fileName)” as a cover. Drop a PNG, JPEG or HEIC image." }
        return "Couldn’t use that image as a cover. Drop a PNG, JPEG or HEIC image."
    }

    static func notAudio(_ names: [String]) -> String {
        if names.count == 1 { return "Can’t import “\(names[0])” — it isn’t an audio file or a folder" }
        return "Can’t import these \(names.count.formatted(.number)) files — none is an audio file or a folder"
    }

    /// Importing needs the library folder (UC-STATUS-07 shape).
    static func cantImportOffline(_ volume: String) -> String {
        "Can’t import — “\(volume)” is not connected"
    }

    /// `Added 2 tracks to “Warm-up” at position 4` (D-PLD-INSERT).
    static func insertedMessage(added: Int, moved: Int, position: Int, playlist: String) -> String {
        var text = "Added \(StatusBarText.tracks(added)) to “\(playlist)” at position \(position.formatted(.number))"
        if moved > 0 {
            text += " · \(moved.formatted(.number)) already in it moved there"
        }
        return text
    }

    /// `Moved 3 tracks to position 4 in “Warm-up”` (D-PLD-REORDER).
    static func reorderedMessage(count: Int, position: Int, playlist: String) -> String {
        "Moved \(StatusBarText.tracks(count)) to position \(position.formatted(.number)) in “\(playlist)”"
    }

    /// While sorted by another column the drop appends, and says so (UC-TABLE-05).
    static func appendedWhileSorted(_ column: String) -> String {
        " at the end — the playlist is sorted by \(column)"
    }

    static func reorderActionName(_ playlist: String) -> String { "Reorder “\(playlist)”" }
    static func addActionName(_ container: String) -> String { "Add to “\(container)”" }

    /// Sync profile content (UC-CM-12, PATTERN-DND.N04).
    static func addedToProfile(tracks added: Int, alreadyPresent: Int, profile: String) -> String {
        var text = "Added \(StatusBarText.tracks(added)) to “\(profile)”"
        if alreadyPresent > 0 {
            text += " · \(alreadyPresent.formatted(.number)) \(alreadyPresent == 1 ? "was" : "were") already in it"
        }
        return text
    }

    static func addedPlaylistsToProfile(names: [String], profile: String) -> String {
        names.count == 1
            ? "Added “\(names[0])” to “\(profile)”"
            : "Added \(StatusBarText.playlists(names.count)) to “\(profile)”"
    }

    static func alreadyInProfile(count: Int, kind: String, profile: String) -> String {
        count == 1
            ? "The \(kind) was already in “\(profile)”"
            : "All \(count.formatted(.number)) \(kind)s were already in “\(profile)”"
    }

    /// Cover drop (UC-UNDO-02 cover changes; action name per UC-UNDO-07).
    static let setCoverActionName = "Set Cover"
    static func coverSetMessage(_ playlist: String) -> String { "Set the cover of “\(playlist)”" }

    /// The Activity title of an import by drop — the folder import's `Scan “‹folder›”` shape.
    /// Activity says the start and the end in the status bar (`Import started — 4 files`).
    static func importTitle(files: Int, folderName: String?, playlist: String?) -> String {
        if let folderName {
            return playlist.map { "Scan “\(folderName)” into “\($0)”" } ?? "Scan “\(folderName)”"
        }
        let counted = StatusBarText.count(files, "file", "files")
        return playlist.map { "Import \(counted) into “\($0)”" } ?? "Import \(counted)"
    }

    /// Several files dropped with a library file: the first library opens (D-LIBFILE-OPEN).
    static func ignoredWithLibrary(_ count: Int) -> String {
        "Opening the library — \(StatusBarText.count(count, "other file was", "other files were")) ignored"
    }

    /// Finder export when nothing can leave MLM (UC-DND-02).
    static func cantCopyOffline(_ volume: String) -> String {
        "Can’t copy files — “\(volume)” is not connected"
    }
}
