import SwiftUI

// MARK: - FocusedValues for ⌘1–5 navigation shortcuts

/// Allows CommandMenu in MLMApp to write the sidebar selection.
struct SelectedSectionKey: FocusedValueKey {
    typealias Value = Binding<SidebarSection>
}

extension FocusedValues {
    var selectedSection: Binding<SidebarSection>? {
        get { self[SelectedSectionKey.self] }
        set { self[SelectedSectionKey.self] = newValue }
    }
}

// MARK: - Root content view

/// Root content view with full window layout.
///
/// Layout (top → bottom):
/// ```
/// ┌────────┬──────────────────────┐
/// │Sidebar │  Detail content      │  NavigationSplitView
/// │        │                      │
/// ├────────┴──────────────────────┤
/// │ ▶ No track playing     —:—   │  MiniPlayerView (36px)
/// ├───────────────────────────────┤
/// │ ▼ Activity                    │  ActivityPanel (36px collapsed)
/// └───────────────────────────────┘
/// ```
struct ContentView: View {
    @Environment(\.container) private var container

    @State private var selectedSection: SidebarSection = .library
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if container.isInitialized {
                initializedView
            } else if let error = container.initializationError {
                errorView(error)
            } else {
                loadingView
            }
        }
        .focusedSceneValue(\.selectedSection, $selectedSection)
    }

    // MARK: - Initialized layout

    private var initializedView: some View {
        VStack(spacing: 0) {
            // Main content — NavigationSplitView fills available space
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(selectedSection: $selectedSection)
                    .frame(minWidth: MLMSpacing.sidebarWidth)
            } detail: {
                detailView
            }

            // Separator
            Rectangle()
                .fill(Color.mlmEdge)
                .frame(height: 1)

            // Persistent mini player bar
            MiniPlayerView()

            // Separator
            Rectangle()
                .fill(Color.mlmEdge)
                .frame(height: 1)

            // Collapsible activity panel
            ActivityPanel()
        }
        .background(Color.mlmBase)
    }

    // MARK: - Detail view router

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .library:
            LibraryView()
        case .playlists:
            PlaceholderView(title: "Playlists", icon: "list.bullet", description: "Your curated playlists")
        case .folders:
            PlaceholderView(title: "Folders", icon: "folder", description: "Browse by disk folder structure")
        case .sync:
            PlaceholderView(title: "Sync", icon: "arrow.triangle.2.circlepath", description: "Device sync profiles")
        case .sources:
            PlaceholderView(title: "Sources", icon: "globe", description: "Connected streaming services")
        }
    }

    // MARK: - Error state

    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.mlmError)
            Text("Failed to Initialize")
                .font(MLMFont.pageTitle)
                .foregroundColor(.mlmInk)
            Text(error.localizedDescription)
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlmBase)
    }

    // MARK: - Loading state

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading Library...")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlmBase)
    }
}

// MARK: - Navigation sections

/// Navigation sections matching the Tauri app sidebar.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case library
    case playlists
    case folders
    case sync
    case sources

    var id: String { rawValue }

    var label: String {
        switch self {
        case .library: "Library"
        case .playlists: "Playlists"
        case .folders: "Folders"
        case .sync: "Sync"
        case .sources: "Sources"
        }
    }

    var icon: String {
        switch self {
        case .library: "music.note.list"
        case .playlists: "list.bullet"
        case .folders: "folder"
        case .sync: "arrow.triangle.2.circlepath"
        case .sources: "globe"
        }
    }

    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .library: "1"
        case .playlists: "2"
        case .folders: "3"
        case .sync: "4"
        case .sources: "5"
        }
    }
}

// MARK: - Placeholder view

/// Placeholder view for sections not yet implemented.
struct PlaceholderView: View {
    let title: String
    let icon: String
    let description: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.mlmInkMuted)
            Text(title)
                .font(MLMFont.pageTitle)
                .foregroundColor(.mlmInk)
            Text(description)
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlmBase)
    }
}
