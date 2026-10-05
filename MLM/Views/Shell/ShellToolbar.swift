import SwiftUI

// MARK: - Constant toolbar (P-TOOLBAR, UC-TB-01…05, DEC-048)

/// The main window's toolbar — the same in every destination. Order (UC-TB-01): sidebar
/// toggle (system, from `NavigationSplitView`) · Back / Forward · Add · — · player
/// (`.principal`, with the queue button) · — · Activity · Info · search (`.searchable`,
/// attached by `ContentView`).
///
/// Customizable (UC-TB-04): Add and Activity can be removed; the rest can't.
struct ShellToolbar: CustomizableToolbarContent {
    let playbackViewModel: PlaybackViewModel?

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "shell.backForward", placement: .navigation) {
            BackForwardButtons()
        }
        .customizationBehavior(.disabled)

        ToolbarItem(id: "shell.add", placement: .navigation) {
            AddMenu()
        }

        ToolbarItem(id: "shell.player", placement: .principal) {
            if let playbackViewModel {
                PlayerBar(viewModel: playbackViewModel)
            }
        }
        .customizationBehavior(.disabled)

        ToolbarItem(id: "shell.activity", placement: .primaryAction) {
            ActivityToolbarButton()
        }

        ToolbarItem(id: "shell.info", placement: .primaryAction) {
            InfoToggleButton()
        }
        .customizationBehavior(.disabled)
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

    /// Help texts of the items that are not available yet (W3-PL, W3-ADD).
    enum Unavailable {
        static let playlistFolder = "Playlist folders aren’t available yet."
        static let addFromLink = "Adding a track from a link isn’t available yet. To import a playlist from a link, choose Import Playlist from Source… in this menu."
        static let importM3U = "To import an M3U file now, open a playlist and choose Import M3U… there."
        static let refreshFromSources = "Refreshing all sources at once isn’t available yet. Open a linked playlist to refresh it."
    }

    var body: some View {
        Menu {
            Button("New Playlist") {
                actions.newPlaylist()
            }
            Button("New Playlist Folder") {}
                .disabled(true)
                .help(Unavailable.playlistFolder)

            Divider()

            Button("Add from Link…") {}
                .disabled(true)
                .help(Unavailable.addFromLink)
            Button("Import Playlist from Source…") {
                actions.showSources()
            }
            Button("Import Files or Folder…") {
                actions.chooseImportFolder()
            }
            Button("Import M3U…") {}
                .disabled(true)
                .help(Unavailable.importM3U)

            Divider()

            Button("Refresh from Sources") {}
                .disabled(true)
                .help(Unavailable.refreshFromSources)
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuIndicator(.hidden)
        .help("Add")
        .accessibilityLabel("Add")
    }
}

// MARK: - Activity item (placeholder until W3-ACT)

/// Placeholder for the Activity toolbar item (DEC-005, P-ACTIVITY): toggles the existing
/// bottom Activity panel until W3-ACT replaces both with the popover and the Activity window.
/// Shows a spinner while something runs; its help and accessibility value carry the
/// panel's headline text.
struct ActivityToolbarButton: View {
    @AppStorage(ActivityPanelHosting.expandedKey) private var isPanelShown = false
    @Environment(\.container) private var container

    var body: some View {
        let headline = ActivityPanelHosting.headline(container)
        Button {
            isPanelShown.toggle()
        } label: {
            if headline.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Activity", systemImage: "list.bullet.rectangle")
            }
        }
        .help(isPanelShown ? "Hide Activity" : (headline.isEmpty ? "Show Activity" : headline.tooltip))
        .accessibilityLabel("Activity")
        .accessibilityValue(headline.text)
    }
}

/// How the shell hosts the bottom `ActivityPanel` until W3-ACT: the panel is shown only
/// while expanded (no permanent strip, DEC-005); the toolbar item expands it, the panel's
/// own header collapses it.
enum ActivityPanelHosting {
    /// The panel's own persisted expansion key (`ActivityPanel`).
    static let expandedKey = "activity.panel.expanded"

    /// The panel's headline, built exactly as `ActivityPanel` builds it.
    @MainActor
    static func headline(_ container: DependencyContainer) -> ActivityHeadline {
        guard let vm = container.activityViewModel else {
            return ActivityHeadline(text: "", tooltip: "", isBusy: false, isEmpty: true)
        }
        let queueService = PerformanceQueueService.shared
        return ActivityFeed.makeSnapshot(
            operations: vm.operations,
            stalledIDs: vm.stalledOperationIDs,
            recentOperations: vm.recentOperations,
            recentTruncated: vm.isRecentTruncated,
            download: container.downloadViewModel.map { $0.sourceState(operationID: nil) },
            sync: nil,
            queue: QueueSourceState(
                activeJobDescription: queueService.activeJobDescription,
                pendingAnalyses: queueService.pendingAnalysesCount,
                pendingDownloads: queueService.pendingDownloadsCount
            ),
            persistedFailures: [],
            now: Date()
        ).headline
    }
}

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
