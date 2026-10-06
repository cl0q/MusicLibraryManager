import AppKit
import SwiftUI

// MARK: - What folder and file rows do (CM-FOLD-TREE, V-FOLD.N02/menu, D-FOLD-*)

/// The actions of folder and file rows. Track rows use the shared `TrackListActions`; a folder
/// acts through the same shared commands on its tracks (subfolders included, display order).
@MainActor
struct FolderActions {
    let model: FolderViewModel
    let trackActions: TrackListActions
    let shell: ShellActions?
    let statusBar: StatusBarCenter?
    let undo: UndoCenter?
    var container: DependencyContainer = .shared

    private var offlineVolumeName: String? {
        let drive = LibraryDriveState.current(container)
        return drive.isOffline ? drive.volumeName : nil
    }

    // MARK: Drag (D-FOLD-FOLDER-TO-PLAYLIST, UC-DND-06)

    /// A folder row drags as its tracks inside MLM and as the folder itself outside (while the
    /// drive is connected). Built when the drag starts; no disk access.
    func dragItem(for folder: FolderRowInfo, context: TrackDragContext) -> TrackDragItem {
        let reachable = context.offlineVolumePath == nil ? model.url(folder.path)?.path : nil
        if let reachable { FolderDragMemory.shared.remember(reachable) }
        return TrackDragItem.folder(folder.path, libraryId: context.libraryID, folderFilePath: reachable, sort: model.sortOrder)
    }

    /// A file that isn't in the library drags to Finder as the file.
    func fileURL(_ file: FolderFileInfo) -> URL {
        model.url(file.path) ?? URL(fileURLWithPath: file.path)
    }

    // MARK: Drop (D-FOLD-FILES-FROM-FINDER)

    /// Finder audio files / folders dropped on a folder row: imported into the library through
    /// `Import Files or Folder…` (copied in when they lie elsewhere). The table's own rows
    /// (library files, a dragged folder row) are left out — nothing moves inside the library.
    func drop(_ urls: [URL], on folder: FolderRowInfo) {
        let external = urls.filter { url in
            guard url.isFileURL else { return false }
            if FolderDragMemory.shared.contains(url.standardizedFileURL.path) { return false }
            if let root = model.libraryRoot, let relative = FolderPath.relative(url.path, libraryRoot: root),
               model.catalog.isKnownFile(relative) {
                return false
            }
            return true
        }
        guard !external.isEmpty else { return }
        let target = DropTarget.folderRow(path: folder.path, name: folder.name)
        let performer = DropPerformer(container: container, shell: shell, statusBar: statusBar, undo: undo ?? .main)
        let container = self.container
        Task {
            // The dropped items' own "is a folder" flag, read off the main actor (they may lie
            // on a disk that is just waking up).
            let files = await Task.detached(priority: .userInitiated) {
                external.map { url in
                    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    return DroppedFile(url: url, kind: DroppedFile.kind(of: url, isDirectory: isDirectory))
                }
            }.value
            performer.perform(DropRules.decide(.files(files), onto: target, context: DropContext.current(container)))
        }
    }

    // MARK: Menu items

    /// The tracks the rows stand for (folders: subfolders included), in display order.
    private func tracks(_ ids: Set<Int64>, _ run: @escaping @MainActor ([Track]) -> Void) {
        Task { run(await model.tracks(forRows: ids)) }
    }

    private func names(_ ids: Set<Int64>) -> [String] {
        model.outline.order.filter(ids.contains).compactMap { model.folder(id: $0)?.name }
    }

    /// Play: the folder's tracks that can play now, from the first (UC-PRIM-01 for a list).
    func play(_ ids: Set<Int64>) {
        let name = names(ids).first ?? model.rootName
        tracks(ids) { tracks in
            let live = TrackTableLiveState.drive(container)
            let playable = TrackRowBuilder.build(tracks).filter { row in
                row.availability == .local
                    && !TrackRowPresentation.isUnreachable(availability: row.availability, fileLocation: row.fileLocation, live: live)
            }
            guard let first = playable.first else {
                if let volume = offlineVolumeName, !tracks.isEmpty {
                    statusBar?.post(TrackPrimaryAction.driveNotConnectedMessage(volume))
                } else {
                    statusBar?.post(FolderMenuText.nothingToPlay(name, hasTracks: !tracks.isEmpty))
                }
                return
            }
            trackActions.recordPlaybackOrigin(trackID: first.id)
            trackActions.configuration.activate?(first.track, playable.map(\.track))
        }
    }

    func playNext(_ ids: Set<Int64>) {
        tracks(ids) { TrackCommandActions.playNext($0, undo: undo, container: container) }
    }

    func addToQueue(_ ids: Set<Int64>) {
        tracks(ids) { TrackCommandActions.addToQueue($0, undo: undo, container: container) }
    }

    func addToPlaylist(_ playlistID: Int64, _ ids: Set<Int64>) {
        tracks(ids) { TrackCommandActions.addToPlaylist(playlistID, tracks: $0, shell: shell) }
    }

