import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The playlist menu, built once (UC-CM-02, DEC-039)

/// Where a playlist's menu is shown. The sidebar row (CM-SIDEBAR-PINNED), the card
/// (CM-PL-CARD), the detail's `More` (V-PLD.N01/menu) and the header cover (V-PLD.E02/menu)
/// all render `PlaylistMenuModel.sections` — one builder, subsets in one order.
enum PlaylistMenuPlace: Equatable, Sendable {
    case sidebarRow
    case card
    case more
    case cover
}

enum PlaylistMenuItem: Hashable, Sendable {
    case open
    case play
    case playNext
    case addToQueue
    case addToSyncProfile
    case rename
    case chooseCover
    case useAutomaticCover
    case moveToFolder
    /// `Download ‹n› Tracks` (UC §23 C9).
    case download(Int)
    /// `Show Failed Downloads` — opens the detail in its `Download failed` scope.
    case showFailed
    /// `Refresh from ‹Source›`.
    case refresh(source: String)
    /// `Link Source…` / `Change Link…`.
    case link(isLinked: Bool)
    case importM3U
    case exportM3U
    case showInAllPlaylists
    case delete
}

/// The playlist menus of the catalogue (UC §10.2), as data — unit-tested, never built ad hoc.
enum PlaylistMenuModel {
    struct Facts: Equatable, Sendable {
        var isLiked = false
        var hasCustomCover = false
        var isLinked = false
        /// `SoundCloud` when it can be refreshed from its source.
        var refreshSource: String?
        var notDownloaded = 0
        var failed = 0
    }

    static func facts(_ playlist: Playlist, summary: PlaylistSummary?, sourceName: String?) -> Facts {
        Facts(
            isLiked: playlist.isLiked == 1,
            hasCustomCover: playlist.coverIsCustom == 1,
            isLinked: playlist.sourceId != nil,
            refreshSource: PlaylistRefreshService.canRefresh(playlist) ? (sourceName ?? "Source") : nil,
            notDownloaded: summary?.notDownloadedTracks ?? 0,
            failed: summary?.failedTracks ?? 0
        )
    }

    /// Sections in the DEC-039 order: Primary · Queue · Add to · Edit · Fix · Share · Remove.
    static func sections(_ place: PlaylistMenuPlace, facts: Facts) -> [[PlaylistMenuItem]] {
        if place == .cover {
            return [[.chooseCover] + (facts.hasCustomCover ? [.useAutomaticCover] : [])]
        }
        var primary: [PlaylistMenuItem] = []
        switch place {
        case .card: primary = [.open, .play]
        case .sidebarRow: primary = [.play]
        case .more, .cover: break  // Play / Shuffle are the header's buttons (UC-CM-02)
        }
        let queue: [PlaylistMenuItem] = [.playNext, .addToQueue]
        let addTo: [PlaylistMenuItem] = [.addToSyncProfile]
        var edit: [PlaylistMenuItem] = [.rename]
        if place != .sidebarRow {
            edit.append(.chooseCover)
            if facts.hasCustomCover { edit.append(.useAutomaticCover) }
        }
        edit.append(.moveToFolder)
        var fix: [PlaylistMenuItem] = []
        if facts.notDownloaded > 0 { fix.append(.download(facts.notDownloaded)) }
        if place == .card, facts.failed > 0 { fix.append(.showFailed) }
        if let source = facts.refreshSource { fix.append(.refresh(source: source)) }
        if place != .sidebarRow, !facts.isLiked { fix.append(.link(isLinked: facts.isLinked)) }
        if place == .more { fix.append(.importM3U) }
        var share: [PlaylistMenuItem] = []
        if place == .more { share.append(.exportM3U) }
        if place == .sidebarRow { share.append(.showInAllPlaylists) }
        return [primary, queue, addTo, edit, fix, share, [.delete]].filter { !$0.isEmpty }
    }

