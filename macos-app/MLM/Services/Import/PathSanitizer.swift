import Foundation

/// FAT32-safe path sanitization for organized library paths.
///
/// Generates `Artist/Album/Title.ext` paths with FAT32-compatible
/// filenames. Matches the Tauri app's `metadata/sanitize.rs` behavior
/// exactly, including Windows reserved name handling.
///
/// ## Path Structure
/// - Standard: `album_artist/album/title.format`
/// - SoundCloud: `SoundCloud/artist/title.format`
///
/// ## Sanitization Rules
/// - Invalid characters `< > : " / \ | ? *` replaced with `_`
/// - Windows reserved names (`CON`, `PRN`, `AUX`, `NUL`, `COM1-9`, `LPT1-9`)
///   prefixed with `_`
/// - Trailing dots stripped (FAT32 restriction)
/// - Empty/whitespace-only names replaced with `unknown`
/// - Max 255 characters per path component
enum PathSanitizer {

    // MARK: - Unsafe Characters

    /// Characters invalid in FAT32 filenames.
    private static let unsafeCharacters = CharacterSet(charactersIn: "<>:\"/\\|?*")

    /// Windows reserved names (case-insensitive).
    private static let reservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]

    // MARK: - Public API

    /// Sanitize a string to be a valid FAT32 filename.
    ///
    /// Applies:
    /// 1. Strip invalid characters (replace with `_`)
    /// 2. Truncate to 255 characters
    /// 3. Prefix Windows reserved names with `_`
    /// 4. Strip trailing dots
    /// 5. Return `"unknown"` for empty results
    ///
    /// Matches the Tauri app's `sanitize_filename()` in `metadata/sanitize.rs`.
    ///
    /// - Parameter name: Raw string to sanitize
    /// - Returns: FAT32-safe filename
    static func sanitizeFilename(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return "unknown"
        }

        // Check reserved names BEFORE sanitization (match Rust behavior)
        let isReserved = isWindowsReserved(trimmed)

        // Replace unsafe characters with underscore
        var sanitized = trimmed
            .unicodeScalars
            .map { unsafeCharacters.contains($0) ? "_" : String($0) }
            .joined()

        // Strip trailing dots (FAT32 restriction)
        while sanitized.hasSuffix(".") {
            sanitized = String(sanitized.dropLast())
        }

        // Truncate to 255 characters
        if sanitized.count > 255 {
            sanitized = String(sanitized.prefix(255))
        }

        // Empty after sanitization → "unknown"
        if sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "unknown"
        }

        // Prefix reserved names with underscore (match Rust: _CON not CON_)
        if isReserved {
            return "_\(sanitized)"
        }

        return sanitized
    }

    /// Generate the organized path for a track: `artist/album/title.format`.
    ///
    /// Uses `albumArtist` for the artist directory (proper album grouping).
    /// All path components are sanitized for FAT32 compatibility.
    ///
    /// Matches `generate_organized_path()` in `metadata/sanitize.rs`.
    ///
    /// - Parameter metadata: Extracted track metadata
    /// - Returns: Organized relative path (e.g., `"the beatles/abbey road/come together.mp3"`)
    static func organizedPath(for metadata: TrackMetadata) -> String {
        let artist = sanitizeFilename(metadata.albumArtist)
        let album = sanitizeFilename(metadata.album)
        let title = sanitizeFilename(metadata.title)
        let ext = metadata.format

        return "\(artist)/\(album)/\(title).\(ext)"
    }

    /// Generate a SoundCloud-specific path: `SoundCloud/artist/title.format`.
    ///
    /// SoundCloud content uses a flat structure under a dedicated folder.
    /// Matches `generate_soundcloud_path()` in `metadata/sanitize.rs`.
    ///
    /// - Parameter metadata: Extracted track metadata
    /// - Returns: SoundCloud-organized relative path
    static func soundCloudPath(for metadata: TrackMetadata) -> String {
        let artist = sanitizeFilename(metadata.artist)
        let title = sanitizeFilename(metadata.title)
        let ext = metadata.format

        return "SoundCloud/\(artist)/\(title).\(ext)"
    }

    /// Resolve a relative organized_path against the library root.
    ///
    /// - Parameters:
    ///   - organizedPath: Relative path (e.g., `"artist/album/track.mp3"`)
    ///   - libraryRoot: Absolute path to library root directory
    /// - Returns: Full file URL
    static func resolveFullPath(organizedPath: String, libraryRoot: String) -> URL {
        URL(fileURLWithPath: libraryRoot)
            .appendingPathComponent(organizedPath)
    }

    // MARK: - Private Helpers

    /// Check if a name is a Windows reserved name.
    ///
    /// Handles names with extensions (CON.txt is still reserved).
    private static func isWindowsReserved(_ name: String) -> Bool {
        // Extract base name without extension
        let base: String
        if let dotIndex = name.firstIndex(of: ".") {
            base = String(name[..<dotIndex]).uppercased()
        } else {
            base = name.uppercased()
        }

        return reservedNames.contains(base)
    }
}
