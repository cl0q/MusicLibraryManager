import AppKit
import Foundation

/// Thread-safe in-memory image cache for track artwork.
///
/// Backed by `NSCache` (auto-evicts under memory pressure).
/// Keys are scoped by `trackId` + `ArtworkSize` to avoid collisions.
///
/// Phase 37 D-09: countLimit = 200; additionally capped at a ~20 MB byte
/// budget via `totalCostLimit`. A small negative-result set records track
/// ids that are known to have no artwork so a huge scrolling list doesn't
/// hammer the database with a lookup per cell on every pass.
final class TrackArtworkCache: @unchecked Sendable {

    static let shared = TrackArtworkCache()

    private let cache = NSCache<NSNumber, NSImage>()

    /// Track ids confirmed to have no artwork (skip repeat DB lookups).
    private var noArtworkIds = Set<Int64>()
    private let noArtworkLock = NSLock()

    init() {
        cache.countLimit = 200
        // ~20 MB budget. Cost is the decoded pixel size we set on insert.
        cache.totalCostLimit = 20 * 1024 * 1024
    }

    // MARK: - Cache operations

    func image(forTrackId trackId: Int64, size: ArtworkService.ArtworkSize) -> NSImage? {
        cache.object(forKey: cacheKey(trackId: trackId, size: size))
    }

    func setImage(_ image: NSImage, forTrackId trackId: Int64, size: ArtworkService.ArtworkSize) {
        // A real image arrived → this track is no longer "no artwork".
        noArtworkLock.lock()
        noArtworkIds.remove(trackId)
        noArtworkLock.unlock()
        cache.setObject(image, forKey: cacheKey(trackId: trackId, size: size), cost: estimatedCost(image))
    }

    /// Record that a track has no artwork so callers can skip the DB lookup.
    func markNoArtwork(trackId: Int64) {
        noArtworkLock.lock()
        noArtworkIds.insert(trackId)
        noArtworkLock.unlock()
    }

    /// Whether a track is known to have no artwork (negative cache hit).
    func isKnownNoArtwork(trackId: Int64) -> Bool {
        noArtworkLock.lock()
        defer { noArtworkLock.unlock() }
        return noArtworkIds.contains(trackId)
    }

    /// Invalidate all cached sizes for a track (called on .trackArtworkDidChange).
    func invalidate(forTrackId trackId: Int64) {
        noArtworkLock.lock()
        noArtworkIds.remove(trackId)
        noArtworkLock.unlock()
        for size in [ArtworkService.ArtworkSize.small, .large] {
            cache.removeObject(forKey: cacheKey(trackId: trackId, size: size))
        }
    }

    /// Remove all cached images (e.g., on low-memory warning).
    func removeAll() {
        cache.removeAllObjects()
        noArtworkLock.lock()
        noArtworkIds.removeAll()
        noArtworkLock.unlock()
    }

    // MARK: - Private

    /// Approximate decoded byte size (RGBA) used as the NSCache cost.
    private func estimatedCost(_ image: NSImage) -> Int {
        let size = image.size
        let scale = 2.0  // account for @2x backing
        return Int(size.width * scale * size.height * scale * 4)
    }

    private func cacheKey(trackId: Int64, size: ArtworkService.ArtworkSize) -> NSNumber {
        // Unique key: trackId * 10000 + size.rawValue (500 or 1200, both < 10000)
        NSNumber(value: trackId * 10_000 + Int64(size.rawValue))
    }
}
