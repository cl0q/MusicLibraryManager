import SwiftUI

/// File menu (M-FILE, UC-MENU-05). The first two groups are the toolbar Add menu's commands;
/// then the library files. The system's Close Window ⌘W follows.
struct FileCommands: Commands {
    let launch: LibraryLaunchCoordinator

    @FocusedValue(\.shellActions) private var shellActions
    @FocusedValue(\.navigationModel) private var navigation
    @FocusedValue(\.trackSelection) private var focusedSelection

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
            CommandButton(.newPlaylistFolder)
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
            CommandButton(.importM3U)
            CommandSubmenu(.export) {
                CommandButton(.exportPlaylistAsM3U)
                CommandButton(.createMLTrainingSet)
            }

            Divider()

            LibraryCommands(launch: launch)

            Divider()
        }
    }
}
