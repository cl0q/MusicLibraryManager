import SwiftUI

/// Help menu (M-HELP). The system keeps its search field; there is no `MLM Help` item (no help
/// book exists, IMP-116). Show Tips Again starts the TipKit tips over (UC-KIT-27).
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.undoCenter) private var undoCenter

    var body: some Commands {
        CommandGroup(replacing: .help) {
            CommandButton(.keyboardShortcuts, enabled: true) {
                openWindow(id: KeyboardShortcutsWindow.id)
            }
            Divider()
            CommandButton(.showTipsAgain, enabled: true) {
                MLMTips.showAgain()
                _ = undoCenter?.statusBar.post("Tips will show again")
            }
        }
    }
}
