import SwiftUI

// MARK: - Solar Design System Colors

/// Color tokens ported from the Solar — Pro Audio Light design system.
///
/// These match the Tauri app's `[data-theme="solar"]` CSS custom properties
/// defined in `.planning/research/solar-design/CONTRACT.md`.
extension Color {
    // MARK: Backgrounds

    /// Base background — deepest layer
    static let mlmBase = Color(hex: "#0c0c12")
    /// Surface background — cards, panels
    static let mlmSurface = Color(hex: "#14141c")
    /// Raised surface — hover states, elevated cards
    static let mlmRaised = Color(hex: "#1c1c26")
    /// Overlay — modals, dropdowns
    static let mlmOverlay = Color(hex: "#24242e")

    // MARK: Borders

    /// Standard border
    static let mlmEdge = Color(hex: "#2a2a36")
    /// Subtle border — separators
    static let mlmEdgeSubtle = Color(hex: "#1e1e28")

    // MARK: Text

    /// Primary text
    static let mlmInk = Color(hex: "#e8e8f0")
    /// Secondary text — labels, descriptions
    static let mlmInkSecondary = Color(hex: "#8888a0")
    /// Muted text — placeholders, disabled
    static let mlmInkMuted = Color(hex: "#55556a")

    // MARK: Accent

    /// Primary accent — warm amber
    static let mlmAccent = Color(hex: "#d4940c")
    /// Bright accent — hover/active states
    static let mlmAccentBright = Color(hex: "#f0a818")

    // MARK: Status

    /// Success — emerald-400
    static let mlmSuccess = Color(hex: "#34d399")
    /// Error — rose-400
    static let mlmError = Color(hex: "#fb7185")
    /// Active/Info — sky-400
    static let mlmActive = Color(hex: "#38bdf8")
    /// Warning — amber-400
    static let mlmWarning = Color(hex: "#fbbf24")

    // MARK: Energy Bars

    /// Energy level colors for the 1–5 LUFS-derived scale
    static let mlmEnergy1 = Color(hex: "#22d3ee") // cyan-400
    static let mlmEnergy2 = Color(hex: "#34d399") // emerald-400
    static let mlmEnergy3 = Color(hex: "#fbbf24") // amber-400
    static let mlmEnergy4 = Color(hex: "#fb923c") // orange-400
    static let mlmEnergy5 = Color(hex: "#fb7185") // rose-400

    // MARK: Source Brand Colors

    /// Spotify green
    static let mlmSpotify = Color(hex: "#1DB954")
    /// SoundCloud orange
    static let mlmSoundCloud = Color(hex: "#FF5500")
    /// Apple Music gradient start (pink)
    static let mlmAppleMusic = Color(hex: "#FA2D48")
}

// MARK: - Hex Color Initializer

extension Color {
    /// Initialize a Color from a hex string (e.g., "#FF5500" or "FF5500").
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r, g, b, a: UInt64
        switch hex.count {
        case 6: // RGB
            (r, g, b, a) = (
                (int >> 16) & 0xFF,
                (int >> 8) & 0xFF,
                int & 0xFF,
                255
            )
        case 8: // ARGB
            (r, g, b, a) = (
                (int >> 16) & 0xFF,
                (int >> 8) & 0xFF,
                int & 0xFF,
                (int >> 24) & 0xFF
            )
        default:
            (r, g, b, a) = (0, 0, 0, 255)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
