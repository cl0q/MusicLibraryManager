import SwiftUI

/// Discover ▸ Recommendations (V-INBOX, DEC-029): the downloaded recommendations held until they
/// are kept or dismissed, one shared track table per seed group (`Because of “‹track›”` with
/// `Keep All` / `Dismiss All`). First load shows placeholder rows only; verdicts and finished
/// downloads update in place (V-INBOX.E04); a failed load is never shown as empty (V-INBOX.N05).
struct RecommendationsView: View {
    let model: DiscoverModel
    let onTrackActivated: TrackActivation

    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?
    @State private var showsLoadDetails = false
    @State private var placeholder = TrackListModel()

    var body: some View {
        if let error = model.loadError, model.groups.isEmpty {
            ContentUnavailableView {
                Label("Can’t load the recommendations", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The library database didn’t answer. The recommendations you downloaded are still on the drive; nothing was kept or dismissed.")
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
                Button("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }
                DisclosureGroup("Details", isExpanded: $showsLoadDetails) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: 360, alignment: .leading)
                }
                .frame(maxWidth: 360)
            }
        } else if !model.isLoaded {
            // First load: placeholder rows only (UC-TABLE-09) — the table draws them while unloaded.
            TrackListTable(model: placeholder, configuration: RecommendationsConfiguration.placeholder()) { EmptyView() }
        } else if model.isEmpty {
            ContentUnavailableView {
                Label("No recommendations waiting", systemImage: "sparkles")
            } description: {
                Text("Pick a track you like and MLM looks for similar ones on SoundCloud or Last.fm. What it downloads waits here until you keep or dismiss it.")
            } actions: {
                Button("Find Recommendations") { NotificationCenter.default.post(name: .discoverFindRecommendations, object: nil) }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.hasNoMatches {
            ContentUnavailableView {
                Label("No results", systemImage: "magnifyingglass")
            } description: {
                Text("No recommendation matches the search.")
            } actions: {
                Button("Clear Filters") { search?.clear() }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.l, pinnedViews: []) {
                    ForEach(model.visibleGroups) { group in
                        RecommendationGroupSection(group: group, model: model, onTrackActivated: onTrackActivated)
                    }
                }
                .padding(.vertical, Spacing.m)
                .padding(.bottom, Spacing.xl * 3)
            }
        }
    }
}

extension Notification.Name {
    /// The empty state's `Find Recommendations…` asks the page to run the search (the page owns the
    /// selection it seeds from).
    static let discoverFindRecommendations = Notification.Name("MLMDiscoverFindRecommendations")
}

// MARK: - One seed group

/// The group header (`Because of “‹track›”` · `Keep All` · `Dismiss All`) and the group's rows as
/// the shared track table.
struct RecommendationGroupSection: View {
    let group: RecommendationGroup
    let model: DiscoverModel
    let onTrackActivated: TrackActivation

    @State private var list = TrackListModel(sortOrder: nil)
    @State private var context = RecommendationRowContext()
    @Environment(\.container) private var container
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?

    private static let headerHeight: CGFloat = 30
    private static let rowHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Text(group.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(group.items.count.formatted(.number))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer(minLength: Spacing.s)
                Button("Keep All") { Task { await model.keepAll(in: group) } }
                    .controlSize(.small)
                Button("Dismiss All") { Task { await model.dismissAll(in: group) } }
                    .controlSize(.small)
                    .disabled(model.dismissRefusal != nil)
                    .help(model.dismissRefusal ?? "")
            }
            .padding(.horizontal, Spacing.l)
            TrackListTable(model: list, configuration: configuration) { EmptyView() }
                .environment(\.recommendationRowContext, context)
                .frame(height: Self.headerHeight + Self.rowHeight * CGFloat(group.items.count) + 4)
        }
        .task(id: signature) {
            context.sources = Dictionary(uniqueKeysWithValues: group.items.map { ($0.id, DiscoverModel.sourceWord($0.source)) })
            await list.setTracks(group.items.map(\.track),
                                 context: TrackRowBuildContext(matchPercents: model.matches.filter { id, _ in group.items.contains { $0.id == id } }))
        }
    }

    /// Reload the rows when the group's members, their analysis or their match change.
    private var signature: [Int64] {
        group.items.flatMap { [$0.id, $0.isAnalysed ? 1 : 0, Int64(model.matches[$0.id] ?? -1)] }
    }

    private var configuration: TrackListConfiguration {
        var configuration = TrackListConfiguration(
            listContext: TrackListContext(container: .recommendations, viewName: nil),
            persistenceKey: "recommendations",
            columns: [.title, .artist, .source, .match, .time, .energy],
            defaultSort: nil,
            isSortable: false,
            publishesStatusText: false,
            accessibilityID: "recommendations_table",
            activate: onTrackActivated)
        configuration.canAddToSyncProfile = false
        configuration.showsAnalysingEnergy = true
        // ⌫ dismisses (UC-KEY-17), K keeps (UC-KEY-29).
        configuration.removeFromContainer = { ids in Task { await model.dismiss(Array(ids)) } }
        configuration.characterKeys = ["k": { rows in Task { await model.keep(rows.map(\.id)) } }]
        configuration.menuExtras = TrackMenuExtrasProvider(
            items: { rows in
                var extras = TrackMenuExtras(
                    addTo: [TrackMenuExtra(id: Self.keepID, title: "Keep")],
                    remove: [TrackMenuExtra(id: Self.dismissID, title: "Dismiss", isEnabled: model.dismissRefusal == nil)])
                if rows.count == 1, let seed = model.item(for: rows[0].id)?.seedTrackID, seed > 0 {
                    extras.info = [TrackMenuExtra(id: Self.seedID, title: "Go to Seed Track")]
                }
                return extras
            },
            perform: { id, rows in perform(id, rows) })
        return configuration
    }

    private static let keepID = "keep"
    private static let dismissID = "dismiss"
    private static let seedID = "goToSeed"

    private func perform(_ id: String, _ rows: [TrackRow]) {
        let ids = rows.map(\.id)
        switch id {
        case Self.keepID:
            Task { await model.keep(ids) }
        case Self.dismissID:
            Task { await model.dismiss(ids) }
        case Self.seedID:
            guard rows.count == 1, let seed = model.item(for: rows[0].id)?.seedTrackID, let search else { return }
            SearchReveal.showInAllTracks(seed, search: search, container: container)
        default:
            guard id.hasPrefix("keepAndAdd:") else { return }
            let target = String(id.dropFirst("keepAndAdd:".count))
            if let playlistID = Int64(target) {
                Task { await model.keep(ids, addTo: playlistID) }
            } else {
                // `New Playlist…`: keep, then name a playlist made of them (its own undo step).
                Task {
                    await model.keep(ids)
                    _ = await shell?.edits.newPlaylist(fromTrackIDs: ids)
                }
            }
        }
    }
}

// MARK: - Configuration for the first load

enum RecommendationsConfiguration {
    /// The unloaded table's configuration (placeholder rows, nothing to act on).
    static func placeholder() -> TrackListConfiguration {
        var configuration = TrackListConfiguration(
            listContext: TrackListContext(container: .recommendations, viewName: nil),
            persistenceKey: "recommendations",
            columns: [.title, .artist, .source, .match, .time, .energy],
            defaultSort: nil,
            isSortable: false,
            publishesStatusText: false,
            accessibilityID: "recommendations_placeholder")
        configuration.canAddToSyncProfile = false
        return configuration
    }
}
