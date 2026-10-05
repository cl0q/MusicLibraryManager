import SwiftUI

/// Window menu additions (M-WINDOW). Minimize, Zoom, the tiling items, Bring All to Front and
/// the window list are the system's; the main window is listed by its title and reopens after
/// ⌘W (UC-WIN-01).
struct WindowCommands: Commands {
    @FocusedValue(\.navigationModel) private var navigation
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowArrangement) {
            // Until W3-ACT builds the Activity window (DEC-005), Activity ⌥⌘0 shows and hides the
            // bottom Activity panel of the main window — the toolbar Activity item does the same.
            CommandButton(.activity, enabled: DependencyContainer.shared.isInitialized) {
                let shown = UserDefaults.standard.bool(forKey: ActivityPanelHosting.expandedKey)
                if navigation == nil {
                    // Another window is in front: bring the main window and show the panel.
                    UserDefaults.standard.set(true, forKey: ActivityPanelHosting.expandedKey)
                    openWindow(id: MainWindow.id)
                } else {
                    UserDefaults.standard.set(!shown, forKey: ActivityPanelHosting.expandedKey)
                }
            }
            Divider()
        }
    }
}

/// The one main window (UC-WIN-01).
enum MainWindow {
    static let id = "main"
}
