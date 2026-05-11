import SwiftUI

/// Sidebar folder tree backed by the real disk hierarchy.
///
/// Selection is bound directly to the List — FolderTreeRow does NOT
/// observe the ViewModel, so changing the selection does not re-render
/// all 2700+ nodes.
struct FolderTreeView: View {
    @Bindable var viewModel: FolderViewModel

    var body: some View {
        List(selection: $viewModel.selectedFolderPath) {
            ForEach(viewModel.rootNodes) { node in
                FolderTreeRow(node: node)
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Recursive row

/// A single row in the disk folder tree.
///
/// Takes only the node as input — does NOT observe the ViewModel.
/// This keeps selection changes from triggering a full tree re-render.
struct FolderTreeRow: View {
    let node: DiskFolderNode

    @State private var isExpanded = false

    var body: some View {
        if node.children.isEmpty {
            folderLabel
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children) { child in
                    FolderTreeRow(node: child)
                }
            } label: {
                folderLabel
            }
        }
    }

    // MARK: - Label

    private var folderLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(Color.secondary)
                .imageScale(.medium)

            Text(node.name)
                .lineLimit(1)
        }
        .tag(node.id)
        .contentShape(Rectangle())
        .contextMenu {
            Button("In Finder anzeigen") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: node.id)
            }
        }
    }
}
