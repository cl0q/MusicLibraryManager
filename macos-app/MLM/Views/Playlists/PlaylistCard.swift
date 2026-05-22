import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// A single playlist card in the Playlists grid.
///
/// Shows playlist name, track count, pin indicator, and either the cached
/// cover PNG (Phase 36) or a category gradient + SF Symbol fallback.
/// Supports inline rename, right-click context menu (pin/rename/reset/delete),
/// and drag-drop acceptance for custom covers.
///
/// Layout:
/// ```
/// ┌─────────────────────────────┐
/// │  [cover or gradient]        │  Icon area (100pt tall)
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

    /// Forwards a resolved local image URL to the parent for `setCustomCover`.
    /// Defaults to a no-op so SwiftUI Previews + non-grid callers keep compiling.
    var onCoverDropped: (URL) async -> Void = { _ in }

    /// Triggered by the "Reset to Auto Cover" context-menu entry. Parent calls
    /// `PlaylistCoverService.resetToAuto`.
    var onResetCover: () -> Void = {}

    /// Bubbles up to the parent so `PlaylistViewModel.flagCoverDropRejected()`
    /// can show the UI-SPEC line 174 banner.
    var onCoverDropRejected: () -> Void = {}

    /// Sync profiles available for the "Sync zu" submenu (Phase 38 D-05).
    var availableSyncProfiles: [SyncProfile] = []

    /// Called when user picks a profile from the "Sync zu" submenu.
    /// Provides the chosen profile and the playlist's DB id.
    var onAddToSyncProfile: ((SyncProfile, Int64) -> Void)?

    @State private var isHovered = false

    /// `true` while a Finder/in-app drag is hovering over the card. Drives
    /// the accent stroke + thicker line per UI-SPEC §"Cover-Card states".
    @State private var isDropTargeted = false

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
                .stroke(strokeColor, lineWidth: isDropTargeted ? 2 : 1)
        )
        .animation(.easeInOut(duration: 0.12), value: isDropTargeted)
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
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Icon Area

    private var iconArea: some View {
        ZStack {
            if let coverImage = loadCoverImage() {
                Image(nsImage: coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 100)
                    .clipped()
            } else {
                // Fallback: category gradient + SF Symbol (pre-Phase 36 visual).
                LinearGradient(
                    colors: categoryGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(height: 100)

                Image(systemName: categoryIcon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(.white.opacity(0.8))
            }

            // Pin indicator — overlaid on either branch
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

        // D-06: Reset entry only visible when the user has a locked custom cover.
        if playlist.coverIsCustom == 1 {
            Button {
                onResetCover()
            } label: {
                Label("Reset to Auto Cover", systemImage: "arrow.counterclockwise")
            }
        }

        Divider()

        // Phase 38 D-05: "Sync zu" submenu
        Section {
            Menu {
                if availableSyncProfiles.isEmpty {
                    Text("Keine Profile — erstelle zuerst eines")
                } else {
                    ForEach(availableSyncProfiles) { profile in
                        Button {
                            onAddToSyncProfile?(profile, playlist.id ?? -1)
                        } label: {
                            Text(profile.name)
                        }
                    }
                    Divider()
                }
                Button {
                    NotificationCenter.default.post(name: .navigateToCreateSyncProfile, object: nil)
                } label: {
                    Label("Neues Profil erstellen…", systemImage: "plus.circle")
                }
            } label: {
                Label("Sync zu \u{25B8}", systemImage: "arrow.triangle.2.circlepath")
            }
        }

        Divider()

        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete Playlist", systemImage: "trash")
        }
    }

    // MARK: - Cover Loading (Phase 36 Plan 02 cache)

    /// Loads the cached cover PNG from the playlist-covers directory.
    /// Returns `nil` if `coverImagePath` is unset or the file is missing,
    /// triggering the gradient fallback branch in `iconArea`.
    ///
    /// Path-traversal safety (T-36-09): the stored relative path is reduced
    /// to its last component before joining with `coversDir`, so any `../`
    /// segment cannot escape the playlist-covers directory.
    private func loadCoverImage() -> NSImage? {
        guard let relPath = playlist.coverImagePath else { return nil }
        let fileName = (relPath as NSString).lastPathComponent
        let url = coversDir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Resolved on-disk URL of the playlist-covers cache directory.
    /// Same path as `PlaylistCoverService.ensureCoversDir`.
    private var coversDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.musiclibrary.app")
            .appendingPathComponent("playlist-covers")
    }

    // MARK: - Drop Target

    /// Combines hover + drop-target states into a single stroke color.
    /// During a drop drag, the accent color wins; otherwise hover toggles
    /// between mlmEdge (hover) and mlmEdgeSubtle (resting).
    private var strokeColor: Color {
        if isDropTargeted { return .mlmAccent }
        return isHovered ? .mlmEdge : .mlmEdgeSubtle
    }

    /// Resolves the dropped provider to a local image URL and forwards it
    /// to `onCoverDropped`. Falls through to `onCoverDropRejected` when no
    /// loadable image data is present (UI-SPEC §"Drop-Target Acceptance Rules").
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else {
            onCoverDropRejected()
            return false
        }

        // Branch 1: Finder file drop — load as .fileURL.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true)
                          ?? URL(string: String(decoding: data, as: UTF8.self))
                else {
                    Task { @MainActor in onCoverDropRejected() }
                    return
                }
                Task { await onCoverDropped(url) }
            }
            return true
        }

        // Branch 2: In-app image drag (NSImage) — load raw image data,
        // persist to a temp file so the service has a uniform URL input.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                guard let data else {
                    Task { @MainActor in onCoverDropRejected() }
                    return
                }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("inapp_cover_\(UUID().uuidString)")
                do {
                    try data.write(to: tmp)
                    Task { await onCoverDropped(tmp) }
                } catch {
                    Task { @MainActor in onCoverDropRejected() }
                }
            }
            return true
        }

        // Anything else (text, folder, multi-format payload without image): reject.
        onCoverDropRejected()
        return false
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
