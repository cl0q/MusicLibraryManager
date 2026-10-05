import SwiftUI

/// Presentation rules for track metadata values (DEC-013, UC-TABLE-11): an absent value, the
/// literal `unknown album` and a source name stored as album render as `—`, never as the
/// placeholder literal and never italic.
enum TrackMetadataPresentation {
    /// Album strings that are not albums: placeholders written by imports and source names
    /// stored as album (ROADMAP §0.3: `unknown album`, `SoundCloud`, `YouTube`, `Downloads`,
    /// `Web`, `Unknown`, `''`, URLs, `SoundCloud Likes`; plus the import buckets below).
    static let nonAlbumLiterals: Set<String> = [
        "unknown album",
        "unknown",
        "soundcloud",
        "soundcloud likes",
        "youtube",
        "spotify",
        "downloads",
        "web",
        "discovered neighbors",
        "reels inbox imports",
    ]

    /// Artist strings that are placeholders.
    static let nonArtistLiterals: Set<String> = ["unknown", "unknown artist"]

    /// Whether `album` names a real album. Pure — the single decision every view uses.
    static func isRealAlbum(_ album: String?) -> Bool {
        guard let album else { return false }
        let normalized = album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return false }
        if nonAlbumLiterals.contains(normalized) { return false }
        if normalized.hasPrefix("http://") || normalized.hasPrefix("https://") || normalized.hasPrefix("www.") {
            return false
        }
        return true
    }

    /// The album as shown, `nil` for `—`.
    static func albumDisplay(_ album: String?) -> String? {
        guard isRealAlbum(album), let album else { return nil }
        return album.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The artist as shown, `nil` for `—`.
    static func artistDisplay(_ artist: String?) -> String? {
        guard let artist else { return nil }
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || nonArtistLiterals.contains(trimmed.lowercased()) { return nil }
        return trimmed
    }

    /// Whether a value is an import placeholder (album or artist) — kept for callers outside
    /// the track table (Folders).
    static func isPlaceholder(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return nonAlbumLiterals.contains(normalized) || nonArtistLiterals.contains(normalized)
    }

    static func sourceName(for track: Track) -> String {
        let path = track.originalPath.lowercased()
        let format = track.format.lowercased()
        let album = track.album.lowercased()

        if album == "reels" || path.hasPrefix("reels://") {
            return "Reels"
        }
        if path.contains("soundcloud") || format == "soundcloud" {
            return "SoundCloud"
        }
        if path.contains("youtube") || format == "youtube" {
            return "YouTube"
        }
        if format == "qobuz" || path.contains("qobuz") {
            return "Qobuz"
        }
        if format == "dab" {
            return "DAB"
        }
        return "Local import"
    }
}

/// A metadata value with the shared absent-value treatment (`—` in `.tertiary`, UC-TABLE-11).
/// Used outside the track table (Folders); the table renders its precomputed row texts.
struct TrackMetadataText: View {
    let value: String
    let secondary: Bool

    init(_ value: String, secondary: Bool = false) {
        self.value = value
        self.secondary = secondary
    }

    var body: some View {
        if TrackMetadataPresentation.isPlaceholder(value) || value.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("—")
                .foregroundStyle(.tertiary)
        } else {
            Text(value)
                .foregroundStyle(secondary ? .secondary : .primary)
                .lineLimit(1)
        }
    }
}
