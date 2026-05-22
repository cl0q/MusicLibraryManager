import AppKit
import Foundation

/// Deterministic palette + initials helper for fallback covers and mosaic gap tiles.
/// All palette entries draw from system semantic colors so Light/Dark and
/// user accent settings adapt automatically (per UI-SPEC Native-look mandate).
///
/// Phase 36 Plan 02 — consumed by `MosaicCompositor` and `PlaylistCoverService`.
enum GradientPalette {
    /// Locked palette (D-02 / D-03). 4 cool/neutral pairs — no rainbow.
    /// Returns (startColor, endColor) for a topLeading→bottomTrailing linear gradient.
    static func colors(forPlaylistId id: Int64) -> (NSColor, NSColor) {
        let index = abs(Int(truncatingIfNeeded: id)) % 4
        switch index {
        case 0:
            let accent = NSColor.controlAccentColor
            let dark = accent.blended(withFraction: 0.4, of: .darkGray) ?? accent
            return (accent, dark)
        case 1:
            return (.systemBlue, .systemIndigo)
        case 2:
            let dark = NSColor.systemBlue.blended(withFraction: 0.3, of: .black) ?? .systemBlue
            return (.systemTeal, dark)
        default: // 3
            return (.systemGray, .controlAccentColor)
        }
    }

    /// First 2 grapheme clusters of `name`, uppercased.
    /// Handles emoji and non-Latin gracefully (UI-SPEC line 83).
    /// "🎵 Workout" → "🎵W" ; "やる気" → "やる" ; "X" → "X".
    static func initials(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })

        if words.count >= 2 {
            // Two-word name: first cluster of each
            let a = words[0].prefix(1)
            let b = words[1].prefix(1)
            return (String(a) + String(b)).localizedUppercase
        } else {
            // Single word: first 2 grapheme clusters
            let collapsed = words.first.map(String.init) ?? trimmed
            return String(collapsed.prefix(2)).localizedUppercase
        }
    }
}
