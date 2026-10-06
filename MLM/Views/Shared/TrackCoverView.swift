import AppKit
import ImageIO
import SwiftUI

extension EnvironmentValues {
    /// Presentation-only hosts can render placeholders without accessing artwork caches.
    @Entry var trackArtworkLoadingEnabled: Bool = true
}

/// Displays track album artwork with Solar-gradient fallback.
///
/// Loading flow:
/// 1. Check TrackArtworkCache (NSCache hit → instant render, no disk I/O)
/// 2. Query AnalysisRepository for artworkPath
/// 3. Check FileManager.fileExists (D-14: if file missing, trigger self-healing)
/// 4. Load NSImage from disk + cache it
///
/// Observes `.trackArtworkDidChange` to reload when background backfill completes.
/// Fallback: quaternary fill + music.note in the tertiary style (D-11).
///
/// Sizing: TrackCoverView does NOT apply its own .frame — callers are responsible
/// for all sizing (width/height) so the component renders at whatever size is requested.
/// The size parameter is used only to select the cached image resolution (500px vs 1200px)
/// and to scale the fallback music note icon proportionally.
///
/// Phase 37 D-10, D-11, D-12, D-14.
struct TrackCoverView: View {

    let trackId: Int64
    let size: ArtworkService.ArtworkSize
    var cornerRadius: CGFloat = 6

    @State private var image: NSImage?
    @State private var isLoading = false

    @Environment(\.container) private var container
    @Environment(\.trackArtworkLoadingEnabled) private var artworkLoadingEnabled

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity.animation(.easeIn(duration: 0.2)))
            } else {
                fallbackGradient
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onReceive(
            NotificationCenter.default.publisher(for: .trackArtworkDidChange)
        ) { note in
            guard artworkLoadingEnabled else { return }
            guard (note.userInfo?["trackId"] as? Int64) == trackId else { return }
            TrackArtworkCache.shared.invalidate(forTrackId: trackId)
            Task { await loadImage() }
        }
        .task(id: trackId) {
            guard artworkLoadingEnabled else {
                image = nil
                return
            }
            // Synchronous probe: clears any stale image from a previous track
            // and avoids a one-frame placeholder flash for already-cached art.
            image = TrackArtworkCache.shared.image(forTrackId: trackId, size: size)
            await loadImage()
        }
    }

    // MARK: - Image loading

    /// Resolve the artwork image for the current track. Returns `nil` on every
    /// failure path so the caller can unconditionally assign the result to `image`,
    /// ensuring the displayed image is a pure function of `trackId`.
    private func resolveArtwork() async -> NSImage? {
        guard trackId > 0 else { return nil }

        // 1. Cache hit
        if let cached = TrackArtworkCache.shared.image(forTrackId: trackId, size: size) {
            return cached
        }

        // 1b. Negative-cache hit — we already know this track has no artwork,
        // so skip the per-cell DB round-trip (critical for smooth scrolling
        // through large remote lists where most rows have no art).
        if TrackArtworkCache.shared.isKnownNoArtwork(trackId: trackId) {
            return nil
        }

        // 2. DB lookup — analysisRepository is optional, fetchArtwork returns optional Artwork
        guard let artworkPath = (try? await container.analysisRepository?.fetchArtwork(trackId: trackId))??.artworkPath,
              !artworkPath.isEmpty else {
            // No DB row or NULL/empty path (incl. "no embedded art" sentinel)
            // → remember so we don't query again on the next scroll pass.
            TrackArtworkCache.shared.markNoArtwork(trackId: trackId)
            return nil
        }

        // 3. Resolve the file to load. For .small, prefer the pre-downsized file
        //    (written by ArtworkService.saveResized); fall back to on-load downsampling
        //    of the large file so the decoded NSImage is small (~1 MB cost vs ~11 MB).
        let largeURL = URL(fileURLWithPath: artworkPath)
        guard FileManager.default.fileExists(atPath: largeURL.path) else {
            // File missing but DB says it should exist — trigger self-healing
            if let service = container.artworkBackfillService {
                await service.refreshSingleTrack(trackId: trackId)
            }
            return nil  // Render fallback while re-backfill is pending
        }

        let decodeURL: URL
        let decodeMaxPixelSize: Int?
        if size == .small {
            let smallURL = Self.smallFileURL(forLargePath: artworkPath)
            if let smallURL, FileManager.default.fileExists(atPath: smallURL.path) {
                decodeURL = smallURL
                decodeMaxPixelSize = nil
            } else {
                decodeURL = largeURL
                decodeMaxPixelSize = 512
            }
        } else {
            decodeURL = largeURL
            decodeMaxPixelSize = nil
        }

        let cgImage: CGImage? = try? await Task.detached(priority: .userInitiated) {
            Self.decodeCGImage(at: decodeURL, maxPixelSize: decodeMaxPixelSize)
        }.value

        guard !Task.isCancelled, let cgImage else { return nil }
        let loaded = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        TrackArtworkCache.shared.setImage(loaded, forTrackId: trackId, size: size)
        return loaded
    }

    private func loadImage() async {
        isLoading = true
        defer { isLoading = false }
        let resolved = await resolveArtwork()
        image = resolved
    }

    /// Derive the small artwork path from the large path using the same naming
    /// convention as ArtworkService.cachedPath: `{trackId}_{size.rawValue}.jpg`.
    private static func smallFileURL(forLargePath largePath: String) -> URL? {
        let url = URL(fileURLWithPath: largePath)
        let dir = url.deletingLastPathComponent()
        let filename = url.lastPathComponent
        // Replace _1200.jpg → _500.jpg
        guard let range = filename.range(of: "_1200.jpg") else { return nil }
        let smallFilename = filename.replacingCharacters(in: range, with: "_500.jpg")
        return dir.appendingPathComponent(smallFilename)
    }

    /// Decode an image file into a `CGImage`, optionally downsampling.
    ///
    /// `nonisolated` so callers can invoke it from `Task.detached` to keep the
    /// file read and JPEG decode off the main actor. Returns `CGImage` (which is
    /// `Sendable`) rather than `NSImage` so the value crosses the actor boundary
    /// without a concurrency warning; the caller wraps it in `NSImage` on the
    /// main actor.
    ///
    /// When `maxPixelSize` is `nil` the full image is decoded (using the
    /// thumbnail path with the image's own dimensions so EXIF orientation is
    /// still applied and the decode is forced to complete before returning).
    nonisolated static func decodeCGImage(at url: URL, maxPixelSize: Int? = nil) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        let effectiveMax: Int
        if let maxPixelSize {
            effectiveMax = maxPixelSize
        } else {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
            effectiveMax = max(w, h)
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: effectiveMax
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
    }

    // MARK: - Fallback (D-11)

    private var fallbackGradient: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.quaternary)
            .overlay(
                Image(systemName: "music.note")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: fallbackIconSize))
            )
    }

    // MARK: - Size hints (D-12)

    /// Nominal display points for the fallback icon — half the expected display size.
    /// Callers apply .frame(); this is only for the music.note proportional scaling.
    private var fallbackIconSize: CGFloat {
        switch size {
        case .small: return 20   // half of 40pt PlayerBar default
        case .large: return 28   // half of 56pt TrackDetailView (not 128 — callers constrain)
        }
    }
}
