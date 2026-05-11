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

    /// Reads the selected track from the active table for spacebar preview.
    @FocusedValue(\.selectedTrack) private var selectedTrack

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(container)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Remove default New Document item
            CommandGroup(replacing: .newItem) {}

            // MARK: - File menu additions
            CommandGroup(after: .newItem) {
                Button("New Playlist") {
                    createNewPlaylist()
                }
                .keyboardShortcut("n")
            }

            // MARK: - View menu — Navigate (⌘1–5)
            CommandMenu("Navigate") {
                ForEach(SidebarSection.allCases) { section in
                    Button(section.label) {
                        selectedSection = section
                    }
                    .keyboardShortcut(section.keyboardShortcut)
                }
            }

            // MARK: - Playback menu (Space, ⌘., ⌘←, ⌘→)
            CommandMenu("Playback") {
                Button(playbackVM?.isPlaying == true ? "Pause" : "Play") {
                    if let playbackVM {
                        if let selectedTrack {
                            playbackVM.togglePreview(for: selectedTrack)
                        } else {
                            playbackVM.togglePlayPause()
                        }
                    }
                }
                .keyboardShortcut(.space, modifiers: [])

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

                Button("Reveal in Finder") {
                    NotificationCenter.default.post(
                        name: .revealSelectedInFinder, object: nil
                    )
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(selectedTrack == nil)

                Button("Copy File Path") {
                    if let track = selectedTrack,
                       let path = track?.organizedPath {
                        let pasteValue = path.rangeOfCharacter(from: .whitespaces) != nil
                            ? "\"\(path)\""
                            : path
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pasteValue, forType: .string)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(selectedTrack == nil)

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
