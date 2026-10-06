import AppKit
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Loads what a drop carries from its item providers into a `DropContent` — internal payloads
/// first (a track drag also offers its file URL), then Finder files, image data, links.
///
/// Called once, after the drop (nothing is loaded while a drag hovers). Reads the dropped
/// files' own "is a folder" flag — never a library row.
@MainActor
enum DropLoader {
    static func load(_ providers: [NSItemProvider]) async -> DropContent? {
        guard !providers.isEmpty else { return nil }
        let has: (UTType) -> Bool = { type in providers.contains { $0.hasItemConformingToTypeIdentifier(type.identifier) } }

        if has(.draggedTracks) || has(.legacyTrackDrag) {
            var items: [TrackDragItem] = []
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.draggedTracks.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.legacyTrackDrag.identifier) {
                if let item = await transferable(TrackDragItem.self, from: provider) { items.append(item) }
            }
            // Folder rows of Folders stand for their tracks (D-FOLD-FOLDER-TO-PLAYLIST).
            if items.contains(where: \.isFolder) { items = await FolderDragExpansion.expand(items) }
            // Album cards of the Albums grid stand for their tracks, in album order (W4-2).
            if items.contains(where: \.isAlbum) { items = await AlbumDragExpansion.expand(items) }
            return items.isEmpty ? nil : .tracks(TrackDragPayload(items: items))
        }
        if has(.draggedPlaylist) {
            var items: [PlaylistDragItem] = []
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.draggedPlaylist.identifier) {
                if let item = await transferable(PlaylistDragItem.self, from: provider) { items.append(item) }
            }
            return items.isEmpty ? nil : .playlists(items)
        }
        if has(.fileURL) {
            var files: [DroppedFile] = []
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                guard let data = await data(.fileURL, from: provider), let url = fileURL(from: data) else { continue }
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                files.append(DroppedFile(url: url, kind: DroppedFile.kind(of: url, isDirectory: isDirectory)))
            }
            return files.isEmpty ? nil : .files(files)
        }
        if has(.image), let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }),
           let data = await data(.image, from: provider) {
            return .imageData(data)
        }
        if has(.url), let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
           let data = await data(.url, from: provider), let url = webLink(fromURLData: data) {
            return .link(url)
        }
        if has(.plainText), let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }),
           let text = await transferable(String.self, from: provider), let url = webLink(fromText: text) {
            return .link(url)
        }
        return nil
    }

    // MARK: Pure parts (tested)

    /// A `public.file-url` pasteboard value as a file URL (file reference URLs resolved).
    nonisolated static func fileURL(from data: Data) -> URL? {
        let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true)
            ?? URL(string: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        guard let url, url.isFileURL else { return nil }
        return (url as NSURL).filePathURL ?? url
    }

    /// A `public.url` value that is a web link (http / https), else nil.
    nonisolated static func webLink(fromURLData data: Data) -> URL? {
        let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true)
            ?? URL(string: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        return url.flatMap(webLink)
    }

    /// Dragged text that is exactly one web link (a selected URL in a browser or a note).
    nonisolated static func webLink(fromText text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        return URL(string: trimmed).flatMap(webLink)
    }

    nonisolated private static func webLink(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    // MARK: Providers

    private static func transferable<T: Transferable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            _ = provider.loadTransferable(type: type) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }

    private static func data(_ type: UTType, from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            _ = provider.loadDataRepresentation(for: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
