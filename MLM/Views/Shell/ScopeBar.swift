import SwiftUI

// MARK: - Scope bar (UC-SCOPE-01…05, DEC-011)

/// One scope of a scope bar: its glossary word (UC-SCOPE-02, verbatim) and its live count.
struct ScopeBarItem<ID: Hashable>: Identifiable {
    let id: ID
    /// The scope word, sentence case (`Not downloaded`), never with the count in it.
    let title: String
    /// Live count from a SQL aggregate (UC-TABLE-21); `nil` = not known yet (first load) —
    /// the scope shows its word only.
    var count: Int?
    /// Shown only while something is in it (Playlist detail `Download failed`, UC-SCOPE-02).
    /// A hidden scope comes back while it is the chosen one, so the bar never loses the
    /// selection. All Tracks shows all five scopes always, zero included.
    var hidesWhenEmpty = false
}

/// The noun of a scope bar's counts for VoiceOver (`Download failed, 12 tracks`).
struct ScopeCountNoun: Equatable, Sendable {
    let singular: String
    let plural: String

    static let tracks = ScopeCountNoun(singular: "track", plural: "tracks")
    static let playlists = ScopeCountNoun(singular: "playlist", plural: "playlists")
    static let albums = ScopeCountNoun(singular: "album", plural: "albums")
    static let items = ScopeCountNoun(singular: "item", plural: "items")
}

/// The scope bar's rules — pure, unit-tested (`ScopeBarRulesTests`).
enum ScopeBarRules {
    /// The scopes on screen: every item, minus empty `hidesWhenEmpty` ones that aren't chosen.
    static func visibleItems<ID: Hashable>(_ items: [ScopeBarItem<ID>], selection: ID) -> [ScopeBarItem<ID>] {
        items.filter { item in
            !(item.hidesWhenEmpty && (item.count ?? 0) == 0) || item.id == selection
        }
    }

    /// The scope to show as chosen: `selection` when it exists, else the first item (a stored
    /// scope that no longer exists, UC-SCOPE-05).
    static func resolvedSelection<ID: Hashable>(_ selection: ID, in items: [ScopeBarItem<ID>]) -> ID? {
        items.contains { $0.id == selection } ? selection : items.first?.id
    }

    /// `12,935` — locale thousands separators (UC-COPY-09); `nil` while unknown.
    static func countText(_ count: Int?) -> String? {
        count.map { $0.formatted(.number) }
    }

    /// VoiceOver label: the word and the count with its noun — `Download failed, 1,204 tracks`
    /// (UC-A11Y-02/04); the word alone while the count is unknown.
    static func accessibilityLabel(title: String, count: Int?, noun: ScopeCountNoun) -> String {
        guard let count else { return title }
        return "\(title), \(count.formatted(.number)) \(count == 1 ? noun.singular : noun.plural)"
    }
}

/// A view's scope bar: filters the view in place (UC-SCOPE-01). Native recessed scope buttons
/// (the Finder / Mail scope bar: `.toggleStyle(.button)` in `.buttonStyle(.accessoryBar)`), each
/// with its word and its live count in `.tertiary`; an optional trailing accessory (search
/// tokens, W2-I). Opaque content chrome under the banner slot — never glass (UC-GLASS-07).
///
/// **Adopting it** (album grid, All Playlists, Review, Discover, playlist detail):
/// ```swift
/// @SceneStorage("albums.scope") private var scope = AlbumScope.all.rawValue  // UC-SCOPE-05
///
/// ContentScaffold(showsDriveBanner: false) {
///     AlbumGrid(…)
/// } scopeBar: {
///     ScopeBar(
///         items: AlbumScope.allCases.map { ScopeBarItem(id: $0, title: $0.title, count: counts[$0]) },
///         selection: Binding(get: { AlbumScope(rawValue: scope) ?? .all }, set: { scope = $0.rawValue }),
///         countNoun: .albums
///     )
/// }
/// ```
/// The bar publishes View ▸ Filter for its view (`FocusedValues.viewScopeMenu`, UC-SCOPE-03)
/// while `publishesMenu` is true — set it to false while the view is hidden but kept alive.
/// Keyboard: every scope is a button (Tab with Full Keyboard Access), and View ▸ Filter
/// lists them; no scope has a key equivalent (UC-KEY-39).
struct ScopeBar<ID: Hashable, Accessory: View>: View {
    let items: [ScopeBarItem<ID>]
    @Binding var selection: ID
    var countNoun: ScopeCountNoun = .items
    /// VoiceOver name of the group.
    var label = "Filter"
    /// Publish this bar's scopes as View ▸ Filter.
    var publishesMenu = true
    let accessory: Accessory

