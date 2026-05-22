import AppKit
import Foundation

/// Thread-safe in-memory image cache for track artwork.
///
/// Backed by `NSCache` (auto-evicts under memory pressure).
/// Keys are scoped by `trackId` + `ArtworkSize` to avoid collisions.
///
/// Phase 37 D-09: countLimit = 200 (~30 MB typical working set at 150 KB/image).
final class TrackArtworkCache: @unchecked Sendable {

    static let shared = TrackArtworkCache()

    private let cache = NSCache<NSNumber, NSImage>()

    init() {
        cache.countLimit = 200
    }

    // MARK: - Cache operations

    func image(forTrackId trackId: Int64, size: ArtworkService.ArtworkSize) -> NSImage? {
        cache.object(forKey: cacheKey(trackId: trackId, size: size))
    }

    func setImage(_ image: NSImage, forTrackId trackId: Int64, size: ArtworkService.ArtworkSize) {
        cache.setObject(image, forKey: cacheKey(trackId: trackId, size: size))
    }

    /// Invalidate all cached sizes for a track (called on .trackArtworkDidChange).
    func invalidate(forTrackId trackId: Int64) {
        for size in [ArtworkService.ArtworkSize.small, .large] {
            cache.removeObject(forKey: cacheKey(trackId: trackId, size: size))
        }
    }

    /// Remove all cached images (e.g., on low-memory warning).
    func removeAll() {
        cache.removeAllObjects()
    }

    // MARK: - Private

    private func cacheKey(trackId: Int64, size: ArtworkService.ArtworkSize) -> NSNumber {
        // Unique key: trackId * 10000 + size.rawValue (500 or 1200, both < 10000)
        NSNumber(value: trackId * 10_000 + Int64(size.rawValue))
    }
}
