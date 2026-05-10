import SwiftUI

/// Recursive folder tree using `DisclosureGroup` for lazy-loaded children.
///
/// Each row shows: 📁 FolderName (trackCount)
/// Expanding a node triggers `FolderViewModel.loadChildren(for:)`.
/// Selecting a node sets `selectedFolderPath` → right pane shows tracks.
struct FolderTreeView: View {
    @Bindable var viewModel: FolderViewModel

    var body: some View {
        List(selection: $viewModel.selectedFolderPath) {
            ForEach(viewModel.rootNodes) { node in
                FolderTreeRow(node: node, viewModel: viewModel)
            }
        }
        .listStyle(.sidebar)
        .background(Color.mlmSurface)
    }
}

// MARK: - Recursive row

/// A single row in the folder tree — recursively renders children via DisclosureGroup.
struct FolderTreeRow: View {
    let node: FolderNode
    @Bindable var viewModel: FolderViewModel

    @State private var isExpanded = false

    var body: some View {
        if node.isLoaded, let children = node.children, !children.isEmpty {
            // Has loaded children → show disclosure group
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(children) { child in
                    FolderTreeRow(node: child, viewModel: viewModel)
                }
            } label: {
                folderLabel
            }
            .onChange(of: isExpanded) { _, expanded in
                if expanded {
                    Task { await viewModel.loadChildren(for: node) }
                }
            }
        } else if node.isLoading {
            // Currently loading children
            HStack(spacing: 6) {
                folderLabel
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
        } else {
            // Not yet loaded — show as expandable
            DisclosureGroup(isExpanded: $isExpanded) {
                // Placeholder while loading
                if node.isLoading {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading…")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkMuted)
                    }
                }
            } label: {
                folderLabel
            }
            .onChange(of: isExpanded) { _, expanded in
                if expanded {
                    Task { await viewModel.loadChildren(for: node) }
                }
            }
        }
    }

    // MARK: - Label

    private var folderLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: isSelected ? "folder.fill" : "folder")
                .foregroundColor(isSelected ? .accentColor : .mlmInkSecondary)
                .imageScale(.medium)

            Text(node.name)
                .font(MLMFont.body)
                .foregroundColor(.mlmInk)
                .lineLimit(1)

            Spacer()

            if node.trackCount > 0 {
                Text("\(node.trackCount)")
                    .font(MLMFont.badge)
                    .foregroundColor(.mlmInkMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.mlmRaised)
                    .clipShape(Capsule())
            }
        }
        .tag(node.id)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                revealInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
    }

    private var isSelected: Bool {
        viewModel.selectedFolderPath == node.id
    }

    private func revealInFinder() {
        // Use a temporary selected path to reveal
        let previousSelection = viewModel.selectedFolderPath
        viewModel.selectedFolderPath = node.id
        // Restore after a short delay
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if viewModel.selectedFolderPath == node.id && previousSelection != node.id {
                // Don't restore — user may have intentionally selected this
            }
        }
    }
}
