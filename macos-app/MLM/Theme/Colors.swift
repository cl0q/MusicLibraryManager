import AppKit
import SwiftUI

// MARK: - Native macOS Color Tokens

/// Semantic color aliases mapped to native macOS system tokens.
///
/// Uses system colors for semantic roles and adaptive AppKit colors for
/// source brands, so the app adapts to Light/Dark mode and Accessibility settings.
extension Color {
    // MARK: Backgrounds

    /// Base background — window chrome
    static let mlmBase = Color(NSColor.windowBackgroundColor)
    /// Surface background — cards, panels
    static let mlmSurface = Color(NSColor.controlBackgroundColor)
    /// Raised surface — hover states, elevated cards
    static let mlmRaised = Color(NSColor.underPageBackgroundColor)
    /// Overlay — modals, dropdowns
    static let mlmOverlay = Color(NSColor.controlBackgroundColor)

    // MARK: Borders

    /// Standard border / separator
    static let mlmEdge = Color(NSColor.separatorColor)
    /// Subtle border — lighter separator
    static let mlmEdgeSubtle = Color(NSColor.separatorColor).opacity(0.5)

    // MARK: Text

    /// Primary text
    static let mlmInk = Color.primary
    /// Alias for mlmInk (used by some views)
    static let mlmInkPrimary = Color.primary
    /// Secondary text — labels, descriptions
    static let mlmInkSecondary = Color.secondary
    /// Muted text — placeholders, disabled
    static let mlmInkMuted = Color(NSColor.tertiaryLabelColor)

    // MARK: Accent

    /// Primary accent — system accent color
    static let mlmAccent = Color.accentColor
    /// Bright accent — hover/active states
    static let mlmAccentBright = Color.accentColor

    // MARK: Status

    /// Success
    static let mlmSuccess = Color.green
    /// Error
    static let mlmError = Color.red
    /// Active/Info
    static let mlmActive = Color.blue
    /// Needs user review or action.
    static let mlmAttention = Color.orange
    /// Legacy alias retained for existing views.
    static let mlmWarning = mlmAttention

    // MARK: Energy Bars

    /// Accent opacity for a 1–5 LUFS-derived energy level.
    static func mlmEnergyOpacity(for level: Int) -> Double {
        let clampedLevel = min(max(level, 1), 5)
        return 0.25 + Double(clampedLevel - 1) * (0.75 / 4)
    }

    // MARK: Source Brand Colors

    /// SoundCloud orange (#FF5500).
    static let mlmBrandSoundCloud = adaptiveBrandColor(
        light: NSColor(srgbRed: 1, green: 85 / 255, blue: 0, alpha: 1),
        dark: NSColor(srgbRed: 230 / 255, green: 77 / 255, blue: 0, alpha: 1)
    )
    /// Spotify green (#1DB954).
    static let mlmBrandSpotify = adaptiveBrandColor(
        light: NSColor(srgbRed: 29 / 255, green: 185 / 255, blue: 84 / 255, alpha: 1),
        dark: NSColor(srgbRed: 26 / 255, green: 166 / 255, blue: 77 / 255, alpha: 1)
    )
    /// YouTube red (#FF0000).
    static let mlmBrandYouTube = adaptiveBrandColor(
        light: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
        dark: NSColor(srgbRed: 230 / 255, green: 0, blue: 0, alpha: 1)
    )
    /// Apple Music pink-red (#FA243C).
    static let mlmBrandAppleMusic = adaptiveBrandColor(
        light: NSColor(srgbRed: 250 / 255, green: 36 / 255, blue: 60 / 255, alpha: 1),
        dark: NSColor(srgbRed: 225 / 255, green: 33 / 255, blue: 54 / 255, alpha: 1)
    )

    /// Legacy aliases retained while existing source views move to brand tokens.
    static let mlmSpotify = mlmBrandSpotify
    static let mlmSoundCloud = mlmBrandSoundCloud
    static let mlmAppleMusic = mlmBrandAppleMusic

    private static func adaptiveBrandColor(light: NSColor, dark: NSColor) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
