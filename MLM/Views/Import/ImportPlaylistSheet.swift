import SwiftUI

// MARK: - S-IMPORT (DEC-026, import.html, UC-SHEET-01…07)

/// `Import Playlist from Source` — one sheet in the main window, three steps: Source → Preview
/// → Confirm. Cancel (Esc) closes the sheet only; a running import goes on. The sheet never
/// shows download progress — the playlist's header echo and Activity do (DEC-044).
struct ImportPlaylistSheet: View {
    @Bindable var model: ImportPlaylistModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                switch model.step {
                case .source: SourceStep(model: model)
                case .preview: PreviewStep(model: model)
                case .confirm: ConfirmStep(model: model)
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let error = model.commitError {
                Text(error)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .frame(width: 760, height: 560)
        .onChange(of: model.isFinished) { _, finished in
            if finished { dismiss() }
        }
    }

    // MARK: Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if model.step != .source, let preview = model.preview {
                    SourceBrandDot(source: model.sourceName)
                    Text(preview.title).font(.headline).lineLimit(1)
                } else {
                    Text("Import Playlist from Source").font(.headline)
                }
            }
            HStack(spacing: 6) {
                stepLabel("1 Source", .source)
                Text("›")
                stepLabel("2 Preview", .preview)
                Text("›")
                stepLabel("3 Confirm", .confirm)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func stepLabel(_ text: String, _ step: ImportPlaylistModel.Step) -> some View {
        Text(text)
            .fontWeight(model.step == step ? .semibold : .regular)
            .foregroundStyle(model.step == step ? .primary : .secondary)
    }

    private var footer: some View {
        HStack {
            switch model.step {
            case .source:
                Text("Click a playlist or load a link to see its tracks.")
                    .font(.caption).foregroundStyle(.secondary)
            case .preview, .confirm:
                Button("Back") { model.back() }
                    .disabled(model.isCommitting)
            }
            Spacer()
            if model.isCommitting {
                ProgressView().controlSize(.small)
                Text("Adding the tracks…").foregroundStyle(.secondary)
            }
            // Closes the sheet only: a running import goes on (DEC-044). While a preview loads it
            // returns to step 1 (S-IMPORT.N09).
            Button("Cancel", role: .cancel) { model.cancel() }
                .keyboardShortcut(.cancelAction)
            switch model.step {
            case .source:
                Button("Next") { Task { await model.next() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canGoNextFromSource)
            case .preview:
                Button("Next") { Task { await model.next() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.preview == nil || model.selectedTracks.isEmpty)
            case .confirm:
                Button(model.importButtonTitle) { model.importNow() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canImport)
            }
        }
        .padding(20)
    }
}

// MARK: - Step 1: Source

private struct SourceStep: View {
    @Bindable var model: ImportPlaylistModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                List(selection: $model.selectedSource) {
                    ForEach(ImportSourceKind.allCases) { source in
                        HStack(spacing: 8) {
                            SourceBrandDot(source: source.name)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.name)
                                    .foregroundStyle(source == .appleMusic ? .secondary : .primary)
                                Text(model.sourceSubtitle(source))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(source)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 214)
                Button("Manage Accounts…") { model.environment.openSettingsSources() }
                    .buttonStyle(.link)
                    .padding(.leading, 8)
            }
            SourcePane(model: model, source: model.selectedSource)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct SourcePane: View {
    @Bindable var model: ImportPlaylistModel
    let source: ImportSourceKind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if source.takesLinks {
                linkField
            }
            switch source {
            case .appleMusic:
                ContentUnavailableView {
                    Label("Not available yet", systemImage: "music.note")
                } description: {
                    Text("Importing from Apple Music isn’t built yet. Playlists exported from Music as M3U can be imported with Import M3U….")
                }
            case .youtube:
                if model.environment.isYtDlpAvailable() {
                    ContentUnavailableView {
                        Label("Paste a YouTube playlist link", systemImage: "play.rectangle")
                    } description: {
                        Text("Public and unlisted playlists work. Mixes and live sets import as single long tracks without an album.")
                    }
                } else {
                    ToolMissingView(model: model, text: "YouTube playlists need the yt-dlp tool on this Mac.")
                }
            case .soundcloud, .spotify:
                accountPane
            }
        }
        .task(id: source) { await model.loadPlaylistsIfNeeded() }
    }

    private var linkField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Playlist link", text: $model.linkText, prompt: Text(source.linkPlaceholder))
                    .labelsHidden()
                    // Return is the sheet's default button (Next), which loads the link — once.
                Button("Load") { Task { await model.loadLink() } }
                    .disabled(!LinkSuggestion.isLink(model.linkText))
            }
            if let error = model.linkError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var accountPane: some View {
        if let service = source.service {
            let state = model.accounts.state(of: service)
            if state.isConnected {
                playlistList
            } else {
                SourceAccountProblemView(service: service, state: state, accounts: model.accounts) {
                    Task { await model.loadPlaylists(source) }
                }
            }
            if source == .spotify {
                Text("Spotify doesn’t provide audio files. MLM finds each track on SoundCloud or YouTube.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var playlistList: some View {
        switch model.listPhases[source] ?? .idle {
        case .idle, .loading:
            ProgressView("Loading your playlists…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let title):
            ContentUnavailableView {
                Label(title, systemImage: "exclamationmark.triangle")
            } description: {
                Text("Your playlists couldn’t be loaded. Check your internet connection and try again. You can still paste a playlist link above.")
            } actions: {
                Button("Try Again") { Task { await model.loadPlaylists(source) } }
            }
        case .loaded:
            let all = model.playlists[source] ?? []
            if all.isEmpty {
                ContentUnavailableView {
                    Label("No playlists in this account", systemImage: "music.note.list")
                } description: {
                    Text("Paste a playlist link above, or use Refresh from Sources to pull your likes.")
                }
            } else {
                HStack {
                    Text("Your \(source.name) playlists · \(all.count.formatted(.number))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    TextField("Filter", text: $model.playlistFilter)
                        .frame(width: 150)
                }
                List(model.visiblePlaylists) { playlist in
                    Button {
                        Task { await model.open(playlist) }
                    } label: {
                        PlaylistRow(playlist: playlist, imported: model.isImported(playlist))
                    }
                    .buttonStyle(.plain)
                    .disabled(playlist.trackCount == 0)
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds()
            }
        }
    }
}

private struct PlaylistRow: View {
    let playlist: RemotePlaylistSummary
    let imported: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note.list").foregroundStyle(.secondary)
            Text(playlist.title).lineLimit(1).truncationMode(.tail)
            if playlist.isPrivate {
                Label("Private", systemImage: "lock").labelStyle(.titleAndIcon)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if imported {
                Text("Already imported").font(.caption).foregroundStyle(.secondary)
            }
            Text(ActivityNoun.track.counted(playlist.trackCount))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct ToolMissingView: View {
    let model: ImportPlaylistModel
    let text: String

    var body: some View {
        ContentUnavailableView {
            Label("yt-dlp not found", systemImage: "exclamationmark.triangle")
        } description: {
            Text(text)
        } actions: {
            Button("Open Settings ▸ Sources") { model.environment.openSettingsSources() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Step 2: Preview

private struct PreviewRow: Identifiable {
    let id: Int
    let title: String
    let artist: String
    let time: String
    let match: ImportPreviewMatch
}

private struct PreviewStep: View {
    @Bindable var model: ImportPlaylistModel
    @State private var countText = "20"
    @State private var showsDetails = false

    var body: some View {
        switch model.previewPhase {
        case .idle, .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading playlist…").font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let problem):
            problemView(problem)
        case .loaded:
            loaded
        }
    }

    private var rows: [PreviewRow] {
        model.selectedRows.map { number, track in
            PreviewRow(id: number, title: track.title, artist: track.artist,
                       time: track.durationSeconds.map(LinkSuggestion.time) ?? "",
                       match: model.match(track))
        }
    }

    private var loaded: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Tracks", selection: $model.selectionMode) {
                    ForEach(ImportPlaylistModel.SelectionMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if model.selectionMode != .all {
                    TextField("n", text: $countText)
                        .frame(width: 46)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .onSubmit(commitCount)
                        .onChange(of: countText) { commitCount() }
                }
                Spacer()
                Text(model.summaryLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Table(rows) {
                TableColumn("#") { Text("\($0.id)").monospacedDigit().foregroundStyle(.secondary) }
                    .width(34)
                TableColumn("Title") { Text($0.title).lineLimit(1) }
                TableColumn("Artist") { Text($0.artist.isEmpty ? "—" : $0.artist).lineLimit(1) }
                    .width(min: 100, ideal: 150)
                TableColumn("Time") { Text($0.time).monospacedDigit() }
                    .width(50)
                TableColumn("Status") { row in
                    HStack(spacing: 4) {
                        switch row.match {
                        case .new: EmptyView()
                        case .inLibrary: Image(systemName: "icloud").foregroundStyle(.secondary)
                        case .downloaded: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                        }
                        Text(row.match.word).foregroundStyle(row.match == .new ? .primary : .secondary)
                    }
                }
                .width(min: 110, ideal: 150)
            }
            .frame(minHeight: 200)
            options
        }
        .onAppear { countText = "\(model.count)" }
    }

    private func commitCount() {
        let digits = countText.filter(\.isNumber)
        let total = model.preview?.tracks.count ?? 1
        let value = min(max(1, Int(digits) ?? 1), max(1, total))
        if model.count != value { model.count = value }
    }

    private var options: some View {
        Form {
            if let existing = model.existingLinked {
                Picker(selection: $model.target) {
                    Text("“\(existing.name)” — Linked to \(model.sourceName)")
                        .tag(PlaylistImportTarget.existing(id: existing.id, name: existing.name))
                    Text("New playlist “\(model.preview?.title ?? "")”").tag(PlaylistImportTarget.newPlaylist)
                } label: {
                    Text("Add to")
                    Text(model.targetNote)
                }
            } else {
                LabeledContent {
                    Text(model.targetTitle)
                } label: {
                    Text("Add to")
                    Text(model.targetNote)
                }
            }
            Toggle(isOn: $model.downloadNow) {
                Text("Download now")
                Text(model.downloadNote)
            }
            if case .newPlaylist = model.target {
                Toggle(isOn: $model.keepLinked) {
                    Text("Keep linked to \(model.sourceName)")
                    Text(model.linkNote)
                }
                .disabled(!model.linkIsAvailable)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func problemView(_ problem: ImportPlaylistModel.PreviewProblem) -> some View {
        switch problem {
        case .didNotAnswer(let source, let detail):
            ContentUnavailableView {
                Label("\(source) didn’t answer", systemImage: "exclamationmark.triangle")
            } description: {
                VStack(spacing: 6) {
                    Text("The playlist couldn’t be loaded. Nothing was imported.")
                    DisclosureGroup("Details", isExpanded: $showsDetails) {
                        Text(detail).font(.caption).textSelection(.enabled)
                    }
                    .frame(maxWidth: 360)
                }
            } actions: {
                Button("Try Again") { Task { await model.reloadPreview() } }
                    .buttonStyle(.borderedProminent)
            }
        case .signInExpired(let source), .notConnected(let source):
            if let service = source.service {
                SourceAccountProblemView(
                    service: service,
                    state: problem == .notConnected(source) ? .disconnected : .signInExpired,
                    accounts: model.accounts,
                    message: problem == .notConnected(source)
                        ? "Connect your \(source.name) account to load this playlist."
                        : "\(source.name) stopped answering because your sign-in ran out. Reconnect to continue — your place is kept."
                ) {
                    Task { await model.reloadPreview() }
                }
            }
        case .privateOrUnavailable(let source):
            ContentUnavailableView {
                Label("This playlist is private or no longer available", systemImage: "lock")
            } description: {
                Text("\(source) doesn’t offer it to your account. If it is yours, check its privacy setting on \(source).")
            }
        case .toolMissing:
            ToolMissingView(model: model, text: "YouTube playlists need the yt-dlp tool on this Mac.")
        case .empty:
            ContentUnavailableView {
                Label("This playlist has no tracks", systemImage: "music.note.list")
            } description: {
                Text("There is nothing to import from it.")
            }
        }
    }
}

// MARK: - Step 3: Confirm

private struct ConfirmStep: View {
    @Bindable var model: ImportPlaylistModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let queued = model.queuedNote {
                Label {
                    Text(queued).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "clock")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            Form {
                LabeledContent("Playlist", value: model.targetTitle)
                LabeledContent {
                    Text(model.counts.total.formatted(.number)).monospacedDigit()
                } label: {
                    Text("Tracks")
                    Text(model.tracksDetail)
                }
                LabeledContent {
                    Text(model.downloadValue)
                } label: {
                    Text("Download")
                    Text(model.downloadValueNote)
                }
                LabeledContent("Link", value: model.linkValue)
                if model.offersAlsoDownload {
                    Toggle(model.alsoDownloadTitle, isOn: $model.alsoDownloadKnown)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            Text("After you click Import this sheet closes. Progress shows on the playlist and in Activity. Failed tracks can be retried there at any time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
