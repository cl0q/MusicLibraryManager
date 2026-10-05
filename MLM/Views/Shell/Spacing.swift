import CoreGraphics

/// The only explicit layout values (UC-SPACE-01). Prefer system spacing; use these when a
/// value must be stated.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 6
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
}

/// Fixed metrics of the shell (UC-SPACE-03).
enum ShellMetrics {
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarIdealWidth: CGFloat = 232
    static let trailingMinWidth: CGFloat = 280
    static let trailingIdealWidth: CGFloat = 300
    static let trailingMaxWidth: CGFloat = 360
    static let statusBarHeight: CGFloat = 24
}
