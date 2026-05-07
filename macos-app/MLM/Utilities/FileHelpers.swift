import Foundation

/// File and path utility functions.
///
/// Provides helpers for path operations matching the Tauri app's
/// `metadata/sanitize.rs` behavior.
enum FileHelpers {
    /// Characters not allowed in FAT32 filenames.
    private static let fatUnsafeChars = CharacterSet(charactersIn: "\\/:*?\"<>|")

    /// Sanitize a filename for FAT32 compatibility.
    ///
    /// Strips unsafe characters and trims whitespace/dots from the end.
    /// Matches the Tauri app's `sanitize_filename` behavior.
    static func sanitizeFilename(_ name: String) -> String {
        var sanitized = name
            .components(separatedBy: fatUnsafeChars)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove trailing dots (FAT32 restriction)
        while sanitized.hasSuffix(".") {
            sanitized = String(sanitized.dropLast())
        }

        // Fallback for empty result
        if sanitized.isEmpty {
            sanitized = "Unknown"
        }

        return sanitized
    }

    /// Build an organized path: `<sanitized_artist>/<sanitized_album>/<filename>`.
    static func organizedPath(artist: String, album: String, filename: String) -> String {
        let sanitizedArtist = sanitizeFilename(artist)
        let sanitizedAlbum = sanitizeFilename(album)
        return "\(sanitizedArtist)/\(sanitizedAlbum)/\(filename)"
    }

    /// Resolve a relative organized_path against the library root.
    static func resolveFullPath(organizedPath: String, libraryRoot: String) -> URL {
        URL(fileURLWithPath: libraryRoot)
            .appendingPathComponent(organizedPath)
    }

    /// Extract the folder prefix from an organized path (everything before the last `/`).
    static func folderPrefix(from organizedPath: String) -> String? {
        guard let lastSlash = organizedPath.lastIndex(of: "/") else {
            return nil
        }
        return String(organizedPath[..<lastSlash])
    }

    /// Check if a file exists at the given path.
    static func fileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Get the file size in bytes.
    static func fileSize(at path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attrs[.size] as? Int64
    }
}
