import AppKit
import SwiftUI

// MARK: - Selection bar (P-SELBAR, DEC-015, UC-SELBAR-01…05)

/// The selection bar: a transient cluster of the most-used batch actions that floats over the
/// bottom of a track list while two or more of its shown rows are selected — **the one custom
/// Liquid Glass surface of the app** (UC-GLASS-05, UC-SELBAR-04). Every other surface gets its
/// glass from the system; nothing else in `MLM/` calls a glass API (pinned by a test).
///
/// Lives in `ContentScaffold`'s `selectionBar:` slot, which puts it 12 pt above the status bar,
/// over the content, without shrinking the table (UC-LAYOUT-04). It acts on the table that
/// registered with the scaffold's channel (`hostsTrackSelectionBar()`), through that table's
/// own `TrackListActions` — the same actions as its context menu and the Track menu
/// (UC-SELBAR-03): confirmations, Undo and the Remove from Library… alert come from there.
///
/// Construction (UC-GLASS-05/08/14, UC-MOTION-02/03):
/// - `GlassEffectContainer { HStack { … }.glassEffect(.regular.interactive(), in: .capsule) }`,
///   no tint; the buttons inside are `.borderless` — never glass on glass.
/// - Appears / disappears with the container's glass transition (`glassEffectID` +
///   `.materialize`); with Reduce Motion as a plain opacity change.
/// - With Reduce Transparency the capsule is opaque: `windowBackgroundColor` + a separator
///   stroke. An environment branch — no availability check.
///
/// Keyboard: every bar action is also a Track menu item and a context-menu item (UC-MENU-02);
/// the bar registers no key equivalent. Its buttons are in the key view loop only with Full
/// Keyboard Access (the system rule for buttons); appearing never takes focus from the table.
struct TrackSelectionBar: View {
    var host: TrackSelectionBarHost = .place

    @Environment(TrackSelectionBarChannel.self) private var channel: TrackSelectionBarChannel?
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @Environment(TrailingColumnState.self) private var trailingColumn: TrailingColumnState?
    @Environment(\.container) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var glassNamespace

    var body: some View {
        let presentation = channel?.source.flatMap(present)
        let isShown = presentation != nil
        GlassEffectContainer {
            if let presentation {
                SelectionBarCapsule(
                    presentation: presentation,
                    glassNamespace: glassNamespace,
                    reduceMotion: reduceMotion,
                    reduceTransparency: reduceTransparency
                )
                // The plain opacity change under Reduce Motion / Reduce Transparency; with glass
                // the container's materialize transition carries the morph.
                .transition(.opacity)
            }
        }
        // Never wider than the content: the capsule picks the widest layout that fits.
        .padding(.horizontal, Spacing.l)
        .animation(.default, value: isShown)
        .onChange(of: isShown) { _, nowShown in
            // Announced once when it appears, not on every count change (UC-A11Y-05).
            if nowShown, let label = presentation?.state.accessibilityLabel {
                AccessibilityNotification.Announcement(label).post()
            }
        }
    }

    /// The bar for the registered table now, or `nil`. Cheap while hidden: the selection count
    /// is checked before any row is read; then the work is proportional to the selection.
    private func present(_ source: TrackSelectionBarSource) -> SelectionBarPresentation? {
        let model = source.model
        let configuration = source.configuration
        guard TrackSelectionBarVisibility.isShown(
            host: host,
            list: configuration.listContext,
            allTracksVisible: navigation?.isAllTracksVisible ?? true,
            isSearching: container.searchCoordinator.isPresented
        ) else { return nil }
        guard model.isLoaded, model.selection.count >= SelectionBarState.minimumCount else { return nil }
        let rows = model.selectedRows()
        let context = TrackMenuContext(
            container: configuration.listContext.container,
            canActivate: configuration.activate != nil,
            canRemoveFromContainer: configuration.removeFromContainer != nil,
            canAddToSyncProfile: configuration.canAddToSyncProfile,
            extras: configuration.menuExtras?.items(rows) ?? .none
        )
        let live = source.live.state
        guard let state = SelectionBarState.make(
            rows: rows,
            context: context,
            live: live,
            // Downloads queue behind a running batch (W3-ACT N4): never busy.
            isDownloadBusy: false,
            canShowInfo: trailingColumn != nil
        ) else { return nil }
        return SelectionBarPresentation(
            state: state,
            rows: rows,
            source: source,
            offlineVolumeName: live.offlineVolumeName,
            editInfo: { [trailingColumn] in
                // Edit Info = ⌘I's Info for the selection (Info already follows it, W2-E). It
                // only opens Info — it never closes it.
                guard let trailingColumn, !trailingColumn.isShowing(.info) else { return }
                trailingColumn.toggle(.info)
            }
        )
    }
}

