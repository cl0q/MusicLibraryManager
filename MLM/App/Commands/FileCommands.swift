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
            let selected = selectedTracks
            CommandButton(.newPlaylist, enabled: shellActions != nil) {
                shellActions?.newPlaylist()
            }
            CommandButton(.newPlaylistFromSelection, enabled: !selected.isEmpty) {
                TrackCommandActions.newPlaylistFromSelection(selected)
            }
            CommandButton(.newPlaylistFolder)
            // With a selection, the selection becomes the new profile's first content (M-FILE.N03).
            CommandButton(.newSyncProfile, enabled: shellActions != nil) {
                if selected.isEmpty {
                    shellActions?.newSyncProfile()
                } else {
                    TrackCommandActions.newSyncProfileFromSelection(selected)
                }
            }

            Divider()

            CommandButton(.addFromLink)
            // Opens the Sources page until W3-ADD's import sheet (IMP-009).
            CommandButton(.importPlaylistFromSource, enabled: shellActions != nil) {
                shellActions?.showSources()
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

    private var selectedTracks: [Track] {
        TrackSelection.usable(focusedSelection, navigation: navigation)?.selectedTracks ?? []
    }
}
