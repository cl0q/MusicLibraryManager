import SwiftUI

/// A single playlist card in the Playlists grid.
///
/// Shows playlist name, track count, pin indicator, and category icon.
/// Supports inline rename, right-click context menu for pin/rename/delete.
///
/// Layout:
/// ```
/// ┌─────────────────────────────┐
/// │  🎵                         │  Icon area (tinted by category)
/// │                             │
/// │  📌 My Playlist             │  Name (w/ pin indicator)
/// │  42 tracks                  │  Track count
/// └─────────────────────────────┘
/// ```
struct PlaylistCard: View {
    let playlist: Playlist
    let trackCount: Int
    let isRenaming: Bool
    @Binding var renameText: String

    // Actions
    var onTap: () -> Void
    var onRename: () -> Void
    var onConfirmRename: () -> Void
    var onCancelRename: () -> Void
    var onTogglePin: () -> Void
    var onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Icon area
            iconArea

            // Info area
            infoArea
        }
        .background(isHovered ? Color.mlmRaised : Color.mlmSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovered ? Color.mlmEdge : Color.mlmEdgeSubtle, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            if !isRenaming {
                onTap()
            }
        }
        .contextMenu {
            contextMenuItems
        }
    }

    // MARK: - Icon Area

    private var iconArea: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: categoryGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(height: 100)

            // Category icon
            Image(systemName: categoryIcon)
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.white.opacity(0.8))

            // Pin indicator
            if playlist.isPinned == 1 {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(6)
                    }
                    Spacer()
                }
            }

            // Source badge (if from external source)
            if playlist.sourceId != nil {
                VStack {
                    HStack {
                        sourceBadge
                            .padding(6)
                        Spacer()
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Info Area

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Name (or rename field)
            if isRenaming {
                TextField("Playlist name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.mlmBase)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .onSubmit { onConfirmRename() }
                    .onExitCommand { onCancelRename() }
            } else {
                Text(playlist.name)
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            // Track count
            HStack(spacing: 4) {
                Text("\(trackCount) track\(trackCount == 1 ? "" : "s")")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)

                if playlist.isLiked == 1 {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.mlmError)
                }
            }
        }
        .padding(12)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            onTap()
        } label: {
            Label("Open", systemImage: "arrow.right.circle")
        }

        Divider()

        Button {
            onRename()
        } label: {
            Label("Rename…", systemImage: "pencil")
        }

        Button {
            onTogglePin()
        } label: {
            if playlist.isPinned == 1 {
                Label("Unpin", systemImage: "pin.slash")
            } else {
                Label("Pin to Top", systemImage: "pin")
            }
        }

        Divider()

        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete Playlist", systemImage: "trash")
        }
    }

    // MARK: - Category Styling

    private var categoryIcon: String {
        if playlist.isLiked == 1 {
            return "heart.fill"
        }
        if playlist.isSmart == 1 {
            return "wand.and.stars"
        }
        switch playlist.category {
        case "regular": return "music.note.list"
        case "liked": return "heart.fill"
        case "album": return "opticaldisc"
        default: return "music.note.list"
        }
    }

    private var categoryGradient: [Color] {
        if playlist.isLiked == 1 {
            return [Color.mlmError.opacity(0.6), Color.mlmError.opacity(0.3)]
        }
        if playlist.isSmart == 1 {
            return [Color.mlmActive.opacity(0.6), Color.mlmActive.opacity(0.3)]
        }
        if playlist.sourceId != nil {
            return [Color.mlmAccent.opacity(0.4), Color.mlmAccent.opacity(0.2)]
        }
        return [Color.mlmRaised, Color.mlmSurface]
    }

    private var sourceBadge: some View {
        Group {
            if let _ = playlist.sourceId {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(4)
                    .background(Color.black.opacity(0.3))
                    .clipShape(Circle())
            }
        }
    }
}
