import SwiftUI

/// Edit menu (M-EDIT). Undo / Redo, Cut / Copy / Paste, Delete and Select All are the
/// system's (their undo naming is W2-F); MLM adds Deselect All and replaces the text-editing
/// group with Find ▸ — ⌘F is an ordinary menu key of the main window, no key monitor
/// (UC-KEY-25, UC-KEY-36, fixes PP-SHELL-06).
struct EditCommands: Commands {
    @FocusedValue(\.trackSelection) private var focusedSelection
    @FocusedValue(\.navigationModel) private var navigation
    @FocusedValue(\.toolbarSearch) private var search

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            let selection = TrackSelection.usable(focusedSelection, navigation: navigation)
            let deselect = selection?.target.deselectAll
            CommandButton(.deselectAll, enabled: deselect != nil && !(selection?.selectedIDs.isEmpty ?? true)) {
                deselect?()
            }
        }

        CommandGroup(replacing: .textEditing) {
            CommandSubmenu(.find, enabled: search != nil) {
                // Focuses the toolbar search field of the main window; it filters the current view.
                CommandButton(.search, enabled: search != nil) {
                    search?.isPresented = true
                }
                // Until the `Library` search scope (W2-I): focuses the field and, with text in it,
                // searches the whole library at once (the search pane).
                CommandButton(.searchLibrary, enabled: search != nil) {
                    guard let search else { return }
                    search.isPresented = true
                    if !search.text.isEmpty { search.submit() }
                }
            }
        }
    }
}
