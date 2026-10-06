import CoreTransferable
import Foundation
import UniformTypeIdentifiers

// MARK: - Drag payloads (DEC-040, UC-DND-01/02, PATTERN-DND.N01)
//
// What a drag out of MLM carries. Every draggable thing has **two representations**:
//
// 1. an internal one — `CodableRepresentation` under an exported, declared UTType
//    (`com.ilczuk.mlm.track`, `com.ilczuk.mlm.playlist`, declared in the Info.plist that
//    `scripts/run.sh` writes) carrying ids, the container it came from and the library id;
// 2. `public.file-url` (and with it `public.url`, URL's own representation) for the item's
//    library file — offered only when the file is local and reachable now (persisted
//    availability + drive state, decided when the drag starts, never a disk probe).
//
// Nothing else goes on the pasteboard: no source link, no plain-text source. The exported URL
// is the library file itself; the operation outside MLM is copy (`TrackDragConfiguration`),
// so Finder copies, Mail attaches and DJ software loads — MLM never moves or deletes its files
// because of a drag.
//
// A multi-row drag is one item per row (the table writes one item per selected row, in display
// order); a drop target receives `[TrackDragItem]` in that order (`TrackDragPayload`).

extension UTType {
    /// Tracks dragged inside MLM (ids). Declared in Info.plist (`scripts/run.sh`).
    static let draggedTracks = UTType(exportedAs: "com.ilczuk.mlm.track", conformingTo: .data)
    /// A playlist dragged inside MLM (id). Declared in Info.plist (`scripts/run.sh`).
    static let draggedPlaylist = UTType(exportedAs: "com.ilczuk.mlm.playlist", conformingTo: .data)
    /// The track drag of builds before W2-H (`TrackDragData` / `QueueRowDrag` JSON). Imported
    /// only — nothing exports it any more; declared as an imported type in Info.plist.
    static let legacyTrackDrag = UTType(importedAs: "com.musiclibrary.trackdrag", conformingTo: .data)
    /// A library file (`.mlibm`), declared by `scripts/run.sh` since A3.
    static let libraryPackage = UTType(exportedAs: "com.ilczuk.mlm.library", conformingTo: .package)
}

// MARK: - Tracks

/// One dragged track (one row of any track list, a queue row, the player's cover).
///
/// The JSON keeps the keys of the old `TrackDragData` / `QueueRowDrag` shape (`trackId`,
/// `sourcePlaylistId`, `queueEntryId`), so either side can read the other.
struct TrackDragItem: Codable, Transferable, Equatable, Hashable, Sendable {
    let trackId: Int64
    /// The playlist the row was dragged from (reorder vs. insert from elsewhere).
    var sourcePlaylistId: Int64?
    /// Set when the row is a queue entry (reorder inside the Queue panel).
    var queueEntryId: UUID?
    /// The library the track belongs to (`ActiveLibrary.libraryId`); a drop never crosses
    /// libraries. `nil` only in payloads of builds before W2-H.
    var libraryId: String?
    /// Absolute path of the track's library file when it is local and reachable now — decided
    /// when the drag starts. Not encoded: it leaves MLM only as the file URL.
    var filePath: String?
    /// A folder row of Folders (W3-FOLD, D-FOLD-FOLDER-TO-PLAYLIST): the item stands for every
    /// library track in that folder (relative to the library folder, subfolders included);
    /// `trackId` is 0. `DropLoader` turns it into the tracks (`FolderDragExpansion`) before any
    /// target sees it. Outside MLM it is the folder itself (`filePath`).
    var folderPath: String?
    /// The outline's sort when the folder was dragged (`TrackSortOrder.rawValue`): the tracks
    /// arrive in the order the outline shows them.
    var folderSort: String?
    /// An album card of the Albums grid (W4-2): the item stands for the album's listed tracks in
    /// album order; `trackId` is 0. `DropLoader` turns it into the tracks (`AlbumDragExpansion`)
    /// before any target sees it.
    var albumId: Int64?

