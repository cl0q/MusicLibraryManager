import SwiftUI

/// The `Online` scope (V-SEARCH.N08–N13, E05/E08): one section per source in the order they
/// answered, each with its own `Searching ‹Source›…` line or its error in words with one fix.
/// Results are transient — nothing is added to the library until `Download` (UC-SEARCH-03,
/// fixes PP-MAIN-04). Preview of an online row arrives with W3-DISC.
struct OnlineSearchResultsView: View {
    let search: ToolbarSearchModel
    let model: OnlineSearchModel
    let filter: SearchFilter

    @Environment(\.container) private var container
    @Environment(\.openSettings) private var openSettings
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?

    private var query: String { filter.isLink ? "" : filter.onlineQuery }

    var body: some View {
        content
            // Choosing `Online` is the explicit request: ask now (typing afterwards waits for
            // the pause; Return asks at once).
            .onAppear { if query != model.query || model.sections.isEmpty { model.searchNow(query) } }
            .onChange(of: query) { _, newQuery in model.queryChanged(newQuery) }
            .onChange(of: container.searchCoordinator.submitCount) { _, _ in model.searchNow(query) }
    }

    @ViewBuilder
    private var content: some View {
        if model.hasNoSources {
            ContentUnavailableView {
                Label("No sources to search", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text("Connect SoundCloud or Spotify, or install yt-dlp, to search online.")
            } actions: {
                Button("Open Settings ▸ Sources") { openSettings(tab: .sources) }
            }
        } else if query.isEmpty {
            ContentUnavailableView {
                Label("Search online", systemImage: "globe")
            } description: {
                Text("Type what you’re looking for. Online results aren’t added to your library until you download them.")
            }
        } else {
            List {
                Label("Online results aren’t added to your library until you download them.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                ForEach(model.sections) { section in
                    Section {
                        sectionContent(section)
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ section: OnlineSection) -> some View {
        HStack(spacing: Spacing.xs) {
            SourceBrandDot(source: section.source.name)
            Text(section.source.name)
            if case .results(let rows) = section.state {
                Text(rows.count == 1 ? "1 result" : "\(rows.count.formatted(.number)) results")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: OnlineSection) -> some View {
        switch section.state {
        case .searching:
            HStack(spacing: Spacing.s) {
                ProgressView()
                    .controlSize(.small)
                Text("Searching \(section.source.name)…")
                    .foregroundStyle(.secondary)
            }
        case .failed(let failure):
            HStack(spacing: Spacing.s) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(failure.fix == .tryAgain ? .red : .orange)
                    .accessibilityHidden(true)
                Text(failure.sentence(for: section.source))
                Button(failure.fix.title) { fix(failure.fix, source: section.source) }
                    .buttonStyle(.link)
            }
            .help(failure.details ?? "")
        case .results(let rows):
            if rows.isEmpty {
                Text("No results on \(section.source.name).")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    resultRow(row, source: section.source)
                }
            }
        }
    }

    private func resultRow(_ row: OnlineResultRow, source: OnlineSource) -> some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 0) {
                Text(row.result.title)
                    .lineLimit(1)
                Text(TrackMetadataPresentation.artistDisplay(row.result.artist) ?? "—")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            Text(row.result.durationSeconds.map(LinkSuggestion.time) ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            rowState(row)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func rowState(_ row: OnlineResultRow) -> some View {
        if let trackID = row.libraryTrackID {
            if model.startedDownloads[row.id] != nil, container.downloadViewModel?.isDownloading == true {
                HStack(spacing: Spacing.xxs) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading…")
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: Spacing.xs) {
                    Label("In library", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Button("Show") { SearchReveal.showInAllTracks(trackID, search: search) }
                        .buttonStyle(.link)
                }
            }
        } else {
            Button("Download") { download(row) }
        }
    }

    private func fix(_ fix: OnlineSourceFailure.Fix, source: OnlineSource) {
        switch fix {
        case .reconnect, .openSettings: openSettings(tab: .sources)
        case .tryAgain: model.retry(source)
        }
    }

    /// The only action that creates a library track from an online result (album stays empty).
    private func download(_ row: OnlineResultRow) {
        guard let service = SearchDownloadService.live(container) else { return }
        Task {
            let outcome = await service.download(row.result)
            switch outcome {
            case .started(let id, _), .alreadyInLibrary(let id):
                model.downloadStarted(resultID: row.id, trackID: id)
            case .busy, .failed:
                break
            }
            statusBar?.post(SearchDownloadService.message(for: outcome, title: row.result.title))
        }
    }
}

/// Show a library track in All Tracks, selected (`In library · Show`, a link already in the
/// library). All Tracks' filter is cleared so the row can show.
@MainActor
enum SearchReveal {
    static func showInAllTracks(_ trackID: Int64, search: ToolbarSearchModel, container: DependencyContainer = .shared) {
        search.show(.empty, in: .allTracks)
        Task {
            guard let track = try? await container.trackRepository?.fetchTrack(id: trackID) else { return }
            container.libraryViewModel?.reveal(trackID: trackID, availability: track.availability())
            TrackListReveal.shared.reveal(trackID: trackID, listKey: "allTracks", container: .library)
        }
    }
}
