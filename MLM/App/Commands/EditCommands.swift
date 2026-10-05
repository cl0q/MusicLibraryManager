import SwiftUI

/// Edit menu (M-EDIT). Undo / Redo, Cut / Copy / Paste, Delete and Select All are the
/// system's; MLM adds Deselect All and replaces the text-editing group with Find ▸ — ⌘F is an
/// ordinary menu key of the main window, no key monitor (UC-KEY-25, UC-KEY-36, fixes PP-SHELL-06).
///
/// Undo / Redo are deliberately not replaced (W2-F): the system items send `undo:` / `redo:`
/// down the responder chain, so a text field being edited undoes its own typing, and
/// otherwise the main window's `UndoManager` — the one `UndoCenter` registers on — undoes
/// the last step. AppKit titles the items from that manager (`undoMenuItemTitle`):
/// `Undo Add to “Warm-up”`, `Redo Rename Playlist` (UC-MENU-03, UC-UNDO-01/07).
struct EditCommands: Commands {
    @FocusedValue(\.trackSelection) private var focusedSelection
    @FocusedValue(\.navigationModel) private var navigation
    @FocusedValue(\.toolbarSearch) private var search
    /// The Activity window's log search (⌘F there, UC-KEY-25; W3-ACT).
    @FocusedValue(\.activityLogSearch) private var logSearch

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            let selection = TrackSelection.usable(focusedSelection, navigation: navigation)
            let deselect = selection?.target.deselectAll
            CommandButton(.deselectAll, enabled: deselect != nil && !(selection?.selectedIDs.isEmpty ?? true)) {
                deselect?()
            }
        }

        CommandGroup(replacing: .textEditing) {
            CommandSubmenu(.find, enabled: search != nil || logSearch != nil) {
                // Focuses the toolbar search field of the main window, scope `This view`: it
                // filters the current view in place (UC-KEY-25, K-SEARCH-CMDF).
                CommandButton(.search, enabled: search != nil || logSearch != nil) {
                    if let search { search.focus(scope: .thisView) } else { logSearch?.focus() }
                }
                // Focuses the field with the `Library` scope: grouped results from the whole
                // library (UC-SEARCH-02, W2-I).
                CommandButton(.searchLibrary, enabled: search != nil) {
                    search?.focus(scope: .library)
                }
            }
        }
    }
}
