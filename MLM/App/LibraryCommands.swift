import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File menu items for library files (A3, M-FILE.E02–E04, N08): `New Library…`,
/// `Open Library…` ⌘O, `Open Recent ▸` and `Show Library File in Finder`. Switching
/// relaunches; the coordinator asks first. Same calls as the sidebar footer (P-LIBFOOTER).
struct LibraryCommands: View {
    let launch: LibraryLaunchCoordinator

    var body: some View {
        CommandButton(.newLibrary, enabled: true) {
            launch.requestNewLibrary()
        }

        CommandButton(.openLibrary, enabled: true) {
            if let url = LibraryFilePanel.chooseLibraryFile() {
                Task { await launch.handleOpen(url) }
            }
        }

        // The open library checked first, then the others with their state; unreachable ones
        // are disabled with the suffix ` — Not connected` / ` — Not found` (M-FILE.E04).
        CommandSubmenu(.openRecent) {
            if launch.activePackageURL != nil {
                Toggle(LibraryFooter.libraryName(launch), isOn: .constant(true))
                    .disabled(true)
            }
            ForEach(launch.recentLibraries) { recent in
                Button(title(for: recent)) {
                    Task { await launch.handleOpen(recent.entry.url) }
                }
                .disabled(recent.availability != .available)
            }
            Divider()
            CommandButton(.clearRecentLibraries)
        }

        CommandButton(.showLibraryFileInFinder, enabled: launch.activePackageURL != nil) {
            if let url = launch.activePackageURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func title(for recent: LibraryLaunchCoordinator.RecentLibrary) -> String {
        let name = recent.entry.displayName
        switch recent.availability {
        case .available: return name
        case .notFound: return name + " — Not found"
        case .notConnected: return name + " — Not connected"
        }
    }
}

/// Open panel for library files. With the document type registered (app bundle) library
/// files are offered as files; without it (`swift run`) they show as folders.
enum LibraryFilePanel {
    @MainActor
    static func chooseLibraryFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        if let type = UTType("com.ilczuk.mlm.library"), type.conforms(to: .package) {
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [type]
        } else {
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.treatsFilePackagesAsDirectories = false
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