    /// `New Playlist from Folder`: named after the folder (numbered when taken), named inline.
    func newPlaylist(_ ids: Set<Int64>) {
        let folderNames = names(ids)
        tracks(ids) { tracks in
            let trackIDs = tracks.compactMap(\.id)
            guard !trackIDs.isEmpty else {
                statusBar?.post(FolderMenuText.nothingToPlay(folderNames.first ?? model.rootName, hasTracks: false))
                return
            }
            if folderNames.count == 1, let shell {
                Task { await shell.edits.newPlaylist(named: folderNames[0], fromTrackIDs: trackIDs) }
            } else {
                TrackCommandActions.newPlaylistFromSelection(tracks, shell: shell)
            }
        }
    }

    func addToSyncProfile(_ profile: SyncProfile, _ ids: Set<Int64>) {
        guard let profileID = profile.id else { return }
        tracks(ids) { tracks in
            guard let shell else { return }
            Task { await shell.edits.addTracks(tracks.compactMap(\.id), toSyncProfile: profileID, name: profile.name) }
        }
    }

    func newSyncProfile(_ ids: Set<Int64>) {
        tracks(ids) { TrackCommandActions.newSyncProfileFromSelection($0) }
    }

    func scan(_ folder: FolderRowInfo) {
        Task { await model.scan(folder.path) }
    }

    func importNotInLibrary(_ folder: FolderRowInfo) {
        Task { await model.importNotInLibrary(under: folder.path) }
    }

    func importFiles(_ files: [FolderFileInfo]) {
        Task { await model.importFiles(files.map(\.path)) }
    }

