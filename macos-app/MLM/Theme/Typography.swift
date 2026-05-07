import SwiftUI

// MARK: - Solar Design System Typography

/// Font definitions matching the Solar design system.
///
/// Uses IBM Plex font stack from the Tauri app's Solar theme.
/// Falls back to system fonts since IBM Plex requires bundling.
enum MLMFont {
    // MARK: - Body Text

    /// Standard body text — 13pt
    static let body = Font.system(size: 13, weight: .regular)

    /// Body text bold
    static let bodyBold = Font.system(size: 13, weight: .semibold)

    // MARK: - Data/Monospace

    /// Monospaced data display — bitrate, duration, file paths
    static let data = Font.system(size: 13, design: .monospaced)

    /// Small monospaced — keyboard shortcuts, technical info
    static let dataSmall = Font.system(size: 11, design: .monospaced)

    // MARK: - Labels

    /// Section labels — uppercase small caps, 11pt semibold
    static let sectionLabel = Font.system(size: 11, weight: .semibold).uppercaseSmallCaps()

    /// Muted/secondary labels — 11pt
    static let muted = Font.system(size: 11, weight: .regular)

    /// Badge/count labels — 10pt medium
    static let badge = Font.system(size: 10, weight: .medium)

    // MARK: - Headers

    /// Page title — 20pt semibold
    static let pageTitle = Font.system(size: 20, weight: .semibold)

    /// Section header — 15pt semibold
    static let sectionHeader = Font.system(size: 15, weight: .semibold)

    /// Playlist/Album hero title — Serif, 24pt
    static let heroTitle = Font.system(size: 24, weight: .bold, design: .serif)

    // MARK: - Table

    /// Table header — 11pt semibold
    static let tableHeader = Font.system(size: 11, weight: .semibold)

    /// Table cell — 13pt
    static let tableCell = Font.system(size: 13, weight: .regular)

    // MARK: - Mini Player

    /// Now playing track title — 12pt semibold
    static let miniPlayerTitle = Font.system(size: 12, weight: .semibold)

    /// Now playing artist — 11pt
    static let miniPlayerArtist = Font.system(size: 11, weight: .regular)
}
