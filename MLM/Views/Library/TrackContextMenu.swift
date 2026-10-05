import SwiftUI

/// The track menu (CM-TRACK) for places that are not yet a `TrackListTable` — Folders
/// (W3-FOLD) and the genre tools (W3-GEN). A thin adapter over the one builder (`TrackMenu`,
/// `TrackMenuModel`): same items, same order, same actions as every track table.
struct TrackContextMenu: View {
    let selectedTrackIDs: Set<Int64>
    let tracks: [Track]
    let availablePlaylists: [Playlist]
    let availableSyncProfiles: [SyncProfile]
    /// Kept for source compatibility; Add to Sync Profile ▸ uses the shared action.
    let addToSyncProfile: (SyncProfile) -> Void
    var playlist: Playlist? = nil
    var onRemoveFromPlaylist: (() -> Void)? = nil

    @Environment(\.container) private var container
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ShellActions.self) private var shell: ShellActions?

    var body: some View {
        let selected = tracks.filter { track in track.id.map(selectedTrackIDs.contains) ?? false }
        let model = TrackListModel()
        let _ = model.setTracksNow(selected)
        let drive = LibraryDriveState.current(container)
        let live = TrackTableLive(state: TrackTableLiveState(
            nowPlayingID: container.playbackViewModel?.currentTrack?.id,
            isPlaying: container.playbackViewModel?.isPlaying ?? false,
            offlineVolumePath: drive.isOffline ? container.mountObserver?.libraryVolumePath : nil,
            offlineVolumeName: drive.isOffline ? drive.volumeName : nil
        ))
        let listContext: TrackListContext = playlist?.id.map { .playlist(id: $0, name: playlist?.name ?? "") }
            ?? TrackListContext(container: .none, viewName: nil)
        let playback = container.playbackViewModel
        let remove = onRemoveFromPlaylist
        let configuration = TrackListConfiguration(
            listContext: listContext,
            persistenceKey: "contextMenu",
            activate: { track, queue in
                Task { await playback?.playTrack(track, queue: queue) }
            },
            removeFromContainer: remove.map { remove in { _ in remove() } }
        )
        let actions = TrackListActions(model: model, configuration: configuration, live: live,
                                       statusBar: statusBar, undo: undo, shell: shell, container: container)
        let menuModel = TrackMenuModel.make(
            subject: TrackMenuSubject(rows: model.rows, live: live.state),
            context: TrackMenuContext(
                container: listContext.container,
                canActivate: true,
                canRemoveFromContainer: remove != nil,
                canAddToSyncProfile: true
            )
        )
        TrackMenu(
            model: menuModel,
            rows: model.rows,
            actions: actions,
            playlists: availablePlaylists.filter { $0.id != playlist?.id },
            syncProfiles: availableSyncProfiles,
            offlineVolumeName: live.state.offlineVolumeName
        )
    }
}
