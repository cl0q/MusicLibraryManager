import AppKit
import Foundation
import ImageIO

// Album covers (W4-2, IMP-078): `albums.cover_path` — a file in the playlist covers folder, read
// through the same path-traversal guard as playlists (`PlaylistCoverService.safeFileURL`) —
// else the embedded artwork of the album's first listed track, else the placeholder the view
// draws (`square.stack`). Cached in an `NSCache`; the only disk work is the one file read of a
// card that has none cached yet.

/// What a card or header needs to find its picture.
struct AlbumCoverRequest: Hashable, Sendable {
    let albumID: Int64
    let coverPath: String?
    /// The first listed track (embedded artwork fallback); nil when the album has no tracks.
    let firstTrackID: Int64?

    var cacheKey: String { "\(albumID)|\(coverPath ?? "")|\(firstTrackID ?? 0)" }
}

@MainActor
final class AlbumCoverLoader {
    static let shared = AlbumCoverLoader()

    private let cache = NSCache<NSString, NSImage>()
    /// Requests that found no picture (placeholder), so a scroll doesn't ask again.
    private var misses = Set<String>()

    init() {
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    /// The longest side the cards decode to.
    static let maxPixelSize = 600

    func cached(_ request: AlbumCoverRequest) -> NSImage? { cache.object(forKey: request.cacheKey as NSString) }

    func isKnownMiss(_ request: AlbumCoverRequest) -> Bool { misses.contains(request.cacheKey) }

    func forget(albumID: Int64) {
        misses = misses.filter { !$0.hasPrefix("\(albumID)|") }
    }

    func image(for request: AlbumCoverRequest, container: DependencyContainer) async -> NSImage? {
        let key = request.cacheKey
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if misses.contains(key) { return nil }
        var cgImage: CGImage?
        if let path = request.coverPath, let directory = Self.coversDirectory(container),
           let url = PlaylistCoverService.safeFileURL(path, in: directory) {
            cgImage = await Task.detached(priority: .userInitiated) {
                TrackCoverView.decodeCGImage(at: url, maxPixelSize: Self.maxPixelSize)
            }.value
        }
        if cgImage == nil, let trackID = request.firstTrackID {
            cgImage = await Self.embeddedArtwork(trackID: trackID, container: container)
        }
        guard !Task.isCancelled else { return nil }
        guard let cgImage else {
            misses.insert(key)
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key as NSString, cost: cgImage.width * cgImage.height * 4)
        return image
    }

    /// The covers folder of the open library (next to its database); nil without a library.
    static func coversDirectory(_ container: DependencyContainer) -> URL? {
        container.databaseManager?.playlistCoversDirectory
    }

    /// The embedded artwork of a track, through the same stores the track table uses: the
    /// artwork cache, then the `artwork` row's file.
    private static func embeddedArtwork(trackID: Int64, container: DependencyContainer) async -> CGImage? {
        guard trackID > 0 else { return nil }
        if TrackArtworkCache.shared.isKnownNoArtwork(trackId: trackID) { return nil }
        guard let artwork = (try? await container.analysisRepository?.fetchArtwork(trackId: trackID)) ?? nil,
              let path = artwork.artworkPath, !path.isEmpty else {
            TrackArtworkCache.shared.markNoArtwork(trackId: trackID)
            return nil
        }
        let url = URL(fileURLWithPath: path)
        return await Task.detached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: url.path)
                ? TrackCoverView.decodeCGImage(at: url, maxPixelSize: maxPixelSize)
                : nil
        }.value
    }
}

// MARK: - Choosing a cover

enum AlbumCoverFiles {
    enum Failure: Error, Equatable {
        case notAnImage
        case noCoversFolder
        case couldNotWrite
    }

    /// Copies an image into the covers folder as `album-‹id›-‹stamp›.‹ext›` and returns the
    /// stored reference (`playlist-covers/album-…`). The earlier file stays, so Undo can put it
    /// back. Nothing is written for something that isn't an image.
    static func store(_ source: CoverSource, albumID: Int64, in directory: URL?, stamp: String = UUID().uuidString.prefix(8).lowercased()) throws -> String {
        guard let directory else { throw Failure.noCoversFolder }
        let data: Data
        let ext: String
        switch source {
        case .file(let url):
            guard let bytes = try? Data(contentsOf: url) else { throw Failure.notAnImage }
            data = bytes
            ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        case .data(let bytes):
            data = bytes
            ext = "png"
        }
        guard isImage(data) else { throw Failure.notAnImage }
        let name = "album-\(albumID)-\(stamp).\(ext)"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            throw Failure.couldNotWrite
        }
        return "\(DatabaseManager.playlistCoversFolderName)/\(name)"
    }

    /// The bytes decode as an image with a size.
    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return width > 0 && height > 0
    }
}
