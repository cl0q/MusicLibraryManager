import SwiftUI

/// Tracks custom key-held repeat timing for arrow-key seeking.
///
/// Owns two Tasks (delay + repeat) per arrow direction. All mutation
/// happens on the MainActor because the class is @MainActor-isolated.
@MainActor
final class SeekHoldState {
    private var delayTask: Task<Void, Never>?
    private var repeatTask: Task<Void, Never>?

    /// Begin the hold → repeat cascade for a given seek delta.
    /// The first seek already fired on `.down`; after `delayMS` the
    /// repeat task starts seeking every `repeatMS` until cancelled.
    func startHold(delta: TimeInterval, seek: @escaping @Sendable (TimeInterval) async -> Void) {
        cancelAll()
        delayTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.beginRepeat(delta: delta, seek: seek)
        }
    }

    /// Cancel any pending delay and repeat tasks.
    func cancelAll() {
        delayTask?.cancel()
        repeatTask?.cancel()
        delayTask = nil
        repeatTask = nil
    }

    private func beginRepeat(delta: TimeInterval, seek: @escaping @Sendable (TimeInterval) async -> Void) {
        repeatTask = Task {
            while !Task.isCancelled {
                await seek(delta)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// MLM — Music Library Manager (macOS Native)
///
/// Native SwiftUI rewrite of the Tauri-based Music Library Manager.
@main
struct MLMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var container = DependencyContainer.shared

    /// Custom hold-to-repeat state for arrow-key seeking.
    @State private var seekHold = SeekHoldState()

    /// Reads the sidebar selection from the focused window via FocusedValues.
    @FocusedBinding(\.selectedSection) private var selectedSection

    /// Reads the playback VM from the focused window for global shortcuts.
    @FocusedValue(\.playbackViewModel) private var playbackVM

    var body: some Scene {
        // One window only (A3): opening a library file from Finder reuses it and asks to
        // switch, instead of a window group spawning a second window per opened file.
        Window("MLM", id: "main") {
            ContentView()
                .environment(container)
                .frame(minWidth: 900, minHeight: 600)
                .onKeyPress(.leftArrow, phases: [.down, .repeat, .up]) { press in
                    handleSeekKey(phase: press.phase, delta: -5)
                }
                .onKeyPress(.rightArrow, phases: [.down, .repeat, .up]) { press in
                    handleSeekKey(phase: press.phase, delta: 5)
                }
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

                Divider()

                // Library files (A3): New Library… · Open Library… ⌘O · Open Recent ▸
                LibraryCommands(launch: LibraryLaunchCoordinator.shared)
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

                Button("Previous Track") {
                    Task { await playbackVM?.back() }
                }
                .disabled(playbackVM?.hasTrack != true)

                Button("Next Track") {
                    Task { await playbackVM?.next() }
                }
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

    // MARK: - Arrow-key seek (hold-to-repeat)

    /// Handle left/right arrow key press phases for ±5 s seeking.
    ///
    /// - `.down`: seek once immediately, start a 500 ms delay task.
    /// - `.repeat`: swallowed (`.handled`) — our own timer drives repeats.
    /// - `.up`: cancel all pending tasks.
    ///
    /// Ignores presses when ⌘/⌥/⌃ are held (so ⌘← / ⌘→ menu items
    /// still reach the system) and when no track is loaded.
    private func handleSeekKey(phase: KeyPress.Phases, delta: TimeInterval) -> KeyPress.Result {
        // Let modifier combos (⌘←, ⌥←, ⌃←) fall through to menu shortcuts.
        if let event = NSApp.currentEvent {
            let blocked: NSEvent.ModifierFlags = [.command, .option, .control]
            if event.modifierFlags.intersection(blocked).isEmpty == false {
                return .ignored
            }
        }

        switch phase {
        case .down:
            playbackVM?.seekBy(delta)
            seekHold.startHold(delta: delta) { [playbackVM] d in
                await playbackVM?.seekBy(d)
            }
            return .handled
        case .repeat:
            // Swallow system auto-repeat — our Task-based timer drives repeats.
            return .handled
        case .up:
            seekHold.cancelAll()
            return .handled
        default:
            return .ignored
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
