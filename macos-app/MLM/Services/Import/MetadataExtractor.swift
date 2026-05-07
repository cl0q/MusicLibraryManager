import AVFoundation
import Foundation

/// Extracted audio metadata from a single file.
///
/// Mirrors the Tauri app's `TrackMetadata` struct from `models/track.rs`.
/// All string fields are normalized: trimmed and lowercased.
struct TrackMetadata: Sendable {
    let artist: String
    let albumArtist: String
    let album: String
    let title: String
    let genre: String?
    let year: Int?
    let bitrate: Int?
    let duration: Int?
    let format: String
    let originalPath: String
}

/// Audio metadata extraction using AVFoundation.
///
/// Reads metadata from supported audio formats:
/// - MP3 (ID3v2)
/// - FLAC (Vorbis Comments via AVAsset)
/// - AAC/M4A (MP4 atoms)
/// - WAV (RIFF INFO / ID3v2)
/// - AIFF (ID3v2)
/// - OGG (Vorbis Comments via AVAsset)
///
/// ## Fallback Behavior
/// - `artist` → raw artist tag, or empty string
/// - `albumArtist` → album artist tag → artist → "various artists"
/// - `album` → album tag → "unknown album"
/// - `title` → title tag → filename stem
///
/// Matches the Tauri app's `metadata/extractor.rs` behavior exactly.
enum MetadataExtractor {

    /// Errors that can occur during metadata extraction.
    enum ExtractionError: Error, LocalizedError {
        case cannotOpenFile(path: String, underlying: String)
        case unsupportedFormat(path: String)
        case noMetadata(path: String)

        var errorDescription: String? {
            switch self {
            case .cannotOpenFile(let path, let underlying):
                return "Cannot open file \(path): \(underlying)"
            case .unsupportedFormat(let path):
                return "Unsupported format: \(path)"
            case .noMetadata(let path):
                return "No metadata found: \(path)"
            }
        }
    }

    // MARK: - Supported Formats

    /// Audio file extensions supported for import.
    static let supportedExtensions: Set<String> = [
        "mp3", "flac", "aac", "m4a", "ogg", "wav", "aiff", "alac"
    ]

    /// Check if a file URL has a supported audio extension.
    static func isAudioFile(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Extraction

    /// Extract metadata from an audio file.
    ///
    /// Uses AVFoundation's `AVAsset` to read audio metadata across
    /// all supported formats. Falls back to filename-derived values
    /// when tags are missing.
    ///
    /// - Parameter url: Path to the audio file
    /// - Returns: Extracted `TrackMetadata`
    /// - Throws: `ExtractionError` if the file cannot be read
    static func extract(from url: URL) async throws -> TrackMetadata {
        let asset = AVAsset(url: url)

        // Verify the asset is readable
        let isPlayable = try await asset.load(.isPlayable)
        guard isPlayable else {
            throw ExtractionError.cannotOpenFile(
                path: url.path,
                underlying: "Asset is not playable"
            )
        }

        // Load metadata items
        let metadata = try await asset.load(.commonMetadata)
        let duration = try await asset.load(.duration)

        // Extract raw values from common metadata keys
        let rawArtist = await metadataValue(for: .commonKeyArtist, in: metadata)
        let rawAlbumArtist = await metadataValue(for: .iTunesMetadataKeyAlbumArtist, in: metadata)
            ?? await metadataValue(for: .id3MetadataKeyBand, in: metadata)
        let rawAlbum = await metadataValue(for: .commonKeyAlbum, in: metadata)
        let rawTitle = await metadataValue(for: .commonKeyTitle, in: metadata)
        let rawGenre = await metadataValue(for: .commonKeyType, in: metadata)
            ?? await metadataValue(for: .iTunesMetadataKeyUserGenre, in: metadata)

        // Year extraction: try common creation date
        let rawYear = await extractYear(from: metadata)

        // Format from file extension
        let format = url.pathExtension.lowercased()

        // Duration in seconds
        let durationSeconds: Int? = {
            let secs = Int(CMTimeGetSeconds(duration))
            return secs > 0 ? secs : nil
        }()

        // Bitrate from audio tracks
        let bitrate = await extractBitrate(from: asset)

        // --- Normalize values (matching Rust extractor behavior) ---

        let artistNormalized = rawArtist?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty ?? ""

        // Album artist fallback: albumArtist → artist → "various artists"
        let albumArtistNormalized = rawAlbumArtist?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
            ?? (artistNormalized.isEmpty ? nil : artistNormalized)
            ?? "various artists"

        // Album fallback: album → "unknown album"
        let albumNormalized = rawAlbum?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
            ?? "unknown album"

        // Title fallback: title → filename stem
        let titleNormalized = rawTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
            ?? url.deletingPathExtension().lastPathComponent.lowercased()

        // Genre normalization (optional)
        let genreNormalized = rawGenre?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty

        return TrackMetadata(
            artist: artistNormalized,
            albumArtist: albumArtistNormalized,
            album: albumNormalized,
            title: titleNormalized,
            genre: genreNormalized,
            year: rawYear,
            bitrate: bitrate,
            duration: durationSeconds,
            format: format,
            originalPath: url.path
        )
    }

    // MARK: - Private Helpers

    /// Extract a string value for a given metadata key.
    private static func metadataValue(
        for key: AVMetadataKey,
        in items: [AVMetadataItem]
    ) async -> String? {
        let matching = AVMetadataItem.metadataItems(
            from: items,
            withKey: key,
            keySpace: nil
        )
        guard let item = matching.first else { return nil }
        return try? await item.load(.stringValue)
    }

    /// Extract year from metadata.
    ///
    /// Looks at creation date / release date metadata.
    /// Handles both full date strings ("2024-01-15") and plain years ("2024").
    private static func extractYear(from items: [AVMetadataItem]) async -> Int? {
        // Try common creation date first
        if let dateString = await metadataValue(for: .commonKeyCreationDate, in: items) {
            return parseYear(from: dateString)
        }
        // Try iTunes release date
        if let dateString = await metadataValue(for: .iTunesMetadataKeyReleaseDate, in: items) {
            return parseYear(from: dateString)
        }
        return nil
    }

    /// Parse a year integer from a date string.
    ///
    /// Handles formats: "2024", "2024-01-15", "2024-01-15T00:00:00Z"
    private static func parseYear(from dateString: String) -> Int? {
        let trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Try to extract first 4 digits as year
        if trimmed.count >= 4, let year = Int(String(trimmed.prefix(4))), year > 1900, year < 2100 {
            return year
        }
        return nil
    }

    /// Extract bitrate from audio tracks (kbps).
    private static func extractBitrate(from asset: AVAsset) async -> Int? {
        guard let tracks = try? await asset.load(.tracks) else { return nil }

        for track in tracks where track.mediaType == .audio {
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                return Int(rate / 1000) // bps → kbps
            }
        }
        return nil
    }
}

// MARK: - String Extension

private extension String {
    /// Returns nil if the string is empty.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