    /// Several cards selected (UC-CM-04): a count header, then the items that work on many.
    static let multipleSections: [[PlaylistMenuItem]] = [[.play], [.playNext, .addToQueue], [.addToSyncProfile], [.moveToFolder]]

    static func title(_ item: PlaylistMenuItem) -> String {
        switch item {
        case .open: "Open"
        case .play: "Play"
        case .playNext: "Play Next"
        case .addToQueue: "Add to Queue"
        case .addToSyncProfile: "Add to Sync Profile"
        case .rename: "Rename"
        case .chooseCover: "Choose Cover…"
        case .useAutomaticCover: "Use Automatic Cover"
        case .moveToFolder: "Move to Folder"
        case .download(let n): n == 1 ? "Download 1 Track" : "Download \(n.formatted(.number)) Tracks"
        case .showFailed: "Show Failed Downloads"
        case .refresh(let source): "Refresh from \(source)"
        case .link(let isLinked): isLinked ? "Change Link…" : "Link Source…"
        case .importM3U: "Import M3U into This Playlist…"
        case .exportM3U: "Export as M3U…"
        case .showInAllPlaylists: "Show in All Playlists"
        case .delete: "Delete Playlist…"
        }
    }
}

// MARK: - Window-level playlist requests

/// What a playlist command asks the main window to present: the Delete alert (A-PL-DELETE),
/// the Link sheet (S-PLD-LINK) and the cover file panel (Choose Cover…). Hosted once by the
/// window (`playlistWindowRequests()`), so every place offers the same alert and sheets.
@MainActor
@Observable
final class PlaylistRequests {
    static let shared = PlaylistRequests()

    struct Deletion: Identifiable {
        let id = UUID()
        let playlist: Playlist
        let confirmation: PlaylistDeletionConfirmation
    }

    struct Link: Identifiable {
        let id = UUID()
        let playlist: Playlist
    }

    var deletion: Deletion?
    var link: Link?
    /// Choose Cover…: the playlist whose cover the file panel sets.
    var coverPlaylist: Playlist?
    /// The grid card to select (Show in All Playlists).
    var revealInGrid: Int64?
}

// MARK: - What the items do

/// The commands behind the playlist menus, shared by the sidebar, the grid and the detail.
@MainActor
struct PlaylistActions {
    let container: DependencyContainer
    let shell: ShellActions?
    let navigation: NavigationModel?
    let statusBar: StatusBarCenter?
    let undo: UndoCenter?

    private var requests: PlaylistRequests { .shared }

    private func tracks(_ playlistID: Int64) async -> [Track] {
        (try? await container.playlistRepository?.fetchTracks(playlistId: playlistID)) ?? []
    }

    /// Play a playlist from its first track that can play; the rest is the queue context.
    func play(_ playlist: Playlist, shuffled: Bool = false) {
        guard let id = playlist.id else { return }
        if let reason = TrackTableLiveState.drive(container).cantPlayReason {
            statusBar?.post(reason)
            return
        }
        Task {
            let rows = await tracks(id)
            let playable = rows.filter(\.isLocal)
            guard let first = playable.first else {
                statusBar?.post(rows.isEmpty
                    ? "Nothing to play — “\(playlist.name)” is empty"
                    : "Nothing to play — no track of “\(playlist.name)” is downloaded")
                return
            }
            container.playbackViewModel?.willActivate(nil, from: PlaybackOrigin(
                place: .playlist(id), path: [], listKey: "playlist", container: .playlist(id: id, name: playlist.name)))
            if shuffled {
                await container.playbackViewModel?.playShuffled(playable)
            } else if let activate = shell?.activateTrack {
                activate(first, rows)
            } else {
                await container.playbackViewModel?.playTrack(first, queue: rows)
            }
        }
    }

    func playNext(_ playlists: [Playlist]) {
        Task {
            var all: [Track] = []
            for p in playlists { if let id = p.id { all += await tracks(id) } }
            TrackCommandActions.playNext(all, undo: undo)
        }
    }

