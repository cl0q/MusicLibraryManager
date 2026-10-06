import SwiftUI

/// **Similar to “‹track›”** (V-SIMILAR, DEC-030): a pushed view — the 1040 pt sheet is gone — with
/// the library tracks that sound like the seed in the shared track table (selection, Space
/// preview, menu, drag) and the suggestions SoundCloud or Last.fm have for it. Nothing in it can
/// remove a track from the library (V-SIMILAR.N07, PP-INSPECTOR-21): suggestions are `Download`ed
/// (held in Discover ▸ Recommendations until kept) or `Keep`-ed (straight into the library).
/// Back (⌘[) returns to where it came from; opening it never moves anything else (P3).
struct SimilarView: View {
    let trackID: Int64
    let onTrackActivated: TrackActivation

    @Environment(\.container) private var container
    @Environment(\.openSettings) private var openSettings
    @Environment(NavigationModel.self) private var navigation: NavigationModel?
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ShellActions.self) private var shell: ShellActions?

    @State private var model: SimilarModel?
    @State private var list = TrackListModel(sortOrder: nil)

    private var analysis: InspectorAnalysis { InspectorAnalysis.shared }

    var body: some View {
        ContentScaffold(showsDriveBanner: true) {
            content
        } selectionBar: {
            TrackSelectionBar()
        }
        .hostsTrackSelectionBar()
        .navigationTitle(model?.seed.map { "Similar to “\($0.title)”" } ?? "Similar")
        .task(id: trackID) { await setUp() }
        .task(id: LibraryDriveState.current(container)) { model?.drive = LibraryDriveState.current(container) }
        // The analysis the seed was waiting for finished: the matches appear.
        .task(id: analysis.isRunning(trackID)) {
            if !analysis.isRunning(trackID), model?.seedState == .notAnalysed { await model?.refresh() }
        }
        .onChange(of: container.downloadViewModel?.discoveryStatuses) { _, _ in
            Task { await model?.refreshPlacements() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in
            Task { await model?.refreshPlacements() }
        }
    }

    private func setUp() async {
        if model == nil, let dependencies = DiscoverLive.similarDependencies(container, shell: shell) {
            let created = SimilarModel(trackID: trackID, dependencies: dependencies)
            created.drive = LibraryDriveState.current(container)
            model = created
        }
        model?.undo = undo
        await model?.load()
        await list.setTracks(model?.inLibrary ?? [], context: TrackRowBuildContext(matchPercents: model?.matches ?? [:]))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let model {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    seedHeader(model)
                    librarySection(model)
                    onlineSection(model)
                    Label(SimilarModel.noDeleteNote, systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(Spacing.l)
                .padding(.bottom, Spacing.xl * 3)
            }
            .onChange(of: model.inLibrary) { _, tracks in
                Task { await list.setTracks(tracks, context: TrackRowBuildContext(matchPercents: model.matches)) }
            }
        } else {
            Color.clear
        }
    }

    // MARK: Seed header (S-GROOVE-SIMILAR.E01)

    private func seedHeader(_ model: SimilarModel) -> some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            if let seed = model.seed, let id = seed.id {
                Group {
                    if seed.availability().hasFile {
                        TrackCoverView(trackId: id, size: .small, cornerRadius: 6)
                    } else {
                        TrackPlaceholderArtwork()
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Similar to")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(model.seed?.title ?? "—")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(Self.seedLine(model.seed))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            // The user's own click: this one navigates by design.
            Button("Show Recommendations") { navigation?.select(.discover) }
        }
    }

    /// `Bicep · 6:41 · 124 BPM · Energy 4`.
    static func seedLine(_ seed: Track?) -> String {
        guard let seed else { return "" }
        var parts: [String] = []
        if let artist = TrackMetadataPresentation.artistDisplay(seed.artist) { parts.append(artist) }
        if let time = TrackDurationText.trackTime(seed.duration) { parts.append(time) }
        if let bpm = seed.bpm, bpm > 0 { parts.append("\(bpm) BPM") }
        if let energy = seed.energyBucket, (1...5).contains(energy) { parts.append("Energy \(energy)") }
        return parts.joined(separator: " · ")
    }

    // MARK: In library (S-GROOVE-SIMILAR.E02, V-SIMILAR.N02)

    @ViewBuilder
    private func librarySection(_ model: SimilarModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("In library").font(.headline)
                if model.seedState == .ready, !model.inLibrary.isEmpty {
                    Text("Top \(model.inLibrary.count) by sound")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            switch model.seedState {
            case .loading:
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Looking for similar tracks…").foregroundStyle(.secondary)
                }
            case .missing:
                Text("This track is no longer in the library.").foregroundStyle(.secondary)
            case .notAnalysed:
                notAnalysed(model)
            case .ready:
                if model.inLibrary.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(SimilarModel.noSimilarHeadline).fontWeight(.semibold)
                        Text("The more tracks are analysed, the better the matches.").foregroundStyle(.secondary)
                        Button("Open Settings ▸ Maintenance") { openSettings(tab: .maintenance) }
                    }
                } else {
                    TrackListTable(model: list, configuration: configuration) { EmptyView() }
                        .frame(height: 30 + 26 * CGFloat(model.inLibrary.count) + 4)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
                }
            }
        }
    }

    private func notAnalysed(_ model: SimilarModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if analysis.isRunning(trackID) {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing “\(model.seed?.title ?? "")”…").fontWeight(.semibold)
                }
                Text("Also shown in Activity. Results appear here when it finishes.").foregroundStyle(.secondary)
            } else {
                Text(SimilarModel.notAnalysedHeadline).fontWeight(.semibold)
                Text(SimilarModel.analyseSentence(model.seed?.title ?? "")).foregroundStyle(.secondary)
                let refusal = model.analyseRefusal
                Button("Analyse This Track") { Task { await model.analyseSeed() } }
                    .disabled(refusal != nil)
                    .help(refusal ?? "")
                if let refusal { Text(refusal).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
    }

    private var configuration: TrackListConfiguration {
        TrackListConfiguration(
            listContext: TrackListContext(container: .similar(trackID: trackID), viewName: nil),
            persistenceKey: "similar",
            columns: [.title, .artist, .album, .time, .bpm, .energy, .match],
            defaultSort: TrackSortOrder(column: .match, ascending: false),
            publishesStatusText: false,
            accessibilityID: "similar_table",
            activate: onTrackActivated)
    }

    // MARK: Online (S-GROOVE-SIMILAR.E03/E04, V-SIMILAR.N03…N06)

    private func onlineSection(_ model: SimilarModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                Text("Online").font(.headline)
                Picker("Source", selection: Binding(get: { model.source }, set: { model.setSource($0) })) {
                    Text("SoundCloud").tag(SwarmRecommendationService.SwarmSource.soundcloud)
                    Text("Last.fm").tag(SwarmRecommendationService.SwarmSource.lastfm)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if model.onlineState == .results {
                    Text(model.onlineRows.count == 1 ? "1 suggestion" : "\(model.onlineRows.count) suggestions")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.s)
                Button("Refresh") { Task { await model.refresh() } }
                    .help("Read both sections again")
            }
            switch model.onlineState {
            case .idle:
                EmptyView()
            case .loading:
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text(SimilarModel.onlineLoadingLine(model.source, model.seed?.title ?? ""))
                        .foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelOnline() }
                        .buttonStyle(.link)
                }
            case .empty:
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("No suggestions found").fontWeight(.semibold)
                    Text(SimilarModel.noSuggestionsLine(model.source, model.seed?.title ?? ""))
                        .foregroundStyle(.secondary)
                }
            case .failed(let failure):
                failureView(failure, model: model)
            case .results:
                VStack(spacing: 0) {
                    ForEach(model.onlineRows) { row in
                        onlineRow(row, model: model)
                        Divider()
                    }
                }
                Button("Load More") { model.loadMore() }
            }
        }
    }

    private func failureView(_ failure: SimilarModel.OnlineFailure, model: SimilarModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(failure.headline, systemImage: failure.kind == .noSource ? "gearshape" : "exclamationmark.triangle")
                .fontWeight(.semibold)
            Text(failure.details).foregroundStyle(.secondary)
            HStack {
                switch failure.kind {
                case .noSource:
                    Button("Open Settings ▸ Sources") { openSettings(tab: .sources) }
                case .offline:
                    Button("Try Again") { model.refreshOnline() }
                case .noAnswer:
                    Button("Try Again") { model.refreshOnline() }
                    Button("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }
                }
            }
        }
    }

    private func onlineRow(_ row: SimilarModel.OnlineRow, model: SimilarModel) -> some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 0) {
                Text(row.recommendation.title).lineLimit(1)
                Text(TrackMetadataPresentation.artistDisplay(row.recommendation.artist) ?? "—")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            HStack(spacing: Spacing.xs) {
                let word = DiscoverModel.sourceWord(row.recommendation.source)
                SourceBrandDot(source: word)
                Text(word).foregroundStyle(.secondary)
            }
            rowState(row, model: model)
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .onAppear { TrackMenuSources.shared.loadIfNeeded() }
        .contextMenu {
            StreamPreviewMenuItem(link: row.recommendation.scDownloadUrl, title: row.recommendation.title, rowID: row.id)
            Button("Download") { model.download(row) }
                .disabled(row.isBusy || row.isPlaced)
            Button("Keep") { model.keep(row) }
                .disabled(row.isBusy || row.isPlaced)
            Menu("Keep and Add to Playlist") {
                AddToPlaylistMenuItems(
                    playlists: TrackMenuSources.shared.playlists,
                    showsKeyEquivalents: false,
                    newPlaylist: { model.keep(row, addingTo: .new) },
                    add: { id in model.keep(row, addingTo: .existing(id)) })
            }
            .disabled(row.isBusy || row.isPlaced)
            if let link = row.recommendation.scDownloadUrl, let url = URL(string: link) {
                Divider()
                Button("Open on \(DiscoverModel.sourceWord(row.recommendation.source))") { NSWorkspace.shared.open(url) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
            }
        }
    }

    @ViewBuilder
    private func rowState(_ row: SimilarModel.OnlineRow, model: SimilarModel) -> some View {
        if row.isBusy {
            HStack(spacing: Spacing.xxs) {
                if row.pipeline == .downloading { ProgressView().controlSize(.small) }
                Text(row.stateWord ?? "").foregroundStyle(.secondary)
            }
        } else if row.isPlaced {
            Label(row.stateWord ?? "", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        } else {
            HStack(spacing: Spacing.xs) {
                if row.pipeline == .failed { Text("Download failed").foregroundStyle(.secondary) }
                // Hear it before downloading it (V-SIMILAR.N10): a stream in the toolbar player.
                StreamPreviewButton(link: row.recommendation.scDownloadUrl, title: row.recommendation.title, rowID: row.id)
                Button("Download") { model.download(row) }
                    .help("Downloads it and holds it in Discover ▸ Recommendations until you keep it")
                Button("Keep") { model.keep(row) }
                    .help("Downloads it straight into your library")
            }
        }
    }
}