    private enum CodingKeys: String, CodingKey {
        case trackId, sourcePlaylistId, queueEntryId, libraryId, folderPath, folderSort, albumId
    }

    init(trackId: Int64, sourcePlaylistId: Int64? = nil, queueEntryId: UUID? = nil,
         libraryId: String?, filePath: String? = nil) {
        self.trackId = trackId
        self.sourcePlaylistId = sourcePlaylistId
        self.queueEntryId = queueEntryId
        self.libraryId = libraryId
        self.filePath = filePath
    }

    /// A folder row dragged out of Folders: its tracks inside MLM, the folder outside.
    static func folder(_ relativePath: String, libraryId: String?, folderFilePath: String?, sort: TrackSortOrder?) -> TrackDragItem {
        var item = TrackDragItem(trackId: 0, libraryId: libraryId, filePath: folderFilePath)
        item.folderPath = relativePath
        item.folderSort = sort?.rawValue
        return item
    }

    /// An album card dragged out of the Albums grid: its tracks inside MLM.
    static func album(_ id: Int64, libraryId: String?) -> TrackDragItem {
        var item = TrackDragItem(trackId: 0, libraryId: libraryId)
        item.albumId = id
        return item
    }

    /// The item is a folder of Folders, not one track.
    var isFolder: Bool { folderPath != nil }

    /// The item is an album card, not one track.
    var isAlbum: Bool { albumId != nil }

    /// The library file (`public.file-url`), or nil when the track has no reachable file.
    var fileURL: URL? { filePath.map { URL(fileURLWithPath: $0) } }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .draggedTracks)
        // The old shape still arrives from a queue row or list of an older build.
        ProxyRepresentation(importing: { (legacy: LegacyTrackDrag) in
            TrackDragItem(trackId: legacy.trackId, sourcePlaylistId: legacy.sourcePlaylistId,
                          queueEntryId: legacy.queueEntryId, libraryId: nil)
        })
        // Finder, Mail, DJ software: the file itself, only when there is one (UC-DND-02).
        ProxyRepresentation(exporting: { (item: TrackDragItem) -> URL in
            guard let url = item.fileURL else { throw CocoaError(.fileNoSuchFile) }
            return url
        })
        .exportingCondition { $0.fileURL != nil }
    }
}

/// The JSON of the pre-W2-H track drag (`TrackDragData`, `QueueRowDrag`) under its old type.
struct LegacyTrackDrag: Codable, Transferable, Equatable, Sendable {
    let trackId: Int64
    var sourcePlaylistId: Int64?
    var queueEntryId: UUID?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .legacyTrackDrag)
    }
}

/// The dragged tracks of one drag, in the order they were dragged (display order).
struct TrackDragPayload: Equatable, Sendable {
    let items: [TrackDragItem]

    /// Track ids in drag order, each once (a folder item not yet expanded has none).
    var trackIDs: [Int64] {
        var seen = Set<Int64>()
        return items.filter { !$0.isFolder && !$0.isAlbum }.map(\.trackId).filter { seen.insert($0).inserted }
    }

    /// The one playlist every item was dragged from, if they share one.
    var sourcePlaylistID: Int64? {
        guard let first = items.first?.sourcePlaylistId,
              items.allSatisfy({ $0.sourcePlaylistId == first }) else { return nil }
        return first
    }

    /// Queue entries, when the drag is rows of the Queue panel.
    var queueEntryIDs: [UUID] { items.compactMap(\.queueEntryId) }

    /// `true` when an item carries another library's id. Items of builds before W2-H (no
    /// library id) are taken as this library's: only one library is open per process.
    func crossesLibraries(current libraryID: String?) -> Bool {
        guard let libraryID else { return false }
        return items.contains { item in item.libraryId.map { $0 != libraryID } ?? false }
    }

    /// The files that leave MLM (Finder, other apps), in drag order, and how many tracks have
    /// none (left out, UC-DND-02).
    var exportedFiles: (urls: [URL], leftOut: Int) {
        let urls = items.compactMap(\.fileURL)
        return (urls, items.count - urls.count)
    }
}

