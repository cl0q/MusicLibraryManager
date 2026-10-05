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

            // Playlist folders become submenus with W3-PL.
            CommandSubmenu(.goPlaylists, enabled: navigation != nil) {
                Button(SidebarDestination.allPlaylists.fixedTitle) {
                    navigation?.select(.allPlaylists)
                }
                if let playlists = sidebar?.playlists, !playlists.isEmpty {
                    Divider()
                    ForEach(playlists) { playlist in
                        if let id = playlist.id {
                            Button(playlist.name) { navigation?.select(.playlist(id)) }
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
