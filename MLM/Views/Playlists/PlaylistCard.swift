import SwiftUI
import UniformTypeIdentifiers
import AppKit
import ImageIO
import os

// MARK: Accessibility labels for shotty UI automation (snake_case literals)

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
    let source: Source?
    let trackCount: Int
    let downloadStatus: PlaylistDownloadStatus?
    let isRenaming: Bool
    @Binding var renameText: String

    // Actions
    var onTap: () -> Void
    var onRename: () -> Void
    var onConfirmRename: () -> Void
    var onCancelRename: () -> Void
    var onTogglePin: () -> Void
    var onDelete: () -> Void
    /// Opens the playlist while a track drag rests on the card (D-PL-SPRINGLOAD-CARD: system
    /// timing, never required — the card takes the drop itself).
    var onSpringLoad: (() -> Void)? = nil

    /// Triggered by the "Reset to Auto Cover" context-menu entry. Parent calls
    /// `PlaylistCoverService.resetToAuto`.
    var onResetCover: () -> Void = {}

    /// Sync profiles available for the "Sync to" submenu (Phase 38 D-05).
    var availableSyncProfiles: [SyncProfile] = []

    /// Called when user picks a profile from the "Sync to" submenu.
    /// Provides the chosen profile and the playlist's DB id.
    var onAddToSyncProfile: ((SyncProfile, Int64) -> Void)?

    var onDownloadMissing: (() async -> Void)? = nil
    var onShowFailedTracks: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var coverImage: NSImage?
    /// A refused cover drop's sentence, shown on the card for 5 s (UC-SURF-04).
    @State private var coverRefusal: String?
    /// Bumped when the cover service rewrote this playlist's picture (same file name).
    @State private var coverRevision = 0
    @Environment(\.container) private var container

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Icon area
            iconArea

            if let downloadStatus, downloadStatus.isImporting {
                ProgressView(
                    value: Double(downloadStatus.localTracks),
                    total: Double(max(downloadStatus.totalTracks, 1))
                )
                .progressViewStyle(.linear)
                .tint(.mlmActive)
                .frame(maxWidth: .infinity)
                .frame(height: 2)
            }

            // Info area
            infoArea
        }
        .background(isHovered ? Color.mlmRaised : Color.mlmSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(strokeColor, lineWidth: 1)
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
        // Tracks, playlists, Finder files and links as on its sidebar row; an image sets the
        // cover (undoable); a refused image says so on the card (W2-H, DEC-040).
        .dropTarget(
            .playlistCard(id: playlist.id ?? -1, name: playlist.name),
            cornerRadius: 8,
            springLoad: onSpringLoad,
            sayRefusal: { coverRefusal = $0 }
        )
        .inPlaceRefusal($coverRefusal)
        // Drags as the playlist (UC-DND-01).
        .draggable(PlaylistDragItem(playlistId: playlist.id ?? -1, libraryId: container.activeLibrary?.libraryId))
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { note in
            guard (note.userInfo?["origin"] as? String) == "coverService",
                  note.userInfo?["playlistId"] as? Int64 == playlist.id else { return }
            coverRevision += 1
        }
        .accessibilityIdentifier("playlist_card")
        .accessibilityLabel("playlist_card_\(playlist.id ?? -1)")
        .task(id: playlist.id) {
            coverImage = nil
        }
        .task(id: "\(playlist.coverImagePath ?? "")#\(coverRevision)") {
            guard let path = playlist.coverImagePath else {
                coverImage = nil
                return
            }
            let coversDir = Self.coversDirectory
            let cgImage: CGImage? = await Task.detached(priority: .userInitiated) {
                PlaylistCard.loadCoverCGImage(coverImagePath: path, coversDir: coversDir)
            }.value
            guard !Task.isCancelled, let cgImage else {
                coverImage = nil
                return
            }
            coverImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }

    // MARK: - Icon Area

    private var iconArea: some View {
        ZStack {
            if let coverImage {
                Image(nsImage: coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // Fallback: category gradient + SF Symbol (pre-Phase 36 visual).
                LinearGradient(
                    colors: categoryGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image(systemName: categoryIcon)
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(.white.opacity(0.8))
            }

            // Pin indicator — overlaid on either branch
            if playlist.isPinned == 1 {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(8)
                    }
                    Spacer()
                }
            }

        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
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

            if let source {
                Text(source.playlistSourceIdentity.displayName)
                    .font(MLMFont.muted)
                    .foregroundColor(sourceBrandColor(source.playlistSourceIdentity))
                    .lineLimit(1)
                    .help("Linked to \(source.playlistSourceIdentity.displayName)")
                    .accessibilityIdentifier("playlist_card_source_link")
                    .accessibilityLabel("Linked to \(source.playlistSourceIdentity.displayName)")
            }

            if let downloadStatus {
                if downloadStatus.isImporting {
                    StatusChip(
                        text: "Importing · \(downloadStatus.localTracks) of \(downloadStatus.totalTracks)",
                        systemImage: "arrow.down.circle",
                        tint: .mlmActive
                    )
                } else if downloadStatus.isIncomplete {
                    StatusChip(
                        text: "Incomplete · \(downloadStatus.failedTracks) failed",
                        systemImage: "exclamationmark.triangle",
                        tint: .mlmAttention
                    )
                }
            }

            // Track count
            HStack(spacing: 4) {
                Text("\(trackCount) track\(trackCount == 1 ? "" : "s")")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)

                if playlist.isLiked == 1 {
                    Label("Liked", systemImage: "heart.fill")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmError)
                        .accessibilityIdentifier("playlist_card_liked")
                        .accessibilityLabel("Liked playlist")
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

        if let downloadStatus, downloadStatus.missingTracks > 0,
           let onDownloadMissing {
            Button {
                Task { await onDownloadMissing() }
            } label: {
                Label(
                    "Download missing (\(downloadStatus.missingTracks))",
                    systemImage: "arrow.down.circle"
                )
            }
        }

        if let downloadStatus, downloadStatus.isIncomplete,
           let onShowFailedTracks {
            Button {
                onShowFailedTracks()
            } label: {
                Label("Show failed tracks", systemImage: "exclamationmark.triangle")
            }
        }

        Divider()

        // Phase 38 D-05: sync submenu
        Section {
            Menu {
                if availableSyncProfiles.isEmpty {
                    Text("No sync profiles. Create one first.")
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
                    Label("Create New Profile…", systemImage: "plus.circle")
                }
            } label: {
                Label("Sync to \u{25B8}", systemImage: "arrow.triangle.2.circlepath")
            }
        }

        Divider()

        if playlist.isLiked == 0 {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Playlist", systemImage: "trash")
            }
        }
    }

    // MARK: - Cover Loading (Phase 36 Plan 02 cache)

    /// Resolve the safe on-disk URL for a playlist cover. Applies the
    /// path-traversal guard (lastPathComponent) so any `../` segment cannot
    /// escape the covers directory (T-36-09). Returns `nil` only when
    /// `coverImagePath` is `nil`; callers check file existence separately.
    nonisolated static func safeCoverURL(coverImagePath: String?, coversDir: URL) -> URL? {
        guard let relPath = coverImagePath else { return nil }
        let fileName = (relPath as NSString).lastPathComponent
        return coversDir.appendingPathComponent(fileName)
    }

    /// Full cover-load pipeline: resolve URL, check existence, decode.
    /// Returns `nil` on any failure so the caller's gradient fallback branch fires.
    nonisolated static func loadCoverCGImage(coverImagePath: String?, coversDir: URL) -> CGImage? {
        guard let url = safeCoverURL(coverImagePath: coverImagePath, coversDir: coversDir) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
    }

    /// Playlist covers folder of the open library (next to its database). Cards only exist
    /// once a library is open; the legacy folder is a fallback for that impossible case.
    static var coversDirectory: URL {
        DependencyContainer.shared.databaseManager?.playlistCoversDirectory
            ?? DatabaseManager.playlistCoversDirectory(forDatabaseAt: DatabaseManager.legacyDatabaseURL)
    }

    // MARK: - Stroke

    /// The card's edge: hover only. A drag over the card gets the shared drop ring
    /// (`dropTarget`, W2-H) instead of a stroke of its own.
    private var strokeColor: Color {
        isHovered ? .mlmEdge : .mlmEdgeSubtle
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
        return [Color.mlmRaised, Color.mlmSurface]
    }

    private func sourceBrandColor(_ identity: PlaylistSourceIdentity) -> Color {
        switch identity {
        case .soundcloud:
            .mlmBrandSoundCloud
        case .spotify:
            .mlmBrandSpotify
        case .youtube:
            .mlmBrandYouTube
        case .appleMusic:
            .mlmBrandAppleMusic
        case .other:
            .mlmInkMuted
        }
    }
}
