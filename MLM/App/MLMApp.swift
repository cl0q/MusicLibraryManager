import SwiftUI

/// MLM — Music Library Manager (macOS Native)
///
/// Composes the scenes and the menu bar; each menu lives in `MLM/App/Commands/`, built from
/// the catalog in `MenuCatalog.swift` (UC-MENU-01…05, DEC-038).
@main
struct MLMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var container = DependencyContainer.shared

    init() {
        MLMTips.configure()
    }

    var body: some Scene {
        // One window only (A3, UC-WIN-01): opening a library file from Finder reuses it and asks
        // to switch, instead of a window group spawning a second window per opened file.
        Window("MLM", id: "main") {
            ContentView()
                .environment(container)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Ten menus in order (UC-MENU-01): MLM (system + Settings scene) · File · Edit · View ·
            // Track · Playback · Library · Go · Window · Help.
            FileCommands(launch: LibraryLaunchCoordinator.shared)
            EditCommands()
            ViewCommands()
            TrackCommands()
            PlaybackCommands()
            LibraryMenuCommands()
            GoCommands()
            WindowCommands()
            HelpCommands()
        }

        // Settings… ⌘, (the system adds the MLM-menu item), UC-WIN-03.
        Settings {
            SettingsView()
                .environment(\.container, container)
        }
        .windowResizability(.contentMinSize)

        // Window ▸ Activity ⌥⌘0 (DEC-005, UC-WIN-02): operations and logs, in every launch state.
        Window(ActivityWindow.title, id: ActivityWindow.id) {
            ActivityWindowView()
                .environment(\.container, container)
        }
        .defaultSize(width: 980, height: 620)
        // Never reopens by itself at launch; only Window ▸ Activity, ⌥⌘0 or a deep link open it.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        // Help ▸ Keyboard Shortcuts (UC-WIN-02, M-HELP.N02). Not listed as an openable window
        // of its own in the Window menu; it shows in the window list while open.
        Window(KeyboardShortcutsWindow.title, id: KeyboardShortcutsWindow.id) {
            KeyboardShortcutsView()
        }
        .windowResizability(.contentMinSize)
        .commandsRemoved()
    }
}
