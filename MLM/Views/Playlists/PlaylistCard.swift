import AppKit
import ImageIO
import SwiftUI

/// A card of All Playlists (V-PL.E09…E14): the cover (cached automatic mosaic or a custom
/// image; a neutral placeholder without one), the name — or its inline rename field — the
/// facts line (`● SoundCloud · 44 tracks · Liked`, the 6 pt brand dot is the only brand colour)
/// and, only when the playlist isn't healthy, its §15.5 status words (the sidebar's words).
/// A thin determinate line under the cover while it imports. Never glass (UC-GLASS-07).
struct PlaylistCard: View {
    let item: PlaylistGridItem
    var isSelected = false
    /// The name is being edited in place (Rename, V-PL.E11).
    var isRenaming = false
    @Binding var renameText: String
    var onCommitRename: () -> Void = {}
    var onCancelRename: () -> Void = {}
    /// The cover's play badge (UC-PRIM-05: double-click the badge plays).
    var onPlay: () -> Void = {}

    @State private var coverImage: NSImage?
    @State private var coverRevision = 0
    @State private var isHovering = false
    @FocusState private var renameFocused: Bool

    private var playlist: Playlist { item.playlist }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            cover
            if case .importing(_, let fraction?) = item.status {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
            }
            nameLine
            HStack(spacing: Spacing.xxs) {
                if let source = item.source {
                    SourceBrandDot(source: source.displayName)
                }
                Text(item.factsText)
                    .lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .help(item.source.map { "Linked to \($0.displayName)" } ?? "")
            if let words = item.status.text {
                Label {
                    Text(words).monospacedDigit()
                } icon: {
                    if let symbol = item.status.systemImage {
                        Image(systemName: symbol).foregroundStyle(item.status.isFailure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                }
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { note in
            guard (note.userInfo?["origin"] as? String) == "coverService",
                  note.userInfo?["playlistId"] as? Int64 == playlist.id else { return }
            coverRevision += 1
        }
        .task(id: "\(playlist.coverImagePath ?? "")#\(coverRevision)") {
            coverImage = await Self.loadCover(playlist.coverImagePath)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var accessibilityText: String {
        ([playlist.name, item.factsText] + [item.status.text].compactMap { $0 }).joined(separator: ", ")
    }

    // MARK: Cover

    private var cover: some View {
        ZStack {
            if let coverImage {
                Image(nsImage: coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: playlist.isLiked == 1 ? "heart" : "music.note.list")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // The play badge on hover (V-PL.E09): double-click it to play.
            if isHovering, !isRenaming {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .background(.background, in: Circle())
                    .padding(Spacing.xs)
                    .onTapGesture(count: 2, perform: onPlay)
                    .help("Double-click to play")
                    .accessibilityLabel("Play")
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    @ViewBuilder
    private var nameLine: some View {
        if isRenaming {
            TextField("Name", text: $renameText)
                .textFieldStyle(.plain)
                .fontWeight(.semibold)
                .focused($renameFocused)
                .onAppear { renameFocused = true }
                .onSubmit(onCommitRename)
                .onExitCommand(perform: onCancelRename)
                .onChange(of: renameFocused) { _, focused in
                    // Clicking away commits (V-PL.E11).
                    if !focused { onCommitRename() }
                }
        } else {
            Text(playlist.name)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(playlist.name)
        }
    }

    // MARK: - Cover loading (cached PNG in the library file, never regenerated per visit)

    static func loadCover(_ path: String?) async -> NSImage? {
        guard let path else { return nil }
        let directory = coversDirectory
        let image = await Task.detached(priority: .userInitiated) {
            PlaylistCard.loadCoverCGImage(coverImagePath: path, coversDir: directory)
        }.value
        return image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    /// Resolve the safe on-disk URL for a playlist cover. Applies the path-traversal guard
    /// (lastPathComponent) so any `../` segment cannot escape the covers directory (T-36-09).
    nonisolated static func safeCoverURL(coverImagePath: String?, coversDir: URL) -> URL? {
        guard let relPath = coverImagePath else { return nil }
        let fileName = (relPath as NSString).lastPathComponent
        return coversDir.appendingPathComponent(fileName)
    }

    /// Full cover-load pipeline: resolve URL, check existence, decode. `nil` on any failure.
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

    /// Playlist covers folder of the open library (next to its database).
    static var coversDirectory: URL {
        DependencyContainer.shared.databaseManager?.playlistCoversDirectory
            ?? DatabaseManager.playlistCoversDirectory(forDatabaseAt: DatabaseManager.legacyDatabaseURL)
    }
}
