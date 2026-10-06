import SwiftUI

/// **Review ▸ Albums** (V-REV.N05–N11, DEC-021, DEC-044, UC-KEY-30): tracks without an album, the
/// suggestions the lookup found, and the decision per row — `Accept` (↩), `Reject` (⌫),
/// `No Album`. Choosing another album swaps the row's suggestion; nothing is written until
/// Accept. The lookup is an Activity operation (`Look Up Albums`); every decision is one undo
/// step with a status-bar confirmation, only the bulk Accept asks first (A-REV-ALBBULK,
/// UC-UNDO-05). Space previews the selected track (never Play/Pause, THOUGHTS §10).
struct ReviewAlbumsView: View {
    let model: ReviewAlbumsModel
    let onTrackActivated: TrackActivation

    @Environment(\.container) private var container
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?

    @State private var selection: Set<Int64> = []
    @State private var showsBulk = false

    private static let previewOwner = "review.albums"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .statusBarText(model.isLoaded ? model.statusText(rows: model.visibleItems.count) : nil)
        .alert(ReviewAlbumsModel.bulkTitle(model.bulkItems.count), isPresented: $showsBulk) {
            Button(ReviewAlbumsModel.bulkButton(model.bulkItems.count)) { acceptAllAbove() }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(model.bulkMessage)
        }
        .onDisappear { endPreview() }
    }

    // MARK: Header (V-REV.N05–N08)

    private var header: some View {
        HStack(spacing: Spacing.m) {
            if let operation = activeLookup {
                ProgressView().controlSize(.small)
                Text(lookupText(operation))
                    .monospacedDigit()
                if let fraction = operation.progress.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 140)
                }
                Button("Show in Activity") { ActivityRouter.shared.showPopover() }
                    .buttonStyle(.link)
                Button("Cancel Lookup") { model.lookup.cancel() }
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.headerLine).monospacedDigit()
                    if let last = model.lookup.lastLookup {
                        Text(last.sentence).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            Picker("Show", selection: Binding(get: { model.filter }, set: { filter in Task { await model.setFilter(filter) } })) {
                ForEach(AlbumSuggestionFilter.allCases) { filter in
                    Text(filterTitle(filter)).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Show")
            Button("Look Up Albums") { model.lookup.startWithConfirmation(statusBar: statusBar) }
                .disabled(model.lookup.blockedReason != nil)
                .help(model.lookup.blockedReason ?? "Look for the album of every track that has none")
            Button(model.bulkButtonTitle) { showsBulk = true }
                .disabled(model.bulkItems.isEmpty || undo == nil)
                .help(model.bulkItems.isEmpty ? "No suggestion has a match above 90 %" : "Accept every suggestion with a match above 90 %")
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(.background)
    }

    private func filterTitle(_ filter: AlbumSuggestionFilter) -> String {
        "\(filter.title) \(model.counts.count(for: filter).formatted(.number))"
    }

    private var activeLookup: ActivityOperation? {
        guard model.lookup.isActive else { return nil }
        return ActivityCenter.shared.activeOperations.first { $0.kind == .albumLookup }
    }

    /// `Looking up albums · 2,410 of 6,341`.
    private func lookupText(_ operation: ActivityOperation) -> String {
        if operation.state == .queued, let wait = operation.wait { return wait.sentence }
        return ["Looking up albums", ActivityPresentation.progressText(operation.progress)].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let rows = model.visibleItems
        if !model.isLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            empty
        } else if rows.isEmpty {
            ContentUnavailableView {
                Label("No results", systemImage: "magnifyingglass")
            } description: {
                Text("No album suggestion matches the search.")
            } actions: {
                Button("Clear Filters") { search?.clear() }
            }
        } else {
            table(rows)
        }
    }

    /// V-REV.N10: never looked up vs clean, and the other two filters in their own words.
    @ViewBuilder
    private var empty: some View {
        switch model.filter {
        case .suggestions where !model.hasLookedUp:
            ContentUnavailableView {
                Label("No album suggestions yet", systemImage: "square.stack")
            } description: {
                Text("Look Up Albums asks about every track that has no album.")
            } actions: {
                Button("Look Up Albums") { model.lookup.startWithConfirmation(statusBar: statusBar) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.lookup.blockedReason != nil)
            }
        case .suggestions:
            ContentUnavailableView {
                Label("Every track has an album or a decision", systemImage: "checkmark.circle")
            } description: {
                Text("New suggestions appear while a lookup runs.")
            }
        case .noMatch:
            ContentUnavailableView {
                Label("Every track got a suggestion", systemImage: "checkmark.circle")
            }
        case .noAlbum:
            ContentUnavailableView {
                Label("No tracks confirmed as “No album”", systemImage: "square.stack")
            } description: {
                Text("Tracks you mark No Album, like a mix or a live set, stop counting as tracks without an album.")
            }
        }
    }

    // MARK: Table (V-REV.N09)

    private func table(_ rows: [AlbumSuggestionItem]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Track") { item in
                HStack(spacing: Spacing.s) {
                    TrackCoverView(trackId: item.id, size: .small, cornerRadius: 4)
                        .frame(width: 28, height: 28)
                    Text(item.track.title).lineLimit(1)
                }
            }
            .width(min: 160, ideal: 240)
            TableColumn("Artist") { item in
                Text(item.track.artist).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Suggested album") { item in
                suggestionCell(item)
            }
            .width(min: 180, ideal: 260)
            TableColumn("Source") { item in
                Text(item.row.hasSuggestion && item.row.status == .pending ? item.row.suggestion.source : "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 100, max: 130)
            TableColumn("Match") { item in
                Text(item.row.hasSuggestion && item.row.status == .pending ? "\(item.row.suggestion.matchPercent) %" : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 60, max: 70)
            TableColumn("Other") { item in
                alternativesMenu(item)
            }
            .width(min: 80, ideal: 96, max: 120)
            TableColumn("") { item in
                rowButtons(item)
            }
            .width(min: 150, ideal: 220, max: 250)
        }
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: Int64.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            showSuggestedAlbum(ids)
        }
        .onKeyPress(.return) {
            guard filter == .suggestions, !selection.isEmpty else { return .ignored }
            accept(selection)
            return .handled
        }
        .onDeleteCommand {
            guard filter == .suggestions, !selection.isEmpty else { return }
            reject(selection)
        }
        // Space on the focused table previews the selected track (never Play/Pause).
        .onKeyPress(.space) {
            guard let item = single(selection) else { return .ignored }
            preview(item)
            return .handled
        }
        .accessibilityIdentifier("review_albums")
    }

    private var filter: AlbumSuggestionFilter { model.filter }

    @ViewBuilder
    private func suggestionCell(_ item: AlbumSuggestionItem) -> some View {
        switch item.row.status {
        case .pending where item.row.hasSuggestion:
            let suggestion = item.row.suggestion
            HStack(spacing: Spacing.xs) {
                Text(suggestion.albumTitle).lineLimit(1)
                if let year = suggestion.year {
                    Text("· \(String(year))").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ReviewAlbumsModel.suggestionLine(suggestion))
        case .noAlbum:
            Text("No album — confirmed").foregroundStyle(.secondary)
        default:
            Text("No match found").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func alternativesMenu(_ item: AlbumSuggestionItem) -> some View {
        let others = item.row.alternatives
        if item.row.status == .pending, !others.isEmpty {
            Menu(others.count == 1 ? "1 more" : "\(others.count) more") {
                Section("Other suggestions") {
                    ForEach(Array(others.enumerated()), id: \.offset) { index, other in
                        Button(ReviewAlbumsModel.alternativeLine(other)) { choose(index, for: item.id) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Other suggestions")
        }
    }

    @ViewBuilder
    private func rowButtons(_ item: AlbumSuggestionItem) -> some View {
        HStack(spacing: Spacing.xs) {
            Spacer(minLength: 0)
            switch item.row.status {
            case .pending where item.row.hasSuggestion:
                Button("Accept") { accept([item.id]) }
                    .buttonStyle(.borderedProminent)
                Button("Reject") { reject([item.id]) }
                Button("No Album") { markNoAlbum([item.id]) }
            case .noAlbum:
                Button("Suggest Again") { suggestAgain([item.id]) }
            default:
                Button("No Album") { markNoAlbum([item.id]) }
            }
        }
        .controlSize(.small)
    }

    // MARK: Context menu (CM-REV-ALBUM)

    @ViewBuilder
    private func menu(for ids: Set<Int64>) -> some View {
        if let item = single(ids) {
            let reachable = item.track.availability() == .local && !model.drive.isOffline
            let driveReason = model.drive.volumeName.map { "“\($0)” is not connected" }
            let pending = item.row.status == .pending && item.row.hasSuggestion
            Section {
                Button { play(item) } label: { Label("Play", systemImage: "play.fill") }
                    .disabled(!reachable)
                    .help(reachable ? "" : (driveReason ?? "The file is not available"))
                Button("Preview") { preview(item) }
                    .disabled(!reachable)
                    .help(reachable ? "" : (driveReason ?? "The file is not available"))
            }
            Section {
                Button("Get Info") { NotificationCenter.default.post(name: .openTrackDetailForTrack, object: nil, userInfo: ["trackId": item.id]) }
                    .keyboardShortcut("i", modifiers: .command)
                let album = model.existingAlbums[item.id]
                Button("Show Suggested Album") { if let album { navigation?.push(.album(album)) } }
                    .disabled(album == nil || navigation == nil)
                    .help(album == nil ? (pending ? "This album is not in the library yet" : "There is no suggested album") : "")
            }
            Section {
                Button("Accept") { accept([item.id]) }
                    .disabled(!pending)
                Menu("Choose Another Album…") {
                    ForEach(Array(item.row.alternatives.enumerated()), id: \.offset) { index, other in
                        Button(ReviewAlbumsModel.alternativeLine(other)) { choose(index, for: item.id) }
                    }
                }
                .disabled(!(item.row.status == .pending && !item.row.alternatives.isEmpty))
                Button("No Album") { markNoAlbum([item.id]) }
                    .disabled(item.row.status == .noAlbum)
                Button("Reject") { reject([item.id]) }
                    .disabled(!pending)
            }
            Section {
                Button("Show in Finder") { TrackCommandActions.showInFinder([item.track], container: container) }
                    .disabled(!reachable)
                    .help(reachable ? "" : (driveReason ?? "The file is not available"))
                Menu("Copy") {
                    Button("Title — Artist") { TrackCommandActions.copyTitleAndArtist([item.track]) }
                }
            }
        } else if ids.count > 1 {
            let chosen = model.items.filter { ids.contains($0.id) }
            let acceptable = AlbumSuggestionDecisions.acceptable(chosen)
            Button("Accept") { accept(ids) }.disabled(acceptable.isEmpty)
            Button("No Album") { markNoAlbum(ids) }
            Button("Reject") { reject(ids) }.disabled(acceptable.isEmpty)
        }
    }

    // MARK: Actions

    private func single(_ ids: Set<Int64>) -> AlbumSuggestionItem? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return model.item(withID: id)
    }

    private func accept(_ ids: Set<Int64>) {
        guard let undo else { return }
        Task { await model.accept(ids, undo: undo); pruneSelection() }
    }

    private func acceptAllAbove() {
        guard let undo else { return }
        Task { await model.acceptAllAbove(undo: undo); pruneSelection() }
    }

    private func reject(_ ids: Set<Int64>) {
        guard let undo else { return }
        Task { await model.reject(ids, undo: undo); pruneSelection() }
    }

    private func markNoAlbum(_ ids: Set<Int64>) {
        guard let undo else { return }
        Task { await model.markNoAlbum(ids, undo: undo); pruneSelection() }
    }

    private func suggestAgain(_ ids: Set<Int64>) {
        guard let undo else { return }
        Task { await model.suggestAgain(ids, undo: undo); pruneSelection() }
    }

    private func choose(_ index: Int, for id: Int64) {
        Task { await model.choose(alternativeAt: index, for: id) }
    }

    /// A decided row leaves the list; the selection keeps only rows that are still shown.
    private func pruneSelection() {
        let shown = Set(model.items.map(\.id))
        selection = selection.intersection(shown)
    }

    private func showSuggestedAlbum(_ ids: Set<Int64>) {
        guard let item = single(ids), let album = model.existingAlbums[item.id] else { return }
        navigation?.push(.album(album))
    }

    private func play(_ item: AlbumSuggestionItem) {
        endPreview()
        onTrackActivated(item.track, [item.track])
    }

    private func preview(_ item: AlbumSuggestionItem) {
        guard let row = TrackRowBuilder.build([item.track]).first else { return }
        container.playbackViewModel?.preview.toggle(owner: Self.previewOwner, candidate: PreviewCandidate.make(rows: [row], live: .idle))
    }

    private func endPreview() {
        guard let preview = container.playbackViewModel?.preview, preview.owner == Self.previewOwner else { return }
        preview.ownerGone(Self.previewOwner)
    }
}
