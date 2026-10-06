import SwiftUI

/// File menu (M-FILE, UC-MENU-05). The first two groups are the toolbar Add menu's commands;
/// then the library files. The system's Close Window ⌘W follows.
struct FileCommands: Commands {
    let launch: LibraryLaunchCoordinator

    @FocusedValue(\.shellActions) private var shellActions
    @FocusedValue(\.navigationModel) private var navigation
    @FocusedValue(\.trackSelection) private var focusedSelection
    @FocusedValue(\.playlistPage) private var playlistPage
    @FocusedValue(\.selectedPlaylists) private var selectedPlaylists

    var body: some Commands {
        // Replaces the system New item: one main window, no documents (UC-WIN-01).
        CommandGroup(replacing: .newItem) {
            let selection = TrackSelection.usable(focusedSelection, navigation: navigation)
            let hasSelection = !(selection?.selectedIDs.isEmpty ?? true)
            CommandButton(.newPlaylist, enabled: shellActions != nil) {
                shellActions?.newPlaylist()
            }
            CommandButton(.newPlaylistFromSelection, enabled: hasSelection && shellActions != nil) {
                TrackCommandActions.newPlaylistFromSelection(selection?.selectedTracks ?? [], shell: shellActions)
            }
            // ⌥⌘N: `untitled folder` first in the Playlists section, its name in edit mode (W3-PL).
            CommandButton(.newPlaylistFolder, enabled: shellActions != nil) {
                if let edits = shellActions?.edits { Task { await edits.newPlaylistFolder() } }
            }
            // With a selection, the selection becomes the new profile's first content (M-FILE.N03).
            CommandButton(.newSyncProfile, enabled: shellActions != nil) {
                if !hasSelection {
                    shellActions?.newSyncProfile()
                } else {
                    TrackCommandActions.newSyncProfileFromSelection(selection?.selectedTracks ?? [])
                }
            }

            Divider()

            // The Add menu's sheets (W3-ADD): S-QUICKADD and S-IMPORT.
            CommandButton(.addFromLink, enabled: shellActions != nil) {
                shellActions?.addFromLink()
            }
            CommandButton(.importPlaylistFromSource, enabled: shellActions != nil) {
                shellActions?.importPlaylistFromSource()
            }
            CommandButton(.importFilesOrFolder, enabled: shellActions != nil) {
                shellActions?.chooseImportFolder()
            }
            // A new playlist named after the file, through the preview sheet (W3-PL).
            CommandButton(.importM3U, enabled: shellActions != nil) {
                DropCenter.shared.chooseM3U(into: nil)
            }
            CommandSubmenu(.export) {
                // The playlist on screen, or the one selected in All Playlists.
                let exportable = playlistPage?.playlist ?? (selectedPlaylists?.count == 1 ? selectedPlaylists?.first : nil)
                CommandButton(.exportPlaylistAsM3U, enabled: exportable != nil && shellActions != nil,
                              disabledReason: "Open a playlist or select one in All Playlists to export it.") {
                    guard let exportable else { return }
                    PlaylistActions(container: .shared, shell: shellActions, navigation: navigation,
                                    statusBar: nil, undo: nil).exportM3U(exportable)
                }
                CommandButton(.createMLTrainingSet)
            }

            Divider()

            LibraryCommands(launch: launch)

            Divider()
        }
    }
}