    /// Show in Finder (⇧⌘R): the folders or files selected in Finder.
    func showInFinder(_ relativePaths: [String]) {
        let urls = relativePaths.compactMap(model.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Copy Path: one absolute path per line (UC-CM-13: folder → `Copy Path`).
    func copyPaths(_ relativePaths: [String]) {
        let paths = relativePaths.compactMap { model.url($0)?.path }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// ⌘C: `Title — Artist` lines of the selected tracks; with only folders or files, their paths.
    func copyItems(_ selection: Set<Int64>) -> [NSItemProvider] {
        let rows = model.trackList.selectedRows(selection)
        if !rows.isEmpty {
            return [NSItemProvider(object: TrackCommandActions.titleArtistLines(rows.map(\.track)) as NSString)]
        }
        let paths = model.outline.order.filter(selection.contains).compactMap { id in
            (model.folder(id: id)?.path ?? model.file(id: id)?.path).flatMap { model.url($0)?.path }
        }
        guard !paths.isEmpty else { return [] }
        return [NSItemProvider(object: paths.joined(separator: "\n") as NSString)]
    }
}

/// The folder paths a drag from the outline carried — a drop of the outline's own folder row
/// back onto the outline is not an import (MLM never moves files inside the library).
@MainActor
final class FolderDragMemory {
    static let shared = FolderDragMemory()
    private var paths: [String: Date] = [:]

    func remember(_ path: String) {
        paths[URL(fileURLWithPath: path).standardizedFileURL.path] = Date()
    }

    func contains(_ path: String) -> Bool {
        let cutoff = Date().addingTimeInterval(-600)
        paths = paths.filter { $0.value > cutoff }
        return paths[path] != nil
    }
}

/// Sentences of the folder menu (UC-COPY).
enum FolderMenuText {
    /// `“2026” has no tracks in the library yet.` / `Nothing in “2026” can play now.`
    static func nothingToPlay(_ name: String, hasTracks: Bool) -> String {
        hasTracks ? "Nothing in “\(name)” can play now." : "“\(name)” has no tracks in the library yet."
    }

    /// `Import File` · `Import 14 Files` (CM-FOLD-TREE.N07, V-FOLD.N02/menu).
    static func importFiles(_ count: Int) -> String {
        count == 1 ? "Import File" : "Import \(count.formatted(.number)) Files"
    }

    /// `3 folders` · `2 files` · `5 items` (UC-CM-04 header line).
    static func header(folders: Int, tracks: Int, files: Int) -> String {
        if tracks == 0, files == 0 { return StatusBarText.folders(folders) }
        if folders == 0, tracks == 0 { return StatusBarText.count(files, "file", "files") }
        return StatusBarText.count(folders + tracks + files, "item", "items")
    }
}

// MARK: - The context menu (DEC-039 order)

/// What the right-clicked rows get: folders → the folder menu (CM-FOLD-TREE, also acting on
/// tracks selected with them); tracks only → the shared track menu (container `.folder`, no
/// Remove from ‹Container›); files only → the file menu (V-FOLD.N02/menu).
struct FolderOutlineMenu: View {
    let ids: Set<Int64>
    let model: FolderViewModel
    let actions: TrackListActions
    let folderActions: FolderActions
    let live: TrackTableLive

    var body: some View {
        let ordered = model.outline.order.filter(ids.contains)
        let folders = ordered.compactMap { model.folder(id: $0) }
        let files = ordered.compactMap { model.file(id: $0) }
        let trackRows = model.trackList.selectedRows(ids)
        if !folders.isEmpty {
            FolderMenu(folders: folders, trackCount: trackRows.count, fileCount: files.count, ids: ids,
                       model: model, actions: folderActions, offlineVolumeName: live.state.offlineVolumeName)
        } else if !trackRows.isEmpty {
            trackMenu(trackRows)
        } else if !files.isEmpty {
            FileMenu(files: files, actions: folderActions)
        }
    }

    @ViewBuilder
    private func trackMenu(_ rows: [TrackRow]) -> some View {
        let context = TrackMenuContext(container: actions.configuration.listContext.container,
                                       canActivate: true, canRemoveFromContainer: false, canAddToSyncProfile: true)
        let menuModel = TrackMenuModel.make(subject: TrackMenuSubject(rows: rows, live: live.state), context: context)
        TrackMenu(model: menuModel, rows: rows, actions: actions, playlists: TrackMenuSources.shared.playlists,
                  syncProfiles: TrackMenuSources.shared.syncProfiles, offlineVolumeName: live.state.offlineVolumeName)
    }
}

/// CM-FOLD-TREE: Open ⌘↓ · Play — Play Next · Add to Queue — Add to Playlist ▸ (New Playlist
/// from Folder first) · Add to Sync Profile ▸ — Scan This Folder ⌘R · Import ‹n› Files — Show
/// in Finder ⇧⌘R · Copy Path. No Remove group; moving and renaming stay in Finder.
private struct FolderMenu: View {
    let folders: [FolderRowInfo]
    let trackCount: Int
    let fileCount: Int
    let ids: Set<Int64>
    let model: FolderViewModel
    let actions: FolderActions
    let offlineVolumeName: String?

    var body: some View {
        let single = folders.count == 1 && trackCount == 0 && fileCount == 0 ? folders.first : nil
        let offlineHelp = offlineVolumeName.map(TrackMenu.notConnectedHelp)
        if folders.count + trackCount + fileCount > 1 {
            Text(FolderMenuText.header(folders: folders.count, tracks: trackCount, files: fileCount))
        }
        if let offlineVolumeName {
            Text(TrackMenu.notConnectedHelp(offlineVolumeName))
        }
        Section {
            if let single {
                Button("Open") { model.openAsRoot(single.path) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
            Button {
                actions.play(ids)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(offlineVolumeName != nil)
            .help(offlineVolumeName.map(TrackPrimaryAction.driveNotConnectedHelp) ?? "")
        }
        Section {
            Button("Play Next") { actions.playNext(ids) }
            Button("Add to Queue") { actions.addToQueue(ids) }
        }
        Section {
            Menu("Add to Playlist") {
                AddToPlaylistMenuItems(
                    playlists: TrackMenuSources.shared.playlists,
                    showsKeyEquivalents: false,
                    newPlaylistTitle: folders.count == 1 ? "New Playlist from Folder" : "New Playlist…",
                    newPlaylist: { actions.newPlaylist(ids) },
                    add: { actions.addToPlaylist($0, ids) }
                )
            }
            Menu("Add to Sync Profile") {
                ForEach(TrackMenuSources.shared.syncProfiles) { profile in
                    Button(profile.name) { actions.addToSyncProfile(profile, ids) }
                }
                if !TrackMenuSources.shared.syncProfiles.isEmpty { Divider() }
                Button("New Sync Profile…") { actions.newSyncProfile(ids) }
            }
        }
        if let single {
            Section {
                Button(RereadCommand.scanThisFolder.title()) { actions.scan(single) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(offlineVolumeName != nil || single.isScanning)
                    .help(offlineHelp ?? (single.isScanning ? "This folder is being scanned." : ""))
                if let files = model.notInLibraryFiles(under: single.path), !files.isEmpty {
                    Button(FolderMenuText.importFiles(files.count)) { actions.importNotInLibrary(single) }
                }
            }
        }
        Section {
            Button("Show in Finder") { actions.showInFinder(folders.map(\.path)) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(offlineVolumeName != nil)
                .help(offlineHelp ?? "")
            Button("Copy Path") { actions.copyPaths(folders.map(\.path)) }
        }
    }
}

/// V-FOLD.N02/menu: Import File / Import ‹n› Files — Show in Finder · Copy Path.
private struct FileMenu: View {
    let files: [FolderFileInfo]
    let actions: FolderActions

    var body: some View {
        if files.count > 1 {
            Text(FolderMenuText.header(folders: 0, tracks: 0, files: files.count))
        }
        Section {
            Button(FolderMenuText.importFiles(files.count)) { actions.importFiles(files) }
        }
        Section {
            Button("Show in Finder") { actions.showInFinder(files.map(\.path)) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Copy Path") { actions.copyPaths(files.map(\.path)) }
        }
    }
}
