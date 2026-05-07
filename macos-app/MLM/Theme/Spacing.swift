import SwiftUI

// MARK: - Solar Design System Layout Constants

/// Spacing and sizing constants matching the Solar design system.
///
/// Ported from the Tauri app's CSS custom properties.
enum MLMSpacing {
    // MARK: - Page Layout

    /// Page padding (p-4 in Tailwind)
    static let pagePadding: CGFloat = 16

    /// Card internal padding (p-3)
    static let cardPadding: CGFloat = 12

    /// Section gap between elements (gap-3)
    static let sectionGap: CGFloat = 12

    /// Standard item spacing (gap-2)
    static let itemGap: CGFloat = 8

    /// Tight spacing (gap-1)
    static let tightGap: CGFloat = 4

    // MARK: - Sidebar

    /// Sidebar width
    static let sidebarWidth: CGFloat = 192

    /// Sidebar item padding
    static let sidebarItemPadding: CGFloat = 8

    // MARK: - Table

    /// Table row height (36px dense)
    static let tableRowHeight: CGFloat = 36

    /// Table row vertical padding (6px)
    static let tableRowPaddingY: CGFloat = 6

    /// Table header height
    static let tableHeaderHeight: CGFloat = 32

    // MARK: - Activity Panel

    /// Activity panel collapsed height
    static let activityCollapsed: CGFloat = 36

    /// Activity panel expanded height
    static let activityExpanded: CGFloat = 320

    // MARK: - Mini Player

    /// Mini player bar height
    static let miniPlayerHeight: CGFloat = 36

    // MARK: - Detail Panels

    /// More Info panel width
    static let detailPanelWidth: CGFloat = 360

    /// Filter bar height
    static let filterBarHeight: CGFloat = 44

    // MARK: - Cards

    /// Playlist card width
    static let playlistCardWidth: CGFloat = 200

    /// Source card width
    static let sourceCardWidth: CGFloat = 280

    // MARK: - Corner Radius

    /// Standard corner radius
    static let cornerRadius: CGFloat = 6

    /// Large corner radius (cards)
    static let cornerRadiusLarge: CGFloat = 8

    /// Small corner radius (badges, pills)
    static let cornerRadiusSmall: CGFloat = 4
}