/// One rendering of the bar: its state, the rows it acts on (shown selected rows, display
/// order) and the table it belongs to.
private struct SelectionBarPresentation {
    let state: SelectionBarState
    let rows: [TrackRow]
    let source: TrackSelectionBarSource
    let offlineVolumeName: String?
    let editInfo: () -> Void
}

// MARK: - The capsule

private struct SelectionBarCapsule: View {
    let presentation: SelectionBarPresentation
    let glassNamespace: Namespace.ID
    let reduceMotion: Bool
    let reduceTransparency: Bool

    @Environment(\.container) private var container
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(NavigationModel.self) private var navigation: NavigationModel?

    private var state: SelectionBarState { presentation.state }
    private var rows: [TrackRow] { presentation.rows }

    /// The table's own actions — the same implementation as its context menu (UC-SELBAR-03).
    private var actions: TrackListActions {
        let source = presentation.source
        return TrackListActions(model: source.model, configuration: source.configuration, live: source.live,
                                statusBar: statusBar, undo: undo, shell: shell, container: container,
                                navigation: navigation)
    }

    var body: some View {
        // Narrow content: titles give way to symbols (each keeps its title as accessibility
        // label and tooltip), then the duration goes. Never wider than the content.
        ViewThatFits(in: .horizontal) {
            row(.titles)
            row(.symbols)
            row(.compact)
        }
        .buttonStyle(.borderless)
        .padding(.leading, Spacing.l)
        .padding(.trailing, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .modifier(SelectionBarSurface(
            glassNamespace: glassNamespace,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        ))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.accessibilityLabel)
        .focusSection()
    }

    private enum Layout {
        /// Count + duration, titled buttons (the mockup).
        case titles
        /// Count + duration, symbol buttons.
        case symbols
        /// Count only, symbol buttons.
        case compact

        var showsTitles: Bool { self == .titles }
    }

    private var configuration: TrackListConfiguration { presentation.source.configuration }

    /// Held recommendations act on the verdicts (V-INBOX.N06): `Keep` · `Keep and Add to Playlist ▾`
    /// · `Dismiss`, one undo step per batch.
    private var isRecommendations: Bool { configuration.listContext.container == .recommendations }

    @ViewBuilder
    private func row(_ layout: Layout) -> some View {
        if isRecommendations {
            recommendationRow(layout)
        } else {
            standardRow(layout)
        }
    }

