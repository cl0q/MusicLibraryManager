import SwiftUI

/// Help menu (M-HELP). The system keeps its search field; MLM Help (no help book yet) and
/// Show Tips Again (TipKit) are pending W5-2.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            CommandButton(.mlmHelp)
            CommandButton(.keyboardShortcuts, enabled: true) {
                openWindow(id: KeyboardShortcutsWindow.id)
            }
            Divider()
            CommandButton(.showTipsAgain)
        }
    }
}