    init(
        items: [ScopeBarItem<ID>],
        selection: Binding<ID>,
        countNoun: ScopeCountNoun = .items,
        label: String = "Filter",
        publishesMenu: Bool = true,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.items = items
        self._selection = selection
        self.countNoun = countNoun
        self.label = label
        self.publishesMenu = publishesMenu
        self.accessory = accessory()
    }

    var body: some View {
        let chosen = ScopeBarRules.resolvedSelection(selection, in: items)
        let visible = ScopeBarRules.visibleItems(items, selection: chosen ?? selection)
        HStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.xxs) {
                ForEach(visible) { item in
                    scopeButton(item, isOn: item.id == chosen)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            Spacer(minLength: Spacing.s)
            accessory
        }
        .toggleStyle(.button)
        .buttonStyle(.accessoryBar)
        .controlSize(.regular)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
        .focusedSceneValue(\.viewScopeMenu, publishesMenu ? menu(visible, chosen: chosen) : nil)
    }

    private func scopeButton(_ item: ScopeBarItem<ID>, isOn: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { isOn },
            // Choosing the chosen scope again keeps it: one scope is always chosen.
            set: { if $0 { selection = item.id } }
        )) {
            HStack(spacing: Spacing.xxs) {
                Text(item.title)
                if let count = ScopeBarRules.countText(item.count) {
                    Text(count)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
        }
        .fixedSize()
        .accessibilityLabel(ScopeBarRules.accessibilityLabel(title: item.title, count: item.count, noun: countNoun))
    }

    private func menu(_ visible: [ScopeBarItem<ID>], chosen: ID?) -> ViewScopeMenu {
        let binding = $selection
        return ViewScopeMenu(
            items: visible.map { ViewScopeMenu.Item(id: AnyHashable($0.id), title: $0.title) },
            selectedID: chosen.map { AnyHashable($0) },
            select: { id in
                if let typed = id.base as? ID { binding.wrappedValue = typed }
            }
        )
    }
}

extension ScopeBar where Accessory == EmptyView {
    init(
        items: [ScopeBarItem<ID>],
        selection: Binding<ID>,
        countNoun: ScopeCountNoun = .items,
        label: String = "Filter",
        publishesMenu: Bool = true
    ) {
        self.init(items: items, selection: selection, countNoun: countNoun, label: label,
                  publishesMenu: publishesMenu) { EmptyView() }
    }
}

// MARK: - View ▸ Filter (UC-SCOPE-03, M-VIEW.N06)

/// The scopes of the view on screen, as View ▸ Filter lists them: the same words, the
/// current one checked. Published by `ScopeBar` (scene-wide, so the menu works whether the
/// table or the bar has focus); any view with a `ScopeBar` gets the menu for free.
struct ViewScopeMenu {
    struct Item: Identifiable {
        let id: AnyHashable
        let title: String
    }

    let items: [Item]
    let selectedID: AnyHashable?
    let select: @MainActor (AnyHashable) -> Void
}

extension FocusedValues {
    /// The visible view's scopes (View ▸ Filter). Published with `.focusedSceneValue` by
    /// `ScopeBar`.
    @Entry var viewScopeMenu: ViewScopeMenu?
}
