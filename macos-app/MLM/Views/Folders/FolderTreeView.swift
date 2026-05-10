import SwiftUI

/// Recursive folder tree using `DisclosureGroup` for pre-loaded children.
///
/// Children are fully pre-populated by `FolderViewModel.buildTree(from:)`.
/// Expanding a node is a pure UI state change — no SQL queries.
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

/// A single row in the folder tree.
///
/// - Leaf nodes (no children) → plain selectable row.
/// - Non-leaf nodes (has children) → DisclosureGroup that expands inline.
struct FolderTreeRow: View {
    let node: FolderNode
    @Bindable var viewModel: FolderViewModel

    @State private var isExpanded = false

    var body: some View {
        if let children = node.children {
            if children.isEmpty {
                // Leaf node: plain selectable row, no disclosure arrow.
                folderLabel
            } else {
                // Non-leaf: disclosure group with pre-loaded children.
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(children) { child in
                        FolderTreeRow(node: child, viewModel: viewModel)
                    }
                } label: {
                    folderLabel
                }
            }
        } else {
            // Fallback for any node whose children were never populated.
            folderLabel
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
                viewModel.selectedFolderPath = node.id
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
    }

    private var isSelected: Bool {
        viewModel.selectedFolderPath == node.id
    }
}
