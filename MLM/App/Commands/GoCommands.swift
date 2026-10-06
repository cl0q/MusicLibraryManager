import SwiftUI

/// Go menu (M-NAVIGATE → Go): the six fixed sidebar rows ⌘1…⌘6, Back ⌘[ / Forward ⌘] for
/// pushed details (IMP-004), and the sidebar's Playlists and Sync sections as submenus.
struct GoCommands: Commands {
    @FocusedValue(\.navigationModel) private var navigation
    @FocusedValue(\.sidebarModel) private var sidebar

    /// The catalog item of each fixed row, in ⌘-number order.
    static let fixedRows: [(MenuCommand, SidebarDestination)] = [
        (.goAllTracks, .allTracks), (.goAlbums, .albums), (.goGenres, .genres),
        (.goFolders, .folders), (.goDiscover, .discover), (.goReview, .review),
    ]

    @ViewBuilder
    private func goButton(_ playlist: Playlist) -> some View {
        if let id = playlist.id {
            Button(playlist.name) { navigation?.select(.playlist(id)) }
        }
    }

    var body: some Commands {
        CommandMenu(MenuBarMenu.go.rawValue) {
            ForEach(Self.fixedRows.indices, id: \.self) { index in
                let (command, destination) = Self.fixedRows[index]
                CommandButton(command, enabled: navigation != nil) {
                    navigation?.select(destination)
                }
            }

            Divider()

            CommandButton(.goBack, enabled: navigation?.canGoBack == true) {
                navigation?.goBack()
            }
            CommandButton(.goForward, enabled: navigation?.canGoForward == true) {
                navigation?.goForward()
            }

            Divider()

            // All Playlists — the sidebar's structure: playlist folders as submenus, playlists in
            // sidebar order (UC-MENU-05 Go, W3-PL).
            CommandSubmenu(.goPlaylists, enabled: navigation != nil) {
                Button(SidebarDestination.allPlaylists.fixedTitle) {
                    navigation?.select(.allPlaylists)
                }
                if let nodes = sidebar?.tree.nodes, !nodes.isEmpty {
                    Divider()
                    ForEach(nodes) { node in
                        switch node {
                        case .playlist(let playlist):
                            goButton(playlist)
                        case .folder(let folder, let playlists):
                            Menu(folder.name) {
                                ForEach(playlists) { goButton($0) }
                            }
                        }
                    }
                }
            }
            let profiles = DependencyContainer.shared.syncViewModel?.profiles ?? []
            CommandSubmenu(.goSyncProfiles, enabled: navigation != nil && !profiles.isEmpty) {
                ForEach(profiles) { profile in
                    if let id = profile.id {
                        Button(profile.name) { navigation?.select(.syncProfile(id)) }
                    }
                }
            }
        }
    }
}
