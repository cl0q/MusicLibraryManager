import SwiftUI

/// Sidebar folder tree backed by the real disk hierarchy.
///
/// Uses native hierarchical List initialization to build an outline tree view.
/// Under the hood on macOS, this is backed by NSOutlineView, which virtualizes
/// layout rows, loads cells lazily, and handles millions of nodes smoothly at 60 FPS.
struct FolderTreeView: View {
    @Bindable var viewModel: FolderViewModel
    @State private var outlineView: NSOutlineView?

    private var managedNodes: [DiskFolderNode] {
        viewModel.rootNodes.filter {
            ManagedLibraryLayout.isManagedFolder(URL(fileURLWithPath: $0.id), libraryRoot: viewModel.libraryRootURL)
        }
    }

    private var personalNodes: [DiskFolderNode] {
        viewModel.rootNodes.filter {
            !ManagedLibraryLayout.isManagedFolder(URL(fileURLWithPath: $0.id), libraryRoot: viewModel.libraryRootURL)
        }
    }

    var body: some View {
        List(selection: $viewModel.selectedFolderPath) {
            if !managedNodes.isEmpty {
                Section("MANAGED BY MLM") {
                    OutlineGroup(managedNodes, children: \.childrenOptional) { node in
                        folderRow(node)
                    }
                }
            }
            if !personalNodes.isEmpty {
                Section {
                    OutlineGroup(personalNodes, children: \.childrenOptional) { node in
                        folderRow(node)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .background(OutlineViewIntrospector(outlineView: $outlineView))
        .onChange(of: viewModel.selectedFolderPath) { _, newPath in
            guard newPath != nil, let outlineView = outlineView else { return }
            DispatchQueue.main.async {
                let selectedRow = outlineView.selectedRow
                if selectedRow != -1, let item = outlineView.item(atRow: selectedRow) {
                    expandParents(of: item, in: outlineView)
                    outlineView.expandItem(item)
                }
            }
        }
    }

    @ViewBuilder
    private func folderRow(_ node: DiskFolderNode) -> some View {
        if node.name.isEmpty && node.id.hasSuffix("/__placeholder__") {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .onAppear {
                viewModel.loadChildren(for: String(node.id.dropLast("/__placeholder__".count)))
            }
        } else {
            let isManaged = ManagedLibraryLayout.isManagedFolder(
                URL(fileURLWithPath: node.id),
                libraryRoot: viewModel.libraryRootURL
            )
            HStack(spacing: 6) {
                Image(systemName: isManaged ? "arrow.down.circle" : "folder")
                    .foregroundStyle(isManaged ? Color.mlmAccent : Color.secondary)
                    .imageScale(.medium)
                Text(node.name).lineLimit(1)
            }
            .tag(node.id)
            .help(isManaged ? "Created and maintained by MLM" : "")
            .contentShape(Rectangle())
            .onTapGesture { viewModel.selectedFolderPath = node.id }
            .onTapGesture(count: 2) {
                guard let outlineView else { return }
                let clickedRow = outlineView.selectedRow
                guard clickedRow != -1, let item = outlineView.item(atRow: clickedRow) else { return }
                outlineView.isItemExpanded(item) ? outlineView.collapseItem(item) : outlineView.expandItem(item)
            }
            .contextMenu {
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: node.id)
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
