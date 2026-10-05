import SwiftUI

/// View menu (M-VIEW): the system sidebar and toolbar items (`SidebarCommands`,
/// `ToolbarCommands`), the trailing column's two modes, the table menus (pending W2-A / W2-B)
/// and Go to Current Track. Info and Queue are custom toggles of one `.inspector` with two
/// modes, so `InspectorCommands` (a second, mode-less toggle with its own key) is not used.
struct ViewCommands: Commands {
    @FocusedValue(\.trailingColumn) private var trailingColumn
    @FocusedValue(\.navigationModel) private var navigation
    @FocusedValue(\.playbackViewModel) private var playback
    @FocusedValue(\.toolbarSearch) private var search

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()

        CommandGroup(after: .sidebar) {
            // ⌘I, ⌥⌘U — each opens the column in its mode or closes it (UC-TRAIL-01).
            CommandButton(.toggleInfo,
                          title: trailingColumn?.isShowing(.info) == true ? "Hide Info" : "Show Info",
                          enabled: trailingColumn != nil) {
                trailingColumn?.toggle(.info)
            }
            CommandButton(.toggleQueue,
                          title: trailingColumn?.isShowing(.queue) == true ? "Hide Queue" : "Show Queue",
                          enabled: trailingColumn != nil) {
                trailingColumn?.toggle(.queue)
            }

            Divider()

            CommandSubmenu(.columns)
            CommandSubmenu(.sortBy)
            CommandSubmenu(.filter)

            Divider()

            CommandButton(.goToCurrentTrack,
                          enabled: navigation != nil && playback?.currentTrack?.id != nil,
                          disabledReason: "Nothing is playing.") {
                goToCurrentTrack()
            }

            Divider()
        }
    }

    /// Go to Current Track ⌘L (M-VIEW.N07): selects the playing track in All Tracks — the one
    /// place every playing track is listed in today. Selecting it in the context it plays from
    /// and scrolling it into view arrive with W2-C's playing context and W2-A's table.
    private func goToCurrentTrack() {
        guard let navigation, let track = playback?.currentTrack, let id = track.id,
              let library = DependencyContainer.shared.libraryViewModel else { return }
        if !navigation.isAllTracksVisible {
            if navigation.selection == .allTracks {
                navigation.popToRoot()
            } else {
                navigation.select(.allTracks)
            }
        }
        let tab: LibraryTab = track.isLocal ? .local : .remote
        if library.selectedTab != tab { library.selectedTab = tab }
        if !library.displayedTracks.contains(where: { $0.id == id }) {
            search?.reset()
        }
        library.selectedTrackIDs = [id]
    }
}
