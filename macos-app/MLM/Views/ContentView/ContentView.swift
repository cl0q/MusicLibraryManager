import SwiftUI

/// Root content view with NavigationSplitView layout.
///
/// Provides the 3-column layout: Sidebar + Content + optional Detail.
struct ContentView: View {
    @Environment(\.container) private var container

    @State private var selectedSection: SidebarSection = .library
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        if container.isInitialized {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(selectedSection: $selectedSection)
                    .frame(minWidth: MLMSpacing.sidebarWidth)
            } detail: {
                detailView
            }
            .background(Color.mlmBase)
        } else if let error = container.initializationError {
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.mlmBase)
        } else {
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

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .library:
            PlaceholderView(title: "Library", icon: "music.note.list", description: "Your local music collection")
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
}

/// Navigation sections matching the Tauri app sidebar
enum SidebarSection: String, CaseIterable, Identifiable {
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

/// Placeholder view for sections not yet implemented
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
