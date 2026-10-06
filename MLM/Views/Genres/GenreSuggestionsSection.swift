import SwiftUI

/// `Suggested tracks` (V-GENRED.N04–N09, ST-STUDIO-GENRE): docked under a genre's track table,
/// collapsible (collapsed by default, remembered). Tracks that sound like a reference track of
/// the genre and don't carry it yet, in the shared track table (Space previews in the toolbar
/// player — the two mini players are gone, DEC-009/010), with `Match` and the verdicts
/// `Add to Genre` (stages) · `Not Now` (hides for the session). Below, while tracks are staged,
/// the staging bar: `Discard` · `Save n Changes` (⌘S, one undo step, DEC-041).
struct GenreSuggestionsSection: View {
    let genreKey: String
    let genreName: String
    let genreTracks: [Track]
    /// The genre table's selected tracks (`Use Selected Track`).
    let genreSelection: () -> [Track]
    let writesTags: Bool
    let onTrackActivated: TrackActivation

    @Environment(\.container) private var container
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(\.openSettings) private var openSettings

    @State private var list = TrackListModel()
    @State private var verdicts = TrackSuggestionVerdicts()
    @State private var coverage: (analysed: Int, total: Int)?
    @State private var isSaving = false

    private var workbench: GenreWorkbench { GenreWorkbench.shared }
    private var page: GenreWorkbench.Page { workbench.page(genreKey) }

    private var drive: LibraryDriveState { LibraryDriveState.current(container) }

    var body: some View {
        let page = self.page
        VStack(spacing: 0) {
            Divider()
            sectionHeader(page)
            if workbench.isSuggestionsExpanded {
                sectionBody(page)
            }
            if !page.staged.isEmpty {
                stagingBar(page)
            }
        }
        .background(.background)
        .task(id: RowsKey(page: page)) { await showRows(page) }
        .onChange(of: InspectorAnalysis.shared.isRunning(page.reference?.id ?? -1)) { _, running in
            // `Analyze This Track` finished: the suggestions appear (V-GENRED.N07).
            if !running, page.state == .notAnalysed { recompute() }
        }
    }

    private struct RowsKey: Equatable {
        let staged: [Int64]
        let suggestions: [Int64]
        init(page: GenreWorkbench.Page) {
            staged = page.staged.compactMap(\.id)
            suggestions = page.suggestions.map(\.id)
        }
    }

    /// Staged rows first (row state `Staged`), then the suggestions, best match first.
    private func showRows(_ page: GenreWorkbench.Page) async {
        verdicts.stagedIDs = page.stagedIDs
        verdicts.stage = { id in stage([id]) }
        verdicts.unstage = { id in workbench.unstage([id], genreKey: genreKey) }
        verdicts.hide = { id in hide([id]) }
        var seen = Set<Int64>()
        let tracks = (page.staged + page.suggestions.map(\.track)).filter { $0.id.map { seen.insert($0).inserted } ?? false }
        var context = TrackRowBuildContext.library
        context.matchPercents = page.matchByID
        await list.setTracks(tracks, context: context)
    }

    // MARK: Header (disclosure)

    private func sectionHeader(_ page: GenreWorkbench.Page) -> some View {
        Button {
            workbench.isSuggestionsExpanded.toggle()
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: workbench.isSuggestionsExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text("Suggested tracks").fontWeight(.semibold)
                Text("Tracks that sound like the reference and aren’t in this genre. Nothing changes until you save.")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: Spacing.s)
                if !page.staged.isEmpty {
                    Text("\(page.staged.count.formatted(.number)) staged")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xs)
        .accessibilityLabel(workbench.isSuggestionsExpanded ? "Hide suggested tracks" : "Show suggested tracks")
    }

    // MARK: Body

