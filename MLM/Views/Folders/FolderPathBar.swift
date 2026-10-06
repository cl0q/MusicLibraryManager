import SwiftUI

// MARK: - Path bar (V-FOLD.E07)

/// The path from the library folder down to where the selection is, at the bottom of the
/// content above the status bar (was the breadcrumb bar at the top). Click a segment to jump
/// there; a segment above the root makes it the root again. Each segment is a drop target for
/// Finder files (D-FOLD-FILES-FROM-FINDER). Show in Finder lives in the menus, not here.
struct FolderPathBar: View {
    let model: FolderViewModel

    /// The bar's height (the mockup's 26 pt strip).
    static let height: CGFloat = 26

    @Environment(\.container) private var container

    var body: some View {
        let segments = model.pathSegments
        HStack(spacing: Spacing.xxs) {
            if let volume = volumeName {
                Label(volume, systemImage: "externaldrive")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                separator
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 { separator }
                Button {
                    model.jump(to: segment.path)
                } label: {
                    Label(segment.name, systemImage: index == 0 ? "folder" : (ManagedFolders.isManaged(segment.path) ? "arrow.down.circle" : "folder"))
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(index == segments.count - 1 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
                .help(index == segments.count - 1 ? segment.name : "Go to “\(segment.name)”")
                .dropTarget(.folderRow(path: segment.path, name: segment.name), cornerRadius: 4)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, Spacing.m)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(.background)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .imageScale(.small)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    /// The library's disk (`Lexxar`) when the library folder is on an external volume.
    private var volumeName: String? {
        LibraryDriveState.volumeName(fromVolumePath: container.mountObserver?.libraryVolumePath)
    }
}
