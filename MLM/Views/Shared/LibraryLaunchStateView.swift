import AppKit
import SwiftUI

/// Window content while no library is open (A3): `No library open`, a library that can't
/// be opened, and a Finder copy that needs its own identity. Minimal native placeholder —
/// the real library picker is B1. Copy: UI-GROUNDTRUTH §3.17 / §5.6.
struct LibraryLaunchStateView: View {
    let screen: LibraryLaunchCoordinator.Screen
    let onNewLibrary: () -> Void
    let onOpenLibrary: (URL) -> Void
    let onOpenAsSeparateLibrary: (URL) -> Void
    let onRetry: () -> Void
    let onDismissProblem: () -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.mlmBase)
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .unavailable(let entry, let availability):
            ContentUnavailableView {
                Label("\"\(entry.displayName)\" can't be opened", systemImage: "opticaldisc")
            } description: {
                Text(availability == .notConnected
                     ? "The library file is on a disk that isn't connected. Connect the disk, then try again."
                     : "The library file isn't where MLM last found it. Open it from its new location, or create a new library.")
            } actions: {
                if availability == .notConnected {
                    Button("Try again", action: onRetry)
                }
                openAndNewButtons
            }
        case .mismatch(let name, let packageURL):
            ContentUnavailableView {
                Label("\"\(name)\" can't be opened", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The library file and its database don't belong together. This can happen when files inside a library file were replaced. MLM didn't change anything.")
            } actions: {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([packageURL])
                }
                Button("OK", action: onDismissProblem)
            }
        case .invalid(let name):
            ContentUnavailableView {
                Label("\"\(name)\" isn't a valid library file.", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("OK", action: onDismissProblem)
            }
        case .duplicateCopy(let name, let originalName, let packageURL):
            ContentUnavailableView {
                Label("\"\(name)\" is a copy of \"\(originalName)\"", systemImage: "doc.on.doc")
            } description: {
                Text("To open it, MLM makes the copy a separate library. \"\(originalName)\" is not changed.")
            } actions: {
                Button("Open as separate library") { onOpenAsSeparateLibrary(packageURL) }
                Button("Cancel", action: onDismissProblem)
            }
        default:
            ContentUnavailableView {
                Label("No library open", systemImage: "opticaldisc")
            } description: {
                Text("Create a new library or open an existing library file.")
            } actions: {
                openAndNewButtons
            }
        }
    }

    @ViewBuilder
    private var openAndNewButtons: some View {
        Button("New Library…", action: onNewLibrary)
        Button("Open Library…") {
            if let url = LibraryFilePanel.chooseLibraryFile() { onOpenLibrary(url) }
        }
    }
}