    @ViewBuilder
    private func sectionBody(_ page: GenreWorkbench.Page) -> some View {
        switch page.state {
        case .noReference where page.staged.isEmpty:
            noReference
        case .notAnalysed:
            notAnalysed(page)
        default:
            VStack(spacing: 0) {
                controls(page)
                Divider()
                if case .failed(let text) = page.state {
                    message(title: text, text: nil) {
                        Button("Try Again") { recompute() }
                    }
                    .frame(height: 140)
                } else {
                    table
                        .frame(height: 220)
                }
                if drive.isOffline, let volume = drive.volumeName {
                    Text(writesTags
                         ? "Previews are paused — “\(volume)” is not connected. You can still stage and save; file tags are written when the drive returns."
                         : "Previews are paused — “\(volume)” is not connected. You can still stage and save.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.xl)
                        .padding(.vertical, Spacing.xxs)
                }
            }
        }
    }

    private var table: some View {
        TrackListTable(model: list, configuration: configuration) {
            message(title: "No more suggestions", text: "Try Match: Wide, show 20, or include tracks that already have a genre.") {
                EmptyView()
            }
        }
        .environment(\.trackSuggestionVerdicts, verdicts)
        // Its own selection-bar channel: the page's bar stays with the genre's tracks.
        .hostsTrackSelectionBar()
    }

    private var configuration: TrackListConfiguration {
        let name = genreName
        return TrackListConfiguration(
            listContext: .unnamed,
            persistenceKey: "genreSuggestions",
            columns: [.title, .artist, .genre, .time, .match, .suggestion],
            defaultSort: nil,
            publishesStatusText: false,
            accessibilityID: "genre_suggestion_table",
            activate: onTrackActivated,
            menuExtras: TrackMenuExtrasProvider(
                items: { [verdicts] rows in
                    let unstaged = rows.contains { !verdicts.stagedIDs.contains($0.id) }
                    return TrackMenuExtras(
                        addTo: unstaged ? [TrackMenuExtra(id: Self.addID, title: "Add to “\(name)”")] : [],
                        remove: [TrackMenuExtra(id: Self.notNowID, title: "Not Now")]
                    )
                },
                perform: { id, rows in
                    let ids = rows.map(\.id)
                    switch id {
                    case Self.addID: stage(ids)
                    case Self.notNowID: hide(ids)
                    default: break
                    }
                }
            )
        )
    }

    private static let addID = "genre.addToGenre"
    private static let notNowID = "genre.notNow"

    private func controls(_ page: GenreWorkbench.Page) -> some View {
        HStack(spacing: Spacing.m) {
            if let reference = page.reference {
                HStack(spacing: Spacing.xs) {
                    Text("Reference").foregroundStyle(.secondary)
                    if let id = reference.id {
                        TrackCoverView(trackId: id, size: .small, cornerRadius: 3)
                            .frame(width: 18, height: 18)
                    }
                    Text(reference.title).fontWeight(.semibold).lineLimit(1)
                    Text(TrackMetadataPresentation.artistDisplay(reference.artist) ?? "").foregroundStyle(.secondary).lineLimit(1)
                    referenceMenu
                }
            } else {
                referenceMenu
            }
            if page.state == .loading {
                ProgressView().controlSize(.small)
                Text("Finding suggestions…").foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.s)
            if !page.hidden.isEmpty {
                Button("Show Hidden (\(page.hidden.count.formatted(.number)))") {
                    workbench.unhideAll(genreKey: genreKey)
                    recompute()
                }
                .buttonStyle(.link)
                .help("Suggestions hidden with Not Now come back")
            }
            Picker("Match", selection: optionBinding(\.match)) {
                ForEach(GenreSuggestionOptions.Match.allCases) { match in
                    Text(match.title).tag(match)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Close shows only near matches; Wide is more adventurous")
            Picker("Show", selection: optionBinding(\.count)) {
                ForEach(GenreSuggestionOptions.countChoices, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Toggle("Only tracks without a genre", isOn: optionBinding(\.onlyTracksWithoutGenre))
                .toggleStyle(.checkbox)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xs)
    }

    /// `Change…`: the selected track above, or a typical one; or no reference.
    private var referenceMenu: some View {
        Menu(page.reference == nil ? "Choose Reference…" : "Change…") {
            Button("Use Selected Track") { useSelectedTrack() }
                .disabled(genreSelection().count != 1)
            Button("Pick a Typical Track") { pickTypicalTrack() }
            if page.reference != nil {
                Divider()
                Button("Clear Reference") { workbench.clearReference(genreKey: genreKey) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func optionBinding<Value>(_ path: WritableKeyPath<GenreSuggestionOptions, Value>) -> Binding<Value> {
        Binding(
            get: { workbench.options[keyPath: path] },
            set: { value in
                workbench.options[keyPath: path] = value
                recompute()
            }
        )
    }

    // MARK: States (V-GENRED.N06 / N07)

    private var noReference: some View {
        message(title: "Choose a reference track",
                text: "Suggestions are tracks that sound like one track of this genre. Select a typical track in the list above, or let MLM pick one.") {
            Button("Use Selected Track") { useSelectedTrack() }
            Button("Pick a Typical Track") { pickTypicalTrack() }
        }
    }

    private func notAnalysed(_ page: GenreWorkbench.Page) -> some View {
        let title = page.reference?.title ?? "The reference track"
        let running = page.reference?.id.map(InspectorAnalysis.shared.isRunning) ?? false
        var text = "Suggestions compare how tracks sound, and that needs the similarity analysis of the reference track."
        if let coverage {
            text += " \(coverage.analysed.formatted(.number)) of \(StatusBarText.tracks(coverage.total)) are analysed."
        }
        return message(title: "“\(title)” hasn’t been analysed", text: text) {
            Button(running ? "Analyzing…" : "Analyze This Track") { analyzeReference(page) }
                .buttonStyle(.borderedProminent)
                .disabled(running || drive.isOffline || !(page.reference?.isLocal ?? false))
                .help(drive.isOffline ? "Analysis needs the file — “\(drive.volumeName ?? "the library disk")” is not connected." : "")
            Button("Choose Another Track") { workbench.clearReference(genreKey: genreKey) }
            Button("Settings ▸ Maintenance") { openSettings(tab: .maintenance) }
                .buttonStyle(.link)
        }
        .task {
            coverage = try? await GenreRepository.live(container)?.similarityCoverage()
        }
    }

    private func message<Actions: View>(title: String, text: String?, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: Spacing.s) {
            Text(title).font(.headline)
            if let text {
                Text(text)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Spacing.s) { actions() }
                .padding(.top, Spacing.xxs)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.l)
    }

    // MARK: Staging bar (V-GENRED.N08)

    private func stagingBar(_ page: GenreWorkbench.Page) -> some View {
        let count = page.staged.count
        return HStack(spacing: Spacing.s) {
            Text(count == 1 ? "1 track staged for “\(genreName)”" : "\(count.formatted(.number)) tracks staged for “\(genreName)”")
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(consequence)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Spacing.s)
            Button("Discard") { discard() }
                .disabled(isSaving)
            Button(count == 1 ? "Save 1 Change" : "Save \(count.formatted(.number)) Changes") { save(page) }
                .buttonStyle(.borderedProminent)
                // UC-KEY-31: ⌘S saves the staged changes — only while there are some.
                .keyboardShortcut("s", modifiers: .command)
                .disabled(isSaving)
        }
        .font(.callout)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xs)
        .overlay(alignment: .top) { Divider() }
    }

    /// What saving does and where (V-GENRED.N08).
    private var consequence: String {
        guard writesTags else { return "Saving sets their genre in the library." }
        if drive.isOffline, let volume = drive.volumeName {
            return "Saving sets their genre in the library now; the files’ tags are written when “\(volume)” is connected."
        }
        return "Saving sets their genre in the library and in the files’ tags."
    }

    // MARK: Actions

    private func stage(_ ids: [Int64]) {
        let byID = Dictionary(page.suggestions.map { ($0.id, $0.track) }, uniquingKeysWith: { first, _ in first })
        workbench.stage(ids.compactMap { byID[$0] }, genreKey: genreKey)
    }

    private func hide(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        workbench.hide(Set(ids), genreKey: genreKey)
        let title = ids.count == 1 ? page.suggestions.first { $0.id == ids[0] }?.track.title : nil
        statusBar?.post("\(title.map { "“\($0)”" } ?? StatusBarText.tracks(ids.count)) won’t be suggested for “\(genreName)” again this session")
    }

    private func discard() {
        let count = workbench.discard(genreKey: genreKey)
        if count > 0 {
            statusBar?.post(count == 1 ? "Discarded 1 staged change" : "Discarded \(count.formatted(.number)) staged changes")
        }
    }

    /// One `TrackTagEdit` step over every staged track (DEC-041); the confirmation and its
    /// `Undo` come from the undo center.
    private func save(_ page: GenreWorkbench.Page) {
        guard let edits = GenreEdits.live(undo: undo, container: container) else { return }
        let ids = page.staged.compactMap(\.id)
        isSaving = true
        Task {
            defer { isSaving = false }
            if (try? await edits.saveStaged(ids, genreName: genreName)) != nil {
                workbench.didSave(Set(ids), genreKey: genreKey)
            }
        }
    }

    private func recompute() {
        guard let repository = GenreRepository.live(container), let source = GenreSimilaritySource.live(container) else { return }
        workbench.recompute(genreKey: genreKey, genreName: genreName, repository: repository, source: source)
    }

    private func setReference(_ track: Track) {
        guard let repository = GenreRepository.live(container), let source = GenreSimilaritySource.live(container) else { return }
        workbench.setReference(track, genreKey: genreKey, genreName: genreName, repository: repository, source: source)
    }

    private func useSelectedTrack() {
        let selected = genreSelection()
        guard selected.count == 1, let track = selected.first else {
            statusBar?.post("Select one track in the list above first.")
            return
        }
        setReference(track)
    }

    private func pickTypicalTrack() {
        let ids = genreTracks.compactMap(\.id)
        Task {
            guard let id = try? await GenreRepository.live(container)?.typicalTrackID(among: ids),
                  let track = genreTracks.first(where: { $0.id == id }) else {
                statusBar?.post("No track of “\(genreName)” is analysed yet — select one and choose Use Selected Track.")
                return
            }
            setReference(track)
        }
    }

    private func analyzeReference(_ page: GenreWorkbench.Page) {
        guard let track = page.reference else { return }
        Task {
            guard let url = await TrackFileLocator.localURL(for: track, container: container) else {
                statusBar?.post("Can’t analyze “\(track.title)” — its file can’t be found.")
                return
            }
            InspectorAnalysis.shared.analyze(track, fileURL: url, container: container)
        }
    }
}
