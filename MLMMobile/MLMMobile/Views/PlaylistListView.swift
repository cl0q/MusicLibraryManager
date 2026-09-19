import SwiftUI

/// Lists the local playlists (manifest-synced + Liked).
struct PlaylistListView: View {
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @EnvironmentObject var syncFolder: SyncFolder

    var body: some View {
        Group {
            if libraryViewModel.localPlaylists.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "list.bullet",
                    description: Text("Sync a profile from MLM to see playlists here.")
                )
            } else {
                List {
                    ForEach(libraryViewModel.localPlaylists) { playlist in
                        NavigationLink(value: playlist) {
                            HStack {
                                Image(systemName: playlist.name == "Liked" ? "heart.fill" : "music.note.list")
                                    .foregroundStyle(playlist.name == "Liked" ? .red : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .font(.body)
                                    if let file = playlist.file {
                                        Text(file)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .navigationDestination(for: LocalPlaylist.self) { playlist in
                    if let vm = libraryViewModel.makePlaylistDetailViewModel(for: playlist) {
                        PlaylistDetailView(viewModel: vm)
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let playlistsDir = syncFolder.playlistsDirectory {
                        libraryViewModel.syncPlaylists(from: playlistsDir)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }
}
