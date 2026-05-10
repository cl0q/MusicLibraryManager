import SwiftUI

// MARK: - Native macOS Color Tokens

/// Semantic color aliases mapped to native macOS system tokens.
///
/// Uses NSColor system colors and SwiftUI semantic colors so the app
/// automatically adapts to Light/Dark mode and Accessibility settings.
/// No custom hex values — everything delegates to AppKit / SwiftUI.
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
    /// Warning
    static let mlmWarning = Color.orange

    // MARK: Energy Bars

    /// Energy level colors for the 1–5 LUFS-derived scale
    static let mlmEnergy1 = Color.cyan
    static let mlmEnergy2 = Color.green
    static let mlmEnergy3 = Color.yellow
    static let mlmEnergy4 = Color.orange
    static let mlmEnergy5 = Color.red

    // MARK: Source Brand Colors

    /// Spotify green
    static let mlmSpotify = Color.green
    /// SoundCloud orange
    static let mlmSoundCloud = Color.orange
    /// Apple Music pink
    static let mlmAppleMusic = Color.pink
}
