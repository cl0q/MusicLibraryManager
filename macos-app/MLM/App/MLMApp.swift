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
            // Remove default New Document item
            CommandGroup(replacing: .newItem) {}

            // Explicit Settings command. macOS's auto-generated "Settings…"
            // item silently no-ops in some builds because the
            // showSettingsWindow: selector isn't wired to our Settings
            // scene by default. Replacing .appSettings with a plain
            // Button that fires the AppKit selector ourselves both
            // unifies the menu (no duplicate item, which SettingsLink
            // produced) and reliably opens the scene under ⌘,.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    if #available(macOS 14, *) {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } else {
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
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

            // MARK: - View menu — Navigate (⌘1–5)
            CommandMenu("Navigate") {
                ForEach(SidebarSection.topLevelCases) { section in
                    Button(section.label) {
                        selectedSection = section
                    }
                    .keyboardShortcut(section.keyboardShortcut ?? "0")
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

                Divider()

                Button("Volume Up") {
                    // Reserved for Phase 5 enhancement
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(true)

                Button("Volume Down") {
                    // Reserved for Phase 5 enhancement
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(true)
            }

            // MARK: - Library menu
            CommandMenu("Library") {
                Button("Search Library") {
                    selectedSection = .library
                    // ⌘F — focus search field via notification
                    NotificationCenter.default.post(
                        name: .focusSearchField, object: nil
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

        Settings {
            SettingsView()
                .environment(container)
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
