import AppKit
import SwiftUI

/// File menu items for library files (A3, M-FILE.E02–E04, N08): `New Library…`,
/// `Open Library…` ⌘O, `Open Recent ▸` and `Show Library File in Finder`. Switching
/// relaunches; the coordinator asks first. Same calls as the sidebar footer (P-LIBFOOTER).
struct LibraryCommands: View {
    let launch: LibraryLaunchCoordinator

    var body: some View {
        // Each brings the main window forward first (UC-WIN-01): the sheet, panel and alerts live there.
        // While a restore or a library file setup changes library files, the library items
        // are disabled with the reason (review S1); Finder opens wait meanwhile.
        CommandButton(.newLibrary, enabled: !launch.isBusy, disabledReason: launch.busyReason) {
            MainWindowPresenter.shared.requestNewLibrary(launch: launch)
        }

        // The system open panel (`.fileImporter`, UC-SHEET-24) is presented by the main window.
        CommandButton(.openLibrary, enabled: !launch.isBusy, disabledReason: launch.busyReason) {
            MainWindowPresenter.shared.show()
            launch.chooseLibraryFile()
        }

        // The open library checked first, then the others with their state; unreachable ones
        // are disabled with the suffix ` — Not connected` / ` — Not found` (M-FILE.E04). Each
        // with the library-file icon (ICON-MLIBM.N03).
        CommandSubmenu(.openRecent) {
            if launch.activePackageURL != nil {
                Toggle(isOn: .constant(true)) {
                    LibraryMenuLabel(title: LibraryFooter.libraryName(launch))
                }
                .disabled(true)
            }
            ForEach(launch.recentLibraries) { recent in
                Button {
                    MainWindowPresenter.shared.openLibrary(recent.entry.url, launch: launch)
                } label: {
                    LibraryMenuLabel(title: LibraryFooter.recentTitle(recent))
                }
                .disabled(recent.availability != .available || launch.isBusy)
                .help(launch.busyReason ?? "")
            }
            Divider()
            // Pending (MenuCatalog): Open Recent lists every library MLM knows; there is no
            // separate "recent" list in the registry to clear. Libraries leave the list with
            // `Remove from List` in the picker.
            CommandButton(.clearRecentLibraries)
        }

        CommandButton(.showLibraryFileInFinder, enabled: launch.activePackageURL != nil) {
            if let url = launch.activePackageURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

/// A library in a menu: the library-file icon and its name (with the state suffix).
struct LibraryMenuLabel: View {
    let title: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: LibraryFileIcon.menuImage)
        }
    }
}
