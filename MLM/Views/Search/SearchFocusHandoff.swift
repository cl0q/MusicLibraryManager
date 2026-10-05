import AppKit

/// Return in the search field with nothing to confirm moves focus to the filtered rows
/// (UC-SEARCH-06, K-SEARCH-RETURN): the visible table of the main window becomes first
/// responder and, without a selection, its first row is selected — so ↑/↓, Space and Return
/// work on the results.
///
/// AppKit because SwiftUI can't move focus out of the toolbar's search field into a table
/// another view owns (UC-KIT-37: only where SwiftUI has no equivalent). The visible table is
/// the one the window hit-tests at its centre: the kept-alive All Tracks table (opacity 0, no
/// hit testing) and the sidebar are never chosen.
@MainActor
enum SearchFocusHandoff {
    static func moveToResults() {
        moveToResults(in: NSApp.keyWindow)
    }

    static func moveToResults(in window: NSWindow?) {
        guard let window, let content = window.contentView else { return }
        let tables = allTables(in: content)
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.numberOfRows > 0 && isOnTop($0, in: window) }
            .sorted { area($0) > area($1) }
        guard let table = tables.first else { return }
        window.makeFirstResponder(table)
        if table.selectedRow < 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    private static func allTables(in view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        if let table = view as? NSTableView, !(table is NSOutlineView) { found.append(table) }
        for subview in view.subviews { found.append(contentsOf: allTables(in: subview)) }
        return found
    }

    /// The table is what the window hits at the centre of its visible part.
    private static func isOnTop(_ table: NSTableView, in window: NSWindow) -> Bool {
        let visible = table.visibleRect
        guard visible.width > 0, visible.height > 0, let content = window.contentView else { return false }
        let centre = table.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
        // `hitTest` takes a point in the receiver's superview's coordinates.
        let point = content.superview?.convert(centre, from: nil) ?? centre
        guard let hit = content.hitTest(point) else { return false }
        return hit === table || hit.isDescendant(of: table)
    }

    private static func area(_ table: NSTableView) -> CGFloat {
        let visible = table.visibleRect
        return visible.width * visible.height
    }
}
