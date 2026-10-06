import SwiftUI

// MARK: - Guesses (V-REELS.N06, E13, E14, E15, E17, E18)

struct ReelGuessesSection: View {
    let model: ReelsModel
    let item: ReelItem
    let bench: ReelBench

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Guesses").font(.headline)
                Text("A guess fills Artist and Title only when you press Use. Nothing is overwritten silently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    if bench.guesses.isEmpty {
                        Text("No guesses yet. Press Identify, or type the artist and title yourself.")
                            .foregroundStyle(.secondary)
                            .padding(Spacing.s)
                    }
                    ForEach(bench.guesses) { guess in
                        guessRow(guess)
                        Divider()
                    }
                    if !bench.fragments.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Text in video").font(.caption).foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Spacing.xs) {
                                    ForEach(bench.fragments, id: \.self) { fragment in
                                        ReelFragmentCapsule(model: model, text: fragment)
                                    }
                                }
                            }
                        }
                        .padding(Spacing.s)
                        Divider()
                    }
                    audioRow
                }
            }
        }
    }

    private func guessRow(_ guess: ReelGuess) -> some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(guess.line).lineLimit(1).truncationMode(.tail)
                Text(guess.provenanceLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.s)
            if bench.usedGuessID == guess.id {
                Text("In use").foregroundStyle(.secondary)
            } else {
                Button("Use") { Task { await model.use(guess) } }
            }
        }
        .padding(Spacing.s)
        .accessibilityElement(children: .combine)
    }

    /// `Identify by Audio (Shazam)` — a guess, nothing more; offline and no match are different
    /// sentences.
    private var audioRow: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                switch bench.audio {
                case .idle:
                    Text("Shazam listens to the first 12 seconds.").foregroundStyle(.secondary)
                case .listening:
                    HStack(spacing: Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Listening to the first 12 seconds…")
                    }
                case .found(let date):
                    Text("Shazam listened on \(date.formatted(.dateTime.month(.abbreviated).day())) and found the guess above.")
                        .foregroundStyle(.secondary)
                case .notRecognised:
                    Text("Shazam didn’t recognise this audio.")
                    Text("Try the text in the video, or type the artist and title yourself.")
                        .font(.caption).foregroundStyle(.secondary)
                case .offline:
                    Label("Can’t identify by audio — this Mac is offline.", systemImage: "globe")
                    Text("Guesses from the file name and the text in the video still work.")
                        .font(.caption).foregroundStyle(.secondary)
                case .failed(let cause):
                    Label("Couldn’t identify by audio — \(cause).", systemImage: "exclamationmark.triangle")
                }
            }
            Spacer(minLength: Spacing.s)
            if bench.audio == .listening {
                Button("Cancel") { model.cancelIdentify(item.id) }
            } else {
                Button("Identify by Audio (Shazam)") { Task { await model.identifyByAudio(item.id) } }
                    .disabled(bench.isIdentifying || !bench.videoReachable)
            }
        }
        .padding(Spacing.s)
    }
}

// MARK: - Song (V-REELS.E09, E11, K-REELS-RETURN)

struct ReelSongSection: View {
    let model: ReelsModel
    let bench: ReelBench

    private enum Field: Hashable { case artist, title }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Song").font(.headline)
                if let source = bench.filledFrom {
                    Text(source == "Typed by you" ? source : "Filled from: \(source)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(spacing: Spacing.s) {
                    LabeledContent("Artist") {
                        TextField("Artist", text: Binding(get: { bench.artist }, set: { model.setArtist($0) }))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .focused($focus, equals: .artist)
                            .onSubmit { Task { await model.search() } }
                    }
                    LabeledContent("Title") {
                        HStack(spacing: Spacing.s) {
                            TextField("Title", text: Binding(get: { bench.title }, set: { model.setTitle($0) }))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .focused($focus, equals: .title)
                                .onSubmit { Task { await model.search() } }
                            Button("Search") { Task { await model.search() } }
                                .disabled(!bench.canSearch)
                        }
                    }
                }
                .padding(Spacing.s)
            }
            // The fields save when you leave them, not on every keystroke (V-REELS.E09).
            .onChange(of: focus) { old, new in
                if old != nil, new == nil { Task { await model.commitFields() } }
            }
        }
    }
}

// MARK: - Results (V-REELS.E19, E20, E21, N07, N08)

struct ReelResultsSection: View {
    let model: ReelsModel
    let bench: ReelBench

    @Environment(\.container) private var container

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Results").font(.headline)
                if case .results(let query, _) = bench.search {
                    Text("for “\(query)” · up to 3 per source")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                let drive = LibraryDriveState.current(container)
                if drive.isOffline, let name = drive.volumeName {
                    Text("Downloads wait until “\(name)” is connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            switch bench.search {
            case .nothingToSearch:
                note("Nothing to search for yet",
                     "Choose a guess or type an artist and a title. MLM then searches \(ReelSource.sentenceList).")
            case .searching(let query):
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Searching for “\(query)”…")
                }
                .padding(Spacing.s)
            case .results(_, let groups):
                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            groupHeader(group)
                            ForEach(group.results) { result in
                                Divider()
                                ReelResultRow(model: model, bench: bench, result: result)
                            }
                            if group.id != groups.last?.id { Divider() }
                        }
                    }
                }
            case .noMatches(let query):
                note("No matches on any source",
                     "Nothing found for “\(query)” on \(orList). Try a shorter title or only the artist.",
                     action: ("Search Again", { Task { await model.search() } }))
            case .offline:
                note("Can’t search — this Mac is offline",
                     "Artist and title are saved with the reel. Search again when you are back online.",
                     symbol: "globe", action: ("Try Again", { Task { await model.search() } }))
            }
        }
    }

    private var orList: String {
        let words = ReelSource.allCases.map(\.word)
        return words.dropLast().joined(separator: ", ") + " or " + (words.last ?? "")
    }

    private func groupHeader(_ group: ReelSearchGroup) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(group.source.word).bold()
            Text(group.countWord).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private func note(_ title: String, _ text: String, symbol: String? = nil, action: (String, () -> Void)? = nil) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                    Text(title).font(.headline)
                }
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.0, action: action.1).padding(.top, Spacing.xxs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.s)
        }
    }
}

/// One result: words instead of unlabelled icons. `Download` shows its state in the row
/// (`Queued` → `Downloading…` → `In library`, or `Download failed — ‹reason›` and `Retry`);
/// `Add to Playlist ▸` is the standard submenu (CM-REELS-ADDPL). A result preview needs a stream
/// preview that doesn't exist yet, so there is no Preview button (no dead controls).
private struct ReelResultRow: View {
    let model: ReelsModel
    let bench: ReelBench
    let result: ReelSearchResult

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).lineLimit(1).truncationMode(.tail)
                Text(result.detailLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            if let state = bench.downloads[result.id] {
                Text(state.word)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if state.isFailed {
                    Button("Retry") { Task { await model.retry(result) } }
                }
            } else {
                Button("Download") { Task { await model.download(result) } }
                addToPlaylist
            }
        }
        .padding(Spacing.s)
        .accessibilityElement(children: .combine)
    }

    private var addToPlaylist: some View {
        let sources = TrackMenuSources.shared
        return Menu("Add to Playlist") {
            AddToPlaylistMenuItems(
                playlists: sources.playlists,
                showsKeyEquivalents: false,
                newPlaylist: { Task { await model.newPlaylist(from: result) } },
                add: { id in Task { await model.addToPlaylist(result, playlistID: id) } })
        }
        .menuStyle(.button)
        .fixedSize()
        .onAppear { sources.loadIfNeeded() }
    }
}