    private func recommendationRow(_ layout: Layout) -> some View {
        let extras = configuration.menuExtras?.items(rows) ?? .none
        let perform = configuration.menuExtras?.perform
        let rows = self.rows
        return HStack(spacing: Spacing.xxs) {
            countText(showsDuration: layout != .compact)
                .padding(.trailing, Spacing.s)
            if let keep = extras.addTo.first {
                Button { perform?(keep.id, rows) } label: {
                    verdictLabel(keep.title, "checkmark.circle", layout)
                }
                .help("Keep K")
            }
            Menu {
                AddToPlaylistMenuItems(
                    playlists: SelectionBarState.playlists(TrackMenuSources.shared.playlists, for: configuration.listContext.container),
                    showsKeyEquivalents: false,
                    newPlaylist: { perform?("keepAndAdd:new", rows) },
                    add: { perform?("keepAndAdd:\($0)", rows) }
                )
            } label: {
                verdictLabel("Keep and Add to Playlist", "text.badge.plus", layout)
            }
            .menuStyle(.button)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Keep and Add to Playlist")
            if let dismiss = extras.remove.first {
                Button { perform?(dismiss.id, rows) } label: {
                    verdictLabel(dismiss.title, "trash", layout)
                }
                .disabled(!dismiss.isEnabled)
                .help(dismiss.isEnabled ? "Dismiss ⌫" : "Dismiss is unavailable while the library’s drive is not connected")
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func verdictLabel(_ title: String, _ symbol: String, _ layout: Layout) -> some View {
        let content = Label(title, systemImage: symbol)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .contentShape(.capsule)
        if layout.showsTitles {
            content.labelStyle(.titleOnly)
        } else {
            content.labelStyle(.iconOnly)
        }
    }

    private func standardRow(_ layout: Layout) -> some View {
        HStack(spacing: Spacing.xxs) {
            countText(showsDuration: layout != .compact)
                .padding(.trailing, Spacing.s)
            button(state.playNext, layout) { actions.playNext(rows) }
            addToPlaylistMenu(layout)
            button(state.editInfo, layout) { presentation.editInfo() }
            if let download = state.download {
                button(download, layout) { actions.download(rows) }
            }
            moreMenu
        }
        .fixedSize()
    }

    /// `14 selected` (semibold) and `52 min` (secondary), monospaced digits (UC-TYPE-03).
    private func countText(showsDuration: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(state.countText)
                .font(.body.weight(.semibold))
            if showsDuration {
                Text(state.durationText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func button(_ action: SelectionBarAction, _ layout: Layout, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            label(action, layout)
        }
        .disabled(!action.isEnabled)
        .help(action.help)
        .accessibilityLabel(action.title)
    }

    @ViewBuilder
    private func label(_ action: SelectionBarAction, _ layout: Layout) -> some View {
        let content = Label(action.title, systemImage: action.systemImage)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .contentShape(.capsule)
        if layout.showsTitles {
            content.labelStyle(.titleOnly)
        } else {
            content.labelStyle(.iconOnly)
        }
    }

    /// `Add to Playlist ▾`: the CM-SUB-PLAYLIST builder (UC-CM-11).
    private func addToPlaylistMenu(_ layout: Layout) -> some View {
        let actions = self.actions
        let rows = self.rows
        return Menu {
            AddToPlaylistMenuItems(
                playlists: SelectionBarState.playlists(
                    TrackMenuSources.shared.playlists,
                    for: presentation.source.configuration.listContext.container
                ),
                showsKeyEquivalents: false,
                newPlaylist: { actions.newPlaylist(rows) },
                add: { actions.addToPlaylist($0, rows) }
            )
        } label: {
            label(state.addToPlaylist, layout)
        }
        .menuStyle(.button)
        .menuIndicator(.visible)
        .fixedSize()
        .help(state.addToPlaylist.help)
        .accessibilityLabel(state.addToPlaylist.title)
    }

    /// `More` (•••): the multi-selection track menu without the bar's four actions, built by
    /// the context menu's builder (UC-CM-02). No key equivalents: this menu stays in the window.
    private var moreMenu: some View {
        let sources = TrackMenuSources.shared
        let container = presentation.source.configuration.listContext.container
        return Menu {
            TrackMenu(
                model: state.moreMenu,
                rows: rows,
                actions: actions,
                playlists: SelectionBarState.playlists(sources.playlists, for: container),
                syncProfiles: sources.syncProfiles,
                offlineVolumeName: presentation.offlineVolumeName,
                showsKeyEquivalents: false
            )
        } label: {
            label(state.more, .symbols)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(state.more.help)
        .accessibilityLabel(state.more.title)
    }
}

// MARK: - Surface: glass, or opaque with Reduce Transparency

/// The capsule's surface. Glass on the capsule only (UC-GLASS-05); with Reduce Transparency an
/// opaque `windowBackgroundColor` capsule with a separator stroke (UC-GLASS-14).
private struct SelectionBarSurface: ViewModifier {
    static let glassID = "selection-bar"

    let glassNamespace: Namespace.ID
    let reduceMotion: Bool
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: .capsule)
                .overlay(Capsule().strokeBorder(.separator))
        } else {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID(Self.glassID, in: glassNamespace)
                // Reduce Motion: no glass morph — the container's opacity change only.
                .glassEffectTransition(reduceMotion ? .identity : .materialize)
        }
    }
}
