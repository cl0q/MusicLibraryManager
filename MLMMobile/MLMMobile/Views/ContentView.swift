import SwiftUI

/// Root view: Tab-based navigation suitable for iPhone.
struct ContentView: View {
    @EnvironmentObject var syncFolder: SyncFolder
    @EnvironmentObject var libraryViewModel: LibraryViewModel

    @State private var showingFolderPicker = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                NavigationStack {
                    TrackListView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                folderMenu
                            }
                        }
                }
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }

                NavigationStack {
                    PlaylistListView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                folderMenu
                            }
                        }
                }
                .tabItem {
                    Label("Playlists", systemImage: "list.bullet")
                }
            }
            .safeAreaInset(edge: .bottom) {
                MiniPlayerView()
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                syncFolder.setFolder(url)
                Task { await libraryViewModel.load(syncFolder: syncFolder) }
            }
        }
        .task {
            await libraryViewModel.load(syncFolder: syncFolder)
        }
    }

    private var folderMenu: some View {
        Menu {
            Button("Choose Folder…") {
                showingFolderPicker = true
            }
            Button("Use Documents") {
                syncFolder.useDocumentsDirectory()
                Task { await libraryViewModel.load(syncFolder: syncFolder) }
            }
            if syncFolder.rootURL != nil {
                Button("Clear Folder", role: .destructive) {
                    syncFolder.clearFolder()
                }
            }
        } label: {
            Image(systemName: "folder")
        }
    }
}