    func addToQueue(_ playlists: [Playlist]) {
        Task {
            var all: [Track] = []
            for p in playlists { if let id = p.id { all += await tracks(id) } }
            TrackCommandActions.addToQueue(all, undo: undo)
        }
    }

    func addToSyncProfile(_ playlists: [Playlist], profile: SyncProfile) {
        guard let profileID = profile.id else { return }
        Task { await shell?.edits.addPlaylists(playlists.compactMap(\.id), toSyncProfile: profileID, name: profile.name) }
    }

    func move(_ playlists: [Playlist], toFolder folderID: Int64?) {
        Task { await shell?.edits.movePlaylistItems(playlists.compactMap { $0.id.map(PlaylistSidebarItemID.playlist) },
                                                    into: folderID, before: nil) }
    }

    func moveToNewFolder(_ playlists: [Playlist]) {
        Task { await shell?.edits.newPlaylistFolder(moving: playlists.compactMap(\.id)) }
    }

    /// `Download ‹n› Tracks` (UC-KEY-14): the playlist's not-downloaded tracks, from its source first.
    func downloadMissing(_ playlist: Playlist) {
        guard let id = playlist.id else { return }
        Task {
            let rows = await tracks(id)
            let missing = rows.filter { $0.availability() == .notDownloaded }
            await download(missing, playlist: playlist)
        }
    }

    /// `Retry All` / `Retry`: the failed tracks again.
    func retryFailed(_ playlist: Playlist, only trackIDs: Set<Int64>? = nil) {
        guard let id = playlist.id else { return }
        Task {
            let rows = await tracks(id)
            let failed = rows.filter { track in
                if case .failed = track.availability() { return trackIDs.map { track.id.map($0.contains) ?? false } ?? true }
                return false
            }
            await download(failed, playlist: playlist)
        }
    }

    private func download(_ tracks: [Track], playlist: Playlist) async {
        guard !tracks.isEmpty, let downloads = container.downloadViewModel, let id = playlist.id else { return }
        var pin = DownloadOrchestrator.PreferredSource.auto
        if let sourceID = playlist.sourceId, let source = try? await container.sourceRepository?.fetch(id: sourceID) {
            pin = source.playlistSourceIdentity.downloadPin
        }
        _ = await downloads.downloadTracks(tracks, preferredSource: pin, context: .playlist(id, name: playlist.name))
    }

    func showFailed(_ playlist: Playlist) {
        guard let id = playlist.id else { return }
        navigation?.push(.playlist(id, showFailedTracks: true))
    }

    func open(_ playlist: Playlist) {
        guard let id = playlist.id else { return }
        navigation?.push(.playlist(id))
    }

    /// Refresh from ‹Source› (DEC-023): one Activity operation, subject = the playlist; the
    /// result is Activity's (`Refresh finished — 3 new tracks`); a failure says why with its fix.
    func refresh(_ playlist: Playlist, onFailure: ((String) -> Void)? = nil) {
        guard let id = playlist.id, let playlists = container.playlistRepository, let tracks = container.trackRepository,
              let sources = container.sourceRepository else { return }
        guard !PlaylistRefreshRegistry.shared.running.contains(id) else { return }
        PlaylistRefreshRegistry.shared.running.insert(id)
        let job = ActivityCenter.shared.begin(.playlistRefresh, title: "Refresh “\(playlist.name)”",
                                              subject: .playlist(id, name: playlist.name), messageName: "Refresh")
        let service = PlaylistRefreshService(playlists: playlists, tracks: tracks, sources: sources, remote: .live(container))
        Task {
            defer { PlaylistRefreshRegistry.shared.running.remove(id) }
            do {
                let added = try await service.refresh(playlistID: id)
                job.finish(ActivityResult(counts: [ActivityCount(.done, added, added == 1 ? "new track" : "new tracks")]))
                NotificationCenter.default.post(name: .playlistDidChange, object: nil, userInfo: ["playlistId": id])
                if added > 0 {
                    NotificationCenter.default.post(name: .libraryDidImport, object: nil, userInfo: ["succeeded": added, "skipped": 0])
                }
            } catch {
                let cause = (error as? PlainCauseError)?.plainCause ?? error.localizedDescription
                job.fail(cause: cause, fix: .runAgain)
                onFailure?(cause)
            }
        }
    }

