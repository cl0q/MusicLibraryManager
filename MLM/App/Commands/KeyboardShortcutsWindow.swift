import SwiftUI

// MARK: - Help ▸ Keyboard Shortcuts (M-HELP.N02, UC-WIN-02)

/// The keyboard map of UI-CONVENTIONS §9.2 as one static table. Rows that are menu items take
/// their keys from `MenuCommand` (the same source the menu bar uses); the rest are keys of the
/// focused list, text fields, sheets and other places.
///
/// The window shows only keys that work now (`visibleGroups`): a menu row whose command is
/// pending, and a key row with an `owner` (the package that builds it), stay hidden until wired.
/// **Wiring a key row (later packages):** remove its `owner`.
enum KeyboardMap {
    struct Row: Identifiable {
        let keys: String
        let action: String
        /// The menu item that owns the key, when there is one.
        let command: MenuCommand?
        /// The work package that makes a non-menu key work; `nil` once it works.
        let owner: String?

        var id: String { keys + action }

        /// Whether the key works now, so the window may list it.
        var isAvailable: Bool {
            owner == nil && !(command?.isPending ?? false)
        }

        /// A menu item's row: keys from the catalog.
        static func menu(_ command: MenuCommand, _ action: String? = nil) -> Row {
            Row(keys: command.shortcut?.description ?? "", action: action ?? command.title, command: command, owner: nil)
        }

        static func key(_ keys: String, _ action: String, owner: String? = nil) -> Row {
            Row(keys: keys, action: action, command: nil, owner: owner)
        }
    }

    struct Group: Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    /// The groups and rows the window shows: only keys that work now, empty groups left out.
    static var visibleGroups: [Group] {
        groups.compactMap { group in
            let rows = group.rows.filter(\.isAvailable)
            return rows.isEmpty ? nil : Group(title: group.title, rows: rows)
        }
    }

    static let groups: [Group] = [
        Group(title: "Track lists", rows: [
            .key("Space", "Preview the selected track; Space again or Esc ends the preview"),
            .key("↩ or double-click", "Play the selected track; the rows after it become the queue"),
            .menu(.playNext),
            .menu(.addToQueue),
            .menu(.toggleInfo, "Show or hide Info"),
            .menu(.download, "Download or retry the selection’s missing tracks"),
            .menu(.showInFinder),
            .key("⌫", "Remove from the current playlist, queue or sync profile", owner: "W2-A"),
            .menu(.removeFromLibrary),
            .menu(.refreshFromSource, "Re-read the current place: Scan Library Folder, Refresh from ‹Source›, Recompute Plan"),
            .key("Type a name", "Jump to the first row whose title starts with it", owner: "W2-A"),
        ]),
        Group(title: "While previewing", rows: [
            .key("← / →", "Seek 5 seconds (hold to repeat)"),
            .key("↑ / ↓", "Preview the next or previous row"),
            .key("↩", "Play the previewed track from where the preview is"),
            .key("Esc", "End the preview and resume"),
        ]),
        Group(title: "Playback", rows: [
            .menu(.next),
            .menu(.previous),
            .menu(.skipForward),
            .menu(.skipBack),
            .menu(.volumeUp),
            .menu(.volumeDown),
            .menu(.stop),
            .menu(.goToCurrentTrack),
            .key("Play/Pause key", "Play or pause (media keys, the toolbar, Playback and Dock menus)"),
        ]),
        Group(title: "Window and places", rows: [
            .menu(.goAllTracks), .menu(.goAlbums), .menu(.goGenres),
            .menu(.goFolders), .menu(.goDiscover), .menu(.goReview),
            .menu(.goBack), .menu(.goForward),
            .menu(.search, "Search the current view"),
            .menu(.searchLibrary),
            .menu(.toggleQueue, "Show or hide the Queue"),
            .menu(.toggleSidebar, "Show or hide the sidebar"),
            .menu(.enterFullScreen),
            .menu(.activity),
            .menu(.settings),
        ]),
        Group(title: "Library and playlists", rows: [
            .menu(.newPlaylist),
            .menu(.newPlaylistFromSelection),
            .menu(.newPlaylistFolder),
            .menu(.addFromLink),
            .menu(.importPlaylistFromSource),
            .menu(.openLibrary),
        ]),
        Group(title: "Editing", rows: [
            .menu(.selectAll), .menu(.deselectAll),
            .menu(.copy), .menu(.cut), .menu(.paste),
            .key("⌘C on tracks", "Copy the tracks and their Title — Artist lines", owner: "W2-A"),
            .menu(.undo), .menu(.redo),
            .key("↩ in a text field", "Commit the edit"),
            .key("Esc in a text field", "Revert to the value before the edit", owner: "W2-E"),
            .key("Tab in a text field", "Commit and go to the next field"),
        ]),
        Group(title: "Sheets and alerts", rows: [
            .key("↩", "The primary button (never a destructive one)"),
            .key("Esc or ⌘.", "Cancel"),
            .key("⌘⌫", "The destructive button of a confirmation", owner: "W5-1"),
        ]),
        Group(title: "Other places", rows: [
            .key("K", "Keep the selected recommendation (Discover)", owner: "W3-DISC"),
            .key("→ / ←", "Expand or collapse (Folders, playlist folders, Review groups)"),
            .key("⌥→ / ⌥←", "Expand or collapse everything inside"),
            .key("⌘↓", "Open the selected folder as the root (Folders)"),
            .key("⌘↑", "Go up one folder (Folders)"),
            .key("⌥↑ / ⌥↓", "Move the row (Albums ▸ Edit Order)", owner: "W4-2"),
            .key("⌘S", "Save the staged changes (genre page)", owner: "W3-GEN"),
        ]),
        Group(title: "MLM", rows: [
            .menu(.closeWindow), .menu(.minimize), .menu(.hideApp), .menu(.hideOthers), .menu(.quit),
            .menu(.mlmHelp),
        ]),
    ]
}

/// The Keyboard Shortcuts window (`Window(id:)`, opened from Help ▸ Keyboard Shortcuts).
enum KeyboardShortcutsWindow {
    static let id = "keyboard-shortcuts"
    static let title = "Keyboard Shortcuts"
}

struct KeyboardShortcutsView: View {
    var body: some View {
        List {
            ForEach(KeyboardMap.visibleGroups) { group in
                Section(group.title) {
                    ForEach(group.rows) { row in
                        LabeledContent {
                            Text(row.keys)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } label: {
                            Text(row.action)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 640)
    }
}