// MARK: - Playlists

/// One dragged playlist (sidebar row, card in All Playlists). Inside MLM it stands for its
/// tracks in playlist order (append, insert, Play Next) or for the playlist itself (sync
/// profile, playlist folder — W3-PL).
///
/// No file URLs yet: a playlist's files need its track list when the drag starts (the matrix
/// cell "Finder: copies its files" is W3-PL's, see the W2-H report).
struct PlaylistDragItem: Codable, Transferable, Equatable, Hashable, Sendable {
    let playlistId: Int64
    var libraryId: String?
    /// Set when the dragged row is a playlist folder (W3-PL: folders reorder among the top-level
    /// rows by drag; `playlistId` is then 0). Older payloads decode without it.
    var folderId: Int64? = nil

    /// A playlist folder row as a drag (reorder only; no other target takes it).
    static func folder(_ id: Int64, libraryId: String?) -> PlaylistDragItem {
        PlaylistDragItem(playlistId: 0, libraryId: libraryId, folderId: id)
    }

    /// The row it stands for in the sidebar's order.
    var sidebarItem: PlaylistSidebarItemID {
        folderId.map(PlaylistSidebarItemID.folder) ?? .playlist(playlistId)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .draggedPlaylist)
    }
}

// MARK: - Making items (no disk access)

/// Builds drag items from what a row or the player already knows: the persisted availability,
/// the library folder and the drive state. Never touches the disk (UC-TABLE-20).
struct TrackDragContext: Equatable, Sendable {
    /// `ActiveLibrary.libraryId` of the open library.
    var libraryID: String?
    /// The library folder (`MountObserver.watchedLibraryRoot`); nil without one.
    var libraryRoot: String?
    /// `/Volumes/‹name›` of the library's disk while it is not connected; nil = connected.
    var offlineVolumePath: String?

    /// The reachable library file of a track, or nil (UC-DND-02): only for `Local` tracks,
    /// only while their disk is connected, and only for a real path.
    static func filePath(organizedPath: String?, availability: TrackAvailability,
                         libraryRoot: String?, offlineVolumePath: String?) -> String? {
        guard availability == .local, let organizedPath, !organizedPath.isEmpty else { return nil }
        let location = TrackRowBuilder.fileLocation(organizedPath)
        if let offlineVolumePath, location.isOnVolume(offlineVolumePath) { return nil }
        switch location {
        case .none:
            return nil
        case .libraryFolder:
            guard let libraryRoot, !libraryRoot.isEmpty else { return nil }
            return URL(fileURLWithPath: libraryRoot).appendingPathComponent(organizedPath).path
        case .absolute:
            return organizedPath
        }
    }

    func item(for track: Track, availability: TrackAvailability? = nil,
              sourcePlaylistID: Int64? = nil, queueEntryID: UUID? = nil) -> TrackDragItem? {
        guard let id = track.id, id > 0 else { return nil }
        let path = Self.filePath(organizedPath: track.organizedPath,
                                 availability: availability ?? track.availability(),
                                 libraryRoot: libraryRoot, offlineVolumePath: offlineVolumePath)
        return TrackDragItem(trackId: id, sourcePlaylistId: sourcePlaylistID, queueEntryId: queueEntryID,
                             libraryId: libraryID, filePath: path)
    }

    func item(for row: TrackRow, sourcePlaylistID: Int64?) -> TrackDragItem? {
        item(for: row.track, availability: row.availability, sourcePlaylistID: sourcePlaylistID)
    }

    /// The open library's context, read now.
    @MainActor
    static func current(_ container: DependencyContainer) -> TrackDragContext {
        let drive = LibraryDriveState.current(container)
        return TrackDragContext(
            libraryID: container.activeLibrary?.libraryId,
            libraryRoot: container.mountObserver?.watchedLibraryRoot,
            offlineVolumePath: drive.isOffline ? container.mountObserver?.libraryVolumePath : nil
        )
    }
}
