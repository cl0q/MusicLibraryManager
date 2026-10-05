import SwiftUI

/// View menu (M-VIEW): the system sidebar and toolbar items (`SidebarCommands`,
/// `ToolbarCommands`), the trailing column's two modes, the table menus (Columns, Sort By —
/// W2-A; Filter — W2-B) and Go to Current Track. Info and Queue are custom toggles of one `.inspector` with two
/// modes, so `InspectorCommands` (a second, mode-less toggle with its own key) is not used.
struct ViewCommands: Commands {
    @FocusedValue(\.trailingColumn) private var trailingColumn
    @FocusedValue(\.navigationModel) private var navigation
    @FocusedValue(\.playbackViewModel) private var playback
    @FocusedValue(\.toolbarSearch) private var search
    @FocusedValue(\.trackTableViewOptions) private var tableOptions
    @FocusedValue(\.trackSelection) private var focusedSelection
    @FocusedValue(\.viewScopeMenu) private var scopeMenu

    /// The focused table's options — not the kept-alive All Tracks table while another place
    /// shows (the same rule as the Track menu, `TrackSelection.usable`).
    private var usableTableOptions: TrackTableViewOptions? {
        guard let tableOptions else { return nil }
        if let selection = focusedSelection, TrackSelection.usable(selection, navigation: navigation) == nil {
            return nil
        }
        return tableOptions
    }

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()

        CommandGroup(after: .sidebar) {
            // ⌘I, ⌥⌘U — each opens the column in its mode or closes it (UC-TRAIL-01).
            CommandButton(.toggleInfo,
                          title: trailingColumn?.isShowing(.info) == true ? "Hide Info" : "Show Info",
                          enabled: trailingColumn != nil) {
                trailingColumn?.toggle(.info)
            }
            CommandButton(.toggleQueue,
                          title: trailingColumn?.isShowing(.queue) == true ? "Hide Queue" : "Show Queue",
                          enabled: trailingColumn != nil) {
                trailingColumn?.toggle(.queue)
            }

            Divider()

            // View ▸ Columns / Sort By follow the focused track table (UC-TABLE-03/04, M-VIEW.N04/N05).
            let table = usableTableOptions
            CommandSubmenu(.columns, enabled: table != nil) {
                if let table {
                    ForEach(table.columns, id: \.id) { column in
                        Toggle(column.id.title, isOn: Binding(
                            get: { column.isVisible },
                            set: { table.setColumnVisible(column.id, $0) }
                        ))
                    }
                }
            }
            CommandSubmenu(.sortBy, enabled: table?.isSortable == true) {
                if let table {
                    let order = table.sortOrder
                    if table.hasContainerOrder {
                        Toggle("Playlist Order", isOn: Binding(
                            get: { order?.isContainerOrder ?? true },
                            set: { if $0 { table.setSortOrder(TrackSortOrder(column: .number, ascending: true)) } }
                        ))
                        Divider()
                    }
                    ForEach(table.sortColumns) { column in
                        Toggle(column.title, isOn: Binding(
                            get: { order?.column == column && !(order?.isContainerOrder ?? false) },
                            set: { if $0 { table.setSortOrder(TrackSortOrder(column: column, ascending: order?.ascending ?? true)) } }
                        ))
                    }
                    Divider()
                    let sortedByColumn = order.map { !$0.isContainerOrder } ?? false
                    Toggle("Ascending", isOn: Binding(
                        get: { sortedByColumn && order?.ascending == true },
                        set: { if $0, let order { table.setSortOrder(TrackSortOrder(column: order.column, ascending: true)) } }
                    ))
                    .disabled(!sortedByColumn)
                    Toggle("Descending", isOn: Binding(
                        get: { sortedByColumn && order?.ascending == false },
                        set: { if $0, let order { table.setSortOrder(TrackSortOrder(column: order.column, ascending: false)) } }
                    ))
                    .disabled(!sortedByColumn)
                }
            }
            // View ▸ Filter lists the visible view's scopes, the current one checked
            // (UC-SCOPE-03, M-VIEW.N06); published by its `ScopeBar`.
            CommandSubmenu(.filter, enabled: scopeMenu?.items.isEmpty == false) {
                if let scopeMenu {
                    ForEach(scopeMenu.items) { item in
                        Toggle(item.title, isOn: Binding(
                            get: { scopeMenu.selectedID == item.id },
                            set: { if $0 { scopeMenu.select(item.id) } }
                        ))
                    }
                }
            }

            Divider()

            CommandButton(.goToCurrentTrack,
                          enabled: navigation != nil && playback?.currentTrack?.id != nil,
                          disabledReason: "Nothing is playing.") {
                goToCurrentTrack()
            }

            Divider()
        }
    }

    /// Go to Current Track ⌘L (M-VIEW.N07): selects the playing track in the list it plays
    /// from and scrolls to it (W2-C, `GoToCurrentTrack`; All Tracks when no list recorded it).
    private func goToCurrentTrack() {
        GoToCurrentTrack.perform(playback: playback, navigation: navigation, search: search)
    }
}