    func link(_ playlist: Playlist) { requests.link = .init(playlist: playlist) }
    func chooseCover(_ playlist: Playlist) { requests.coverPlaylist = playlist }

    func useAutomaticCover(_ playlist: Playlist) {
        guard let id = playlist.id else { return }
        Task { await shell?.edits.useAutomaticCover(ofPlaylist: id, name: playlist.name) }
    }

    func importM3U(into playlist: Playlist) { DropCenter.shared.chooseM3U(into: playlist.id) }

    /// Export ▸ Playlist as M3U… / More ▸ Export as M3U… (`.fileExporter` in the window).
    func exportM3U(_ playlist: Playlist) {
        guard let id = playlist.id else { return }
        Task {
            let rows = await tracks(id)
            let root = (try? await container.configRepository?.getLibraryRoot()) ?? nil
            let export = PlaylistM3U.export(tracks: rows, libraryRoot: root)
            DropCenter.shared.m3uExport = M3UExportRequest(playlistID: id, name: playlist.name,
                                                           document: M3UDocument(text: export.text), leftOut: export.leftOut)
        }
    }

    /// Show in All Playlists: the grid, scrolled to the card, selected (CM-SIDEBAR-PINNED.E04).
    func showInAllPlaylists(_ playlist: Playlist) {
        requests.revealInGrid = playlist.id
        navigation?.select(.allPlaylists)
    }

    /// A-PL-DELETE: asks first (it also leaves its sync profiles; restorable until quit).
    func askToDelete(_ playlist: Playlist) {
        guard let edits = shell?.edits else { return }
        Task {
            let confirmation = await edits.deletionConfirmation(for: playlist)
            requests.deletion = .init(playlist: playlist, confirmation: confirmation)
        }
    }

    func newSyncProfile() { shell?.newSyncProfile() }
}

/// Playlists being refreshed now (one refresh per playlist at a time).
@MainActor
@Observable
final class PlaylistRefreshRegistry {
    static let shared = PlaylistRefreshRegistry()
    var running: Set<Int64> = []
}

// MARK: - The menu view

/// Renders one place's playlist menu. `rename` is the place's own inline rename.
struct PlaylistMenu: View {
    let playlists: [Playlist]
    let place: PlaylistMenuPlace
    var rename: (() -> Void)?

    @Environment(\.container) private var container
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(SidebarModel.self) private var sidebar: SidebarModel?

    private var actions: PlaylistActions {
        PlaylistActions(container: container, shell: shell, navigation: navigation, statusBar: statusBar, undo: undo)
    }

    private var sections: [[PlaylistMenuItem]] {
        guard playlists.count == 1, let playlist = playlists.first else { return PlaylistMenuModel.multipleSections }
        let sourceName = playlist.sourceId.flatMap { sidebar?.sourceNames[$0] }.map { PlaylistEffects.sourceDisplayName($0) }
        let facts = PlaylistMenuModel.facts(playlist, summary: playlist.id.flatMap { sidebar?.summaries[$0] }, sourceName: sourceName)
        return PlaylistMenuModel.sections(place, facts: facts)
    }

