import AVFoundation
import Foundation

/// Reads embedded cover-art data from an audio file's common metadata.
///
/// Uses `AVURLAsset` (the non-deprecated successor to `AVAsset(url:)` on macOS 13+).
/// Filters by `.commonIdentifierArtwork` which covers MP3 APIC, M4A `covr`,
/// FLAC `METADATA_BLOCK_PICTURE`, WAV/AIFF ID3v2 APIC, and OGG block.
///
/// Returns nil silently on:
/// - Unreadable / non-existent URL
/// - Unplayable / corrupt file
/// - File with no embedded artwork
///
/// Phase 36 Plan 02 — consumed by `PlaylistCoverService.regenerateCover`.
enum ArtworkExtractor {
    static func extract(audioURL: URL) async -> Data? {
        let asset = AVURLAsset(url: audioURL)
        guard let isPlayable = try? await asset.load(.isPlayable), isPlayable else {
            return nil
        }
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        let artworkItems = AVMetadataItem.metadataItems(
            from: items,
            filteredByIdentifier: .commonIdentifierArtwork
        )
        guard let item = artworkItems.first else { return nil }
        return try? await item.load(.dataValue)
    }
}
