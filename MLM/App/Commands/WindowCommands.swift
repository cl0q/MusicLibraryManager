import SwiftUI

/// Window menu additions (M-WINDOW). Minimize, Zoom, the tiling items, Bring All to Front and
/// the window list are the system's; the main window is listed by its title and reopens after
/// ⌘W (UC-WIN-01).
struct WindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowArrangement) {
            // Window ▸ Activity ⌥⌘0 opens the Activity window — with or without a library
            // (DEC-005, UC-WIN-02, UC-MENU-04).
            CommandButton(.activity, enabled: true) {
                openWindow(id: ActivityWindow.id)
            }
            Divider()
        }
    }
}

/// The one main window (UC-WIN-01).
enum MainWindow {
    static let id = "main"
}
