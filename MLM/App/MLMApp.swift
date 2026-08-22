import SwiftUI

/// MLM — Music Library Manager (macOS Native)
///
/// Native SwiftUI rewrite of the Tauri-based Music Library Manager.
/// Shares the same SQLite database and schema for seamless switching
/// between the Tauri and native macOS versions.
@main
struct MLMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var container = DependencyContainer.shared

    /// Reads the sidebar selection from the focused window via FocusedValues.
    @FocusedBinding(\.selectedSection) private var selectedSection

    /// Reads the playback VM from the focused window for global shortcuts.
    @FocusedValue(\.playbackViewModel) private var playbackVM

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(container)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Remove default New Document item — single-window app
            CommandGroup(replacing: .newItem) {}

            // Settings via AppDelegate. Only one code path now.
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") {
                    guard let delegate = AppDelegate.shared else {
                        AppLogger.shared.error("AppDelegate.shared is nil — Settings window cannot open", source: "menu")
                        return
                    }
                    delegate.showSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // MARK: - File menu additions
            CommandGroup(after: .newItem) {
                Button("New Playlist") {
                    createNewPlaylist()
                }
                .keyboardShortcut("n")
            }

            // MARK: - Navigate menu (⌘1–⌘7)
            CommandMenu("Navigate") {
                ForEach(SidebarSection.topLevelCases) { section in
                    if let shortcut = section.keyboardShortcut {
                        Button(section.label) {
                            selectedSection = section
                        }
                        .keyboardShortcut(shortcut)
                    }
                }
            }

            // MARK: - Playback menu (⌘., ⌘←, ⌘→)
            CommandMenu("Playback") {
                Button(playbackVM?.isPlaying == true ? "Pause" : "Play") {
                    playbackVM?.togglePlayPause()
                }
                .disabled(playbackVM?.hasTrack != true)

                Button("Stop") {
                    playbackVM?.stop()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(playbackVM?.hasTrack != true)

                Divider()

                Button("Skip Back 10s") {
                    if let vm = playbackVM {
                        let newPos = max(0, vm.currentPosition - 10)
                        vm.seek(to: newPos)
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(playbackVM?.hasTrack != true)

                Button("Skip Forward 10s") {
                    if let vm = playbackVM {
                        let newPos = min(vm.duration, vm.currentPosition + 10)
                        vm.seek(to: newPos)
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(playbackVM?.hasTrack != true)

            }

            CommandMenu("Library") {
                Button("Search Library") {
                    NotificationCenter.default.post(
                        name: .searchCommandTriggered, object: nil
                    )
                }
                .keyboardShortcut("f")

                Divider()

                Button("Import from Folder…") {
                    NotificationCenter.default.post(
                        name: .showImportDialog, object: nil
                    )
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Divider()

                Button("More Info") {
                    NotificationCenter.default.post(
                        name: .showTrackDetail, object: nil
                    )
                }
                .keyboardShortcut("i")

            }
        }

    }

    // MARK: - Menu Actions

    /// Create a new unnamed playlist via the PlaylistRepository.
    private func createNewPlaylist() {
        guard let playlistRepo = container.playlistRepository else { return }
        Task {
            try? await playlistRepo.create(name: "Untitled Playlist")
            NotificationCenter.default.post(name: .playlistDidChange, object: nil)
            selectedSection = .playlists
        }
    }
}
