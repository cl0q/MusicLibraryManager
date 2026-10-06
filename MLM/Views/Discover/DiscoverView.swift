import SwiftUI

/// **Discover** (V-DISC, DEC-029): `Recommendations · Reels` in a scope bar (the old 260 pt
/// segmented control is gone), one title (the window's), the held recommendations in the shared
/// track table, and — in the Reels scope — the existing inbox until W3-DISC-B replaces it.
/// UC-LAYOUT-01…05, UC-SCOPE-01…05.
struct DiscoverView: View {
    let onTrackActivated: TrackActivation

    @Environment(\.container) private var container
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ShellActions.self) private var shell: ShellActions?

    @State private var model: DiscoverModel?
    @SceneStorage("discover.scope") private var storedScope = DiscoverScope.recommendations.rawValue

    private var scope: DiscoverScope { DiscoverScope(rawValue: storedScope) ?? .recommendations }

    var body: some View {
        ContentScaffold(showsDriveBanner: true) {
            content
        } header: {
            header
        } scopeBar: {
            scopeBar
        } selectionBar: {
            TrackSelectionBar()
        }
        .hostsTrackSelectionBar()
        .modifier(WindowTitleModifier())
        .task { await setUp() }
        .task(id: container.searchCoordinator.filter(for: .discover)) {
            model?.filter = container.searchCoordinator.filter(for: .discover)
        }
        .task(id: LibraryDriveState.current(container)) {
            model?.drive = LibraryDriveState.current(container)
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in Task { await model?.reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidDeleteTracks)) { _ in Task { await model?.reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .discoverFindRecommendations)) { _ in find() }
    }

    private func setUp() async {
        if model == nil, let dependencies = DiscoverLive.dependencies(container, shell: shell) {
            let created = DiscoverModel(dependencies: dependencies)
            created.filter = container.searchCoordinator.filter(for: .discover)
            created.drive = LibraryDriveState.current(container)
            model = created
        }
        guard let model else { return }
        model.statusBar = statusBar
        model.undo = undo
        await model.reload()
    }

    // MARK: Scope bar (V-DISC.E02)

    private var scopeBar: some View {
        let items = DiscoverScope.allCases.map { scope in
            ScopeBarItem(id: scope, title: scope.title, count: model?.count(for: scope))
        }
        return ScopeBar(
            items: items,
            selection: Binding(get: { scope }, set: { storedScope = $0.rawValue }),
            countNoun: .items
        ) { EmptyView() }
    }

    // MARK: Header (V-INBOX.E02, N01, N02)

    @ViewBuilder
    private var header: some View {
        if scope == .recommendations, let model {
            VStack(spacing: 0) {
                if model.drive.isOffline, let name = model.drive.volumeName {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "externaldrive.badge.xmark")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("You can keep recommendations, but not preview them. \(Text("Dismiss is unavailable").fontWeight(.semibold)) because the files can’t be moved to the Trash while “\(name)” is not connected.")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    .background(.quaternary)
                    .overlay(alignment: .bottom) { Divider() }
                    .accessibilityElement(children: .combine)
                }
                HStack(spacing: Spacing.m) {
                    if model.isLoaded, model.loadError == nil {
                        Text(DiscoverModel.headerLine(model.waitingCount))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    Spacer(minLength: Spacing.s)
                    Text("Space Preview · K Keep · ⌫ Dismiss · ⌘Z Undo")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Button("Find Recommendations…") { find() }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.xs)
                .background(.background)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch scope {
        case .recommendations:
            if let model {
                RecommendationsView(model: model, onTrackActivated: onTrackActivated)
            } else {
                Color.clear
            }
        case .reels:
            ReelsInboxView()
        }
    }

    // MARK: Find Recommendations… (IMP-056)

    /// Seed = the selected recommendation's seed, else the playing track. Nothing navigates.
    private func find() {
        guard let model else { return }
        let selection = InspectedTrackSelection.shared
        let selected: Set<Int64> = selection.sourceKey == "recommendations" ? Set(selection.trackIDs) : []
        Task { await model.findRecommendations(selected: selected) }
    }
}
