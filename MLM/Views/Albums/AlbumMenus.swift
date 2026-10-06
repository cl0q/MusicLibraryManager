import SwiftUI

/// The album an album menu is for.
struct AlbumMenuSubject: Equatable, Sendable {
    let id: Int64
    let title: String
    let albumArtist: String
    let isCompilation: Bool
}

/// The album menu (CM-ALB-CARD on a card, CM-ALBD-MORE on the page's `More`, UC-CM-02): one
/// builder, sections in the DEC-039 order, rendered from `AlbumMenuModel`. `Get Info`, `Edit
/// Album Info…` and `Merge with Another Album…` are in their place, disabled, until the next
/// package builds their sheets (W4-2b); nothing else is a placeholder.
struct AlbumMenu: View {
    let albums: [AlbumMenuSubject]
    let place: AlbumMenuPlace
    /// Tracks that have no file and aren't downloading (`Download ‹n› Missing`).
    var missing = 0
    /// `Choose Cover…` and `Edit Order` are the page's (`More` only).
    var chooseCover: (() -> Void)?
    var editOrder: (() -> Void)?

    @Environment(\.container) private var container
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?

    private var actions: AlbumActions {
        AlbumActions(container: container, shell: shell, navigation: navigation, statusBar: statusBar, undo: undo)
    }

    private var ids: [Int64] { albums.map(\.id) }
    private var offlineName: String? { TrackTableLiveState.drive(container).offlineVolumeName }

    private var sections: [[AlbumMenuItem]] {
        let one = albums.count == 1 ? albums.first : nil
        let facts = AlbumMenuModel.Facts(
            isMultiple: albums.count > 1,
            artist: one.flatMap { AlbumMenuModel.artistLink(albumArtist: $0.albumArtist, isCompilation: $0.isCompilation) },
            missing: missing)
        return AlbumMenuModel.sections(place, facts: facts)
    }

    var body: some View {
        if albums.count > 1 {
            Text(AlbumText.albums(albums.count))
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
    private func view(for item: AlbumMenuItem) -> some View {
        let title = AlbumMenuModel.title(item)
        let name = albums.count == 1 ? (albums.first?.title ?? "") : AlbumText.albums(albums.count)
        switch item {
        case .play:
            let reason = TrackTableLiveState.drive(container).cantPlayReason
            Button { actions.play(ids, name: name) } label: { Label(title, systemImage: "play.fill") }
                .disabled(reason != nil)
                .help(reason ?? "")
        case .playNext:
            Button(title) { actions.playNext(ids) }
        case .addToQueue:
            Button(title) { actions.addToQueue(ids) }
        case .addToPlaylist:
            Menu(title) {
                AddToPlaylistMenuItems(
                    playlists: TrackMenuSources.shared.playlists,
                    showsKeyEquivalents: false,
                    newPlaylist: { actions.newPlaylist(albumIDs: ids) },
                    add: { actions.addToPlaylist($0, albumIDs: ids) }
                )
            }
        case .addToSyncProfile:
            Menu(title) {
                let profiles = TrackMenuSources.shared.syncProfiles
                ForEach(profiles) { profile in
                    Button(profile.name) { actions.addToSyncProfile(profile, albumIDs: ids) }
                }
                if !profiles.isEmpty { Divider() }
                Button("New Sync Profile…") { actions.newSyncProfile(albumIDs: ids) }
            }
        case .getInfo, .editAlbumInfo, .mergeWithAnother:
            // The sheets arrive with the next package (W4-2b): in place, disabled.
            Button(title) {}
                .disabled(true)
                .help(AlbumMenuModel.nextPackageHelp)
        case .goToArtist(let artist):
            Button(title) { actions.goToArtist(artist, search: search) }
                .disabled(search == nil)
        case .chooseCover:
            Button(title) { chooseCover?() }
                .disabled(chooseCover == nil)
        case .editOrder:
            Button(title) { editOrder?() }
                .disabled(editOrder == nil)
        case .download:
            Button { actions.downloadMissing(ids) } label: { Label(title, systemImage: "arrow.down.circle") }
        case .showInFinder:
            Button(title) { actions.showInFinder(ids) }
                .disabled(offlineName != nil)
                .help(offlineName.map(TrackMenu.notConnectedHelp) ?? "")
        case .removeFromLibrary:
            Button(title, role: .destructive) {
                actions.askToRemove(albums.map { ($0.id, $0.title) })
            }
            .disabled(offlineName != nil)
            .help(offlineName.map(TrackMenu.notConnectedHelp) ?? "")
        }
    }
}
