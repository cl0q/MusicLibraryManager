import AppKit
import SwiftUI

/// Window content while no library is open (A3): `No library open`, a library that can't
/// be opened, and the `New Library` sheet. Minimal native placeholder — the real library
/// picker is B1. Copy: UI-GROUNDTRUTH §3.17 / §5.6.
struct LibraryLaunchStateView: View {
    let screen: LibraryLaunchCoordinator.Screen
    let onCreateLibrary: (String) -> Void
    let onOpenLibrary: (URL) -> Void
    let onRetry: () -> Void
    let onDismissProblem: () -> Void

    @State private var showNewLibrary = false
    @State private var newLibraryName = ""

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.mlmBase)
            .sheet(isPresented: $showNewLibrary) { newLibrarySheet }
            .onAppear {
                if screen == .createFirstLibrary { presentNewLibrary(defaultName: "Main Library") }
            }
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
        Button("New Library…") { presentNewLibrary(defaultName: "New Library") }
        Button("Open Library…", action: chooseLibraryFile)
    }

    private var newLibrarySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Library")
                .font(MLMFont.sectionHeader)
            Form {
                TextField("Name", text: $newLibraryName)
            }
            .formStyle(.columns)
            Text("A library keeps its own tracks, playlists and settings. Audio files stay where they are.")
                .font(MLMFont.muted)
                .foregroundStyle(Color.mlmInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showNewLibrary = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    showNewLibrary = false
                    onCreateLibrary(newLibraryName.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newLibraryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func presentNewLibrary(defaultName: String) {
        newLibraryName = defaultName
        showNewLibrary = true
    }

    /// Library files are directories; until the document type is registered (A3 Wave 4)
    /// the panel offers them as folders.
    private func chooseLibraryFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            onOpenLibrary(url)
        }
    }
}
