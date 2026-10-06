import SwiftUI

// MARK: - Constant toolbar (P-TOOLBAR, UC-TB-01…05, DEC-048)

/// The main window's toolbar — the same in every destination. Order (UC-TB-01): sidebar
/// toggle (system, from `NavigationSplitView`) · Back / Forward · Add · — · player
/// (`.principal`, with the queue button) · — · Activity · Info · search (`.searchable`,
/// attached by `ContentView`).
///
/// Customizable (UC-TB-04): Add and Activity can be removed; the rest can't.
///
/// Narrow windows give way in a fixed order (UC-TB-03): (1) the player's title / artist column
/// (`PlayerBar`, `ViewThatFits`), (2) the Activity item's text (`ViewThatFits`
/// inside `ActivityToolbarItem`), (3) Add moves into the overflow menu — the
/// lowest visibility priority. Back / Forward, the player and Info have the highest; the search
/// field is the system's `.searchable` and isn't a toolbar item MLM can rank.
struct ShellToolbar: CustomizableToolbarContent {
    let playbackViewModel: PlaybackViewModel?

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "shell.backForward", placement: .navigation) {
            BackForwardButtons()
        }
        .customizationBehavior(.disabled)
        .visibilityPriority(.high)

        ToolbarItem(id: "shell.add", placement: .navigation) {
            AddMenu()
        }
        .visibilityPriority(.low)

        ToolbarItem(id: "shell.player", placement: .principal) {
            if let playbackViewModel {
                PlayerBar(viewModel: playbackViewModel)
            }
        }
        .customizationBehavior(.disabled)
        .visibilityPriority(.high)

        ToolbarItem(id: "shell.activity", placement: .primaryAction) {
            ActivityToolbarItem()
        }
        .visibilityPriority(.automatic)

        ToolbarItem(id: "shell.info", placement: .primaryAction) {
            InfoToggleButton()
        }
        .customizationBehavior(.disabled)
        .visibilityPriority(.high)
    }
}

// MARK: - Back / Forward

/// Back ⌘[ / Forward ⌘] for pushed details (UC-KEY-24). The key equivalents live in the
/// Go menu (one definition per key, UC-KEY-36).
struct BackForwardButtons: View {
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        ControlGroup {
            Button {
                navigation.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!navigation.canGoBack)
            .help("Back ⌘[")
            .accessibilityLabel("Back")

            Button {
                navigation.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!navigation.canGoForward)
            .help("Forward ⌘]")
            .accessibilityLabel("Forward")
        }
        .controlGroupStyle(.navigation)
    }
}

// MARK: - Add menu (P-ADDMENU, UC-TB-05)

/// Exactly the UC-TB-05 items. Items whose feature arrives in wave 3 are disabled with a
/// help text that says what is missing (never enabled-but-dead, UC-MENU-02).
struct AddMenu: View {
    @Environment(ShellActions.self) private var actions

    /// Help text of the one Add-menu item that can be unavailable (UC-TB-05).
    enum Unavailable {
        /// UC-TB-05.
        static let refreshFromSources = ImportSheetsPresenter.noSourceConnected
    }

    var body: some View {
        Menu {
            Button("New Playlist") {
                actions.newPlaylist()
            }
            Button("New Playlist Folder") {
                Task { await actions.edits.newPlaylistFolder() }
            }

            Divider()

            Button("Add from Link…") {
                actions.addFromLink()
            }
            Button("Import Playlist from Source…") {
                actions.importPlaylistFromSource()
            }
            Button("Import Files or Folder…") {
                actions.chooseImportFolder()
            }
            Button("Import M3U…") {
                DropCenter.shared.chooseM3U(into: nil)
            }

            Divider()

            Button("Refresh from Sources") {
                actions.refreshFromSources()
            }
            .disabled(!actions.canRefreshFromSources)
            .help(actions.canRefreshFromSources ? "" : Unavailable.refreshFromSources)
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuIndicator(.hidden)
        .help("Add")
        .accessibilityLabel("Add")
    }
}

// MARK: - Activity item (W3-ACT)

// `ActivityToolbarItem` (MLM/Views/Activity/ActivityToolbarItem.swift): the toolbar item,
// its popover and its text that gives way at narrow widths (UC-TB-03 step 2).

// MARK: - Info toggle

/// ⓘ — opens / closes the trailing column in Info mode (⌘I, UC-TRAIL-01).
struct InfoToggleButton: View {
    @Environment(TrailingColumnState.self) private var trailing

    var body: some View {
        let showing = trailing.isShowing(.info)
        Button {
            trailing.toggle(.info)
        } label: {
            Label("Info", systemImage: "info.circle")
        }
        .help(showing ? "Hide Info ⌘I" : "Show Info ⌘I")
        .accessibilityLabel(showing ? "Hide Info" : "Show Info")
    }
}
