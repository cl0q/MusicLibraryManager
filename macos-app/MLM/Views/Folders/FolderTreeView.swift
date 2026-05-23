import SwiftUI

/// Sidebar folder tree backed by the real disk hierarchy.
///
/// Uses native hierarchical List initialization to build an outline tree view.
/// Under the hood on macOS, this is backed by NSOutlineView, which virtualizes
/// layout rows, loads cells lazily, and handles millions of nodes smoothly at 60 FPS.
struct FolderTreeView: View {
    @Bindable var viewModel: FolderViewModel
    @State private var outlineView: NSOutlineView?

    var body: some View {
        List(viewModel.rootNodes, children: \.childrenOptional, selection: $viewModel.selectedFolderPath) { node in
            if node.name.isEmpty && node.id.hasSuffix("/__placeholder__") {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .onAppear {
                    let parentPath = String(node.id.dropLast("/__placeholder__".count))
                    viewModel.loadChildren(for: parentPath)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.secondary)
                        .imageScale(.medium)

                    Text(node.name)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if let outlineView = outlineView {
                        let clickedRow = outlineView.selectedRow
                        if clickedRow != -1, let item = outlineView.item(atRow: clickedRow) {
                            if outlineView.isItemExpanded(item) {
                                outlineView.collapseItem(item)
                            } else {
                                outlineView.expandItem(item)
                            }
                        }
                    }
                }
                .contextMenu {
                    Button("In Finder anzeigen") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: node.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .background(OutlineViewIntrospector(outlineView: $outlineView))
        .onChange(of: viewModel.selectedFolderPath) { _, newPath in
            guard newPath != nil, let outlineView = outlineView else { return }
            // Let SwiftUI and NSOutlineView update selection first, then expand the selected row
            DispatchQueue.main.async {
                let selectedRow = outlineView.selectedRow
                if selectedRow != -1, let item = outlineView.item(atRow: selectedRow) {
                    expandParents(of: item, in: outlineView)
                    outlineView.expandItem(item)
                }
            }
        }
    }

    private func expandParents(of item: Any, in outlineView: NSOutlineView) {
        if let parent = outlineView.parent(forItem: item) {
            expandParents(of: parent, in: outlineView)
            outlineView.expandItem(parent)
        }
    }
}

// MARK: - OutlineView Introspector

struct OutlineViewIntrospector: NSViewRepresentable {
    @Binding var outlineView: NSOutlineView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let view = view else { return }
            var current: NSView? = view
            while current != nil {
                if let ov = current as? NSOutlineView {
                    self.outlineView = ov
                    break
                }
                current = current?.superview
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

