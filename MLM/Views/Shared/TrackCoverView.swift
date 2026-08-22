import AppKit
import SwiftUI

/// Displays track album artwork with Solar-gradient fallback.
///
/// Loading flow:
/// 1. Check TrackArtworkCache (NSCache hit → instant render, no disk I/O)
/// 2. Query AnalysisRepository for artworkPath
/// 3. Check FileManager.fileExists (D-14: if file missing, trigger self-healing)
/// 4. Load NSImage from disk + cache it
///
/// Observes `.trackArtworkDidChange` to reload when background backfill completes.
/// Fallback: Solar linearGradient mlmBase→mlmRaised + music.note in mlmInkMuted (D-11).
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
            guard (note.userInfo?["trackId"] as? Int64) == trackId else { return }
            TrackArtworkCache.shared.invalidate(forTrackId: trackId)
            image = nil
            Task { await loadImage() }
        }
        .task(id: trackId) {
            await loadImage()
        }
    }

    // MARK: - Image loading

    private func loadImage() async {
        guard trackId > 0 else { return }

        isLoading = true
        defer { isLoading = false }

        // 1. Cache hit
        if let cached = TrackArtworkCache.shared.image(forTrackId: trackId, size: size) {
            image = cached
            return
        }

        // 1b. Negative-cache hit — we already know this track has no artwork,
        // so skip the per-cell DB round-trip (critical for smooth scrolling
        // through large remote lists where most rows have no art).
        if TrackArtworkCache.shared.isKnownNoArtwork(trackId: trackId) {
            return
        }

        // 2. DB lookup — analysisRepository is optional, fetchArtwork returns optional Artwork
        guard let artworkPath = (try? await container.analysisRepository?.fetchArtwork(trackId: trackId))??.artworkPath,
              !artworkPath.isEmpty else {
            // No DB row or NULL/empty path (incl. "no embedded art" sentinel)
            // → remember so we don't query again on the next scroll pass.
            TrackArtworkCache.shared.markNoArtwork(trackId: trackId)
            return
        }

        // 3. File existence check (D-14)
        let fileURL = URL(fileURLWithPath: artworkPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // File missing but DB says it should exist — trigger self-healing
            if let service = container.artworkBackfillService {
                await service.refreshSingleTrack(trackId: trackId)
            }
            return  // Render fallback while re-backfill is pending
        }

        // 4. Load and cache
        guard let nsImage = NSImage(contentsOfFile: fileURL.path) else { return }
        TrackArtworkCache.shared.setImage(nsImage, forTrackId: trackId, size: size)
        image = nsImage
    }

    // MARK: - Fallback (D-11 Solar contract)

    private var fallbackGradient: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [Color.mlmBase, Color.mlmRaised]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Image(systemName: "music.note")
                    .foregroundStyle(Color.mlmInkMuted)
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
