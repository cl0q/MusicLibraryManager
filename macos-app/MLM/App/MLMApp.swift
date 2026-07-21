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

            // Settings command. Every SwiftUI-native approach failed
            // before this one — see AppDelegate.showSettingsWindow().
            // We add a diagnostic log line so when the click *still*
            // does nothing we know whether the button itself is firing
            // or the delegate lookup is the failure point.
            CommandGroup(replacing: .appSettings) {
                Button("Einstellungen…") {
                    AppLogger.shared.info(
                        "Settings menu clicked. NSApp.delegate=\(String(describing: NSApp.delegate)) class=\(NSApp.delegate.map { String(describing: type(of: $0)) } ?? "nil")",
                        source: "menu"
                    )
                    if let delegate = AppDelegate.shared {
                        Task { @MainActor in delegate.showSettingsWindow() }
                    } else if let delegate = NSApp.delegate as? AppDelegate {
                        Task { @MainActor in delegate.showSettingsWindow() }
                    } else {
                        // Fallback: build the window inline so the user
                        // is never stuck with a dead menu item.
                        Task { @MainActor in Self.openSettingsFallback() }
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

            // MARK: - View menu — Navigate (⌘1–6)
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

                Divider()

                Button("Sichere Pfad-Migration…") {
                    NotificationCenter.default.post(
                        name: .triggerLibraryRepair, object: nil
                    )
                }
            }
        }

    }

    // MARK: - Menu Actions

    /// Fallback NSWindow opener used if the AppDelegate cast above
    /// fails (e.g. NSApplicationDelegateAdaptor handed SwiftUI its own
    /// wrapper instead of our subclass). Uses a singleton window
    /// controller so a second ⌘, just focuses the existing window.
    @MainActor
    static func openSettingsFallback() {
        FallbackSettings.shared.show()
    }

    @MainActor
    private final class FallbackSettings {
        static let shared = FallbackSettings()
        private var controller: NSWindowController?

        func show() {
            if controller == nil {
                let hosting = NSHostingController(
                    rootView: SettingsView()
                        .environment(\.container, DependencyContainer.shared)
                        .frame(minWidth: 600, minHeight: 500)
                )
                let window = NSWindow(contentViewController: hosting)
                window.title = "MLM Einstellungen"
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                window.setContentSize(NSSize(width: 720, height: 560))
                window.isReleasedWhenClosed = false
                window.center()
                controller = NSWindowController(window: window)
            }
            NSApp.activate(ignoringOtherApps: true)
            controller?.showWindow(nil)
        }
    }

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
