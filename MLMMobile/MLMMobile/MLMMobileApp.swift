import SwiftUI

@main
struct MLMMobileApp: App {
    @StateObject private var syncFolder = SyncFolder()
    @StateObject private var libraryViewModel = LibraryViewModel()
    @StateObject private var playbackService = PlaybackService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncFolder)
                .environmentObject(libraryViewModel)
                .environmentObject(playbackService)
                .onAppear {
                    playbackService.configure(syncFolder: syncFolder)
                }
        }
    }
}
