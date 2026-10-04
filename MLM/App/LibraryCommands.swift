import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File menu items for library files (A3, UI-GROUNDTRUTH §2.6): `New Library…`,
/// `Open Library…` ⌘O and `Open Recent ▸`. Switching relaunches; the coordinator asks first.
struct LibraryCommands: View {
    let launch: LibraryLaunchCoordinator

    var body: some View {
        Button("New Library…") {
            launch.requestNewLibrary()
        }

        Button("Open Library…") {
            if let url = LibraryFilePanel.chooseLibraryFile() {
                Task { await launch.handleOpen(url) }
            }
        }
        .keyboardShortcut("o")

        Menu("Open Recent") {
            ForEach(launch.recentLibraries) { recent in
                Button(title(for: recent)) {
                    Task { await launch.handleOpen(recent.entry.url) }
                }
                .disabled(recent.availability != .available)
            }
        }
        .disabled(launch.recentLibraries.isEmpty)
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
