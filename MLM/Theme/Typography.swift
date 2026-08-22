import SwiftUI

// MARK: - Typography Constants

/// Font definitions using platform-native text styles.
///
/// Provides semantic font aliases for consistent typography across the app.
/// Uses SwiftUI system fonts — adapts automatically to Dynamic Type settings.
enum MLMFont {
    // MARK: - Body Text

    /// Standard body text
    static let body = Font.body

    /// Body text bold
    static let bodyBold = Font.body.weight(.semibold)

    // MARK: - Data/Monospace

    /// Monospaced data display — bitrate, duration, file paths
    static let data = Font.system(.body, design: .monospaced)

    /// Alias for `data` — monospaced body
    static let mono = Font.system(.body, design: .monospaced)

    /// Small monospaced — keyboard shortcuts, technical info
    static let dataSmall = Font.system(.caption, design: .monospaced)

    // MARK: - Labels

    /// Section labels — small caps, semibold
    static let sectionLabel = Font.caption.weight(.semibold).smallCaps()

    /// Muted/secondary labels
    static let muted = Font.caption

    /// Badge/count labels
    static let badge = Font.caption2.weight(.medium)

    // MARK: - Headers

    /// Page title
    static let pageTitle = Font.title2.weight(.semibold)

    /// Section header
    static let sectionHeader = Font.headline

    /// Playlist/Album hero title
    static let heroTitle = Font.title.weight(.bold)

    // MARK: - Title Variants

    /// Title 2 — secondary title
    static let title2 = Font.title2

    /// Title 3 — tertiary title
    static let title3 = Font.title3

    // MARK: - Table

    /// Table header
    static let tableHeader = Font.caption.weight(.semibold)

    /// Table cell
    static let tableCell = Font.body

    // MARK: - Mini Player

    /// Now playing track title
    static let miniPlayerTitle = Font.subheadline.weight(.semibold)

    /// Now playing artist
    static let miniPlayerArtist = Font.caption
}