    var body: some View {
        if playlists.count > 1 {
            Text(StatusBarText.playlists(playlists.count))
        }
        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
            Section {
                ForEach(section, id: \.self) { item in
                    view(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private func view(for item: PlaylistMenuItem) -> some View {
        let title = PlaylistMenuModel.title(item)
        let first = playlists.first
        switch item {
        case .open:
            Button(title) { if let first { actions.open(first) } }
        case .play:
            let reason = TrackTableLiveState.drive(container).cantPlayReason
            Button { if let first { actions.play(first) } } label: { Label(title, systemImage: "play.fill") }
                .disabled(reason != nil)
                .help(reason ?? "")
        case .playNext:
            Button(title) { actions.playNext(playlists) }
        case .addToQueue:
            Button(title) { actions.addToQueue(playlists) }
        case .addToSyncProfile:
            Menu(title) {
                let profiles = container.syncViewModel?.profiles ?? []
                ForEach(profiles) { profile in
                    Button(profile.name) { actions.addToSyncProfile(playlists, profile: profile) }
                }
                if !profiles.isEmpty { Divider() }
                Button("New Sync Profile…") { actions.newSyncProfile() }
            }
        case .rename:
            Button(title) { rename?() }
        case .chooseCover:
            Button(title) { if let first { actions.chooseCover(first) } }
        case .useAutomaticCover:
            Button(title) { if let first { actions.useAutomaticCover(first) } }
        case .moveToFolder:
            Menu(title) { MoveToFolderItems(playlists: playlists, actions: actions) }
        case .download:
            Button { if let first { actions.downloadMissing(first) } } label: { Label(title, systemImage: "arrow.down.circle") }
        case .showFailed:
            Button(title) { if let first { actions.showFailed(first) } }
        case .refresh:
            let running = first?.id.map { PlaylistRefreshRegistry.shared.running.contains($0) } ?? false
            Button(title) { if let first { actions.refresh(first) } }
                .disabled(running)
        case .link:
            Button(title) { if let first { actions.link(first) } }
        case .importM3U:
            Button(title) { if let first { actions.importM3U(into: first) } }
        case .exportM3U:
            Button(title) { if let first { actions.exportM3U(first) } }
        case .showInAllPlaylists:
            Button(title) { if let first { actions.showInAllPlaylists(first) } }
        case .delete:
            Button(title, role: .destructive) { if let first { actions.askToDelete(first) } }
        }
    }
}

/// Move to Folder ▸ (CM-SUB-MOVE, UC-CM-14): `No Folder` · the folders (check mark on the
/// current one) — `New Playlist Folder…`. Undoable.
struct MoveToFolderItems: View {
    let playlists: [Playlist]
    let actions: PlaylistActions

    @Environment(SidebarModel.self) private var sidebar: SidebarModel?

    var body: some View {
        // The folder all of them are in (a check mark only when they share one place).
        let currentFolder = Set(playlists.map { p in p.id.flatMap { sidebar?.tree.folder(containing: $0)?.id } })
        Toggle("No Folder", isOn: Binding(get: { currentFolder == [nil] }, set: { _ in actions.move(playlists, toFolder: nil) }))
        ForEach(sidebar?.folders ?? []) { folder in
            Toggle(folder.name, isOn: Binding(get: { currentFolder == [folder.id] }, set: { _ in actions.move(playlists, toFolder: folder.id) }))
        }
        Divider()
        Button("New Playlist Folder…") { actions.moveToNewFolder(playlists) }
    }
}

/// The playlist folder's menu (P-SIDEBAR.N03/menu): New Playlist in Folder — Rename — Delete
/// Folder. Deleting is undoable and moves the playlists out, so it acts at once (no `…`,
/// UC-COPY-05 / UC-UNDO-04 — W3-PL IMP proposal).
struct PlaylistFolderMenu: View {
    let folder: PlaylistFolder
    var rename: () -> Void

    @Environment(ShellActions.self) private var shell: ShellActions?

    var body: some View {
        Button("New Playlist in Folder") {
            guard let id = folder.id else { return }
            Task { await shell?.edits.newPlaylist(inFolder: id) }
        }
        Divider()
        Button("Rename", action: rename)
        Divider()
        Button("Delete Folder", role: .destructive) {
            guard let id = folder.id else { return }
            Task { await shell?.edits.deletePlaylistFolder(id, name: folder.name) }
        }
    }
}
