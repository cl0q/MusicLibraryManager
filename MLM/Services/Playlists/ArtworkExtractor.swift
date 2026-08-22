import Foundation

/// Thin wrapper delegating to `ArtworkService` for ffmpeg-based extraction.
///
/// Signature is preserved so `PlaylistCoverService` (line 112) can call this
/// without modification. Uses the ffmpeg subprocess path which reliably handles
/// FLAC METADATA_BLOCK_PICTURE, APIC in MP3, covr in M4A.
///
/// Phase 37 D-05: single-source-of-truth for embedded artwork extraction.
enum ArtworkExtractor {
    static func extract(audioURL: URL) async -> Data? {
        return await ArtworkService.extractEmbeddedArtwork(from: audioURL)
    }
}
