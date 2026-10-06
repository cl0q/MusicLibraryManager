import SwiftUI

/// **Merge Genres…** (`s-merge`, ST-STUDIO-MERGE, DEC-041): the genres selected in the list,
/// one can be unticked; `Merge into` prefilled with the largest; a consequence sentence with
/// the count; the tracks that change with their current genre (the shared track table: Space
/// previews, Return plays); `Merge n Genres` = **one** undoable tag edit over every affected
/// track. Replaces the `Consolidate genres` screen (German label, no count, no undo).
struct GenreMergeSheet: View {
    let genres: [GenreSummary]
    /// The merged genre's key, after a merge (the list selects it).
    var didMerge: (String) -> Void = { _ in }

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(UndoCenter.self) private var undo: UndoCenter?

    @State private var included: Set<String> = []
    @State private var name = ""
    @State private var tracks: [Track] = []
    @State private var writesTags = false
    @State private var isMerging = false
    @State private var failure: String?
    @State private var preview = TrackListModel(sortOrder: TrackSortOrder(column: .genre, ascending: true))

    private var ordered: [GenreSummary] {
        genres.sorted { $0.trackCount != $1.trackCount ? $0.trackCount > $1.trackCount : $0.name < $1.name }
    }

    private var chosen: [GenreSummary] { ordered.filter { included.contains($0.key) } }
    private var cleanedName: String? { GenreName.cleaned(name) }

    /// Tracks whose stored genre is not already exactly the new name.
    private var changing: [Track] {
        guard let target = cleanedName else { return tracks }
        let keys = Set(chosen.map(\.key))
        return tracks.filter { track in
            guard let key = GenreName.key(track.genre), keys.contains(key) else { return false }
            return track.genre != target
        }
    }

    private var isValid: Bool { cleanedName != nil && chosen.count >= 2 && !isMerging }

    var body: some View {
        let changing = self.changing
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], Spacing.l)
            Form {
                Section("Genres to merge") {
                    ForEach(ordered) { genre in
                        Toggle(isOn: binding(for: genre)) {
                            HStack {
                                Text(genre.name)
                                Spacer()
                                Text(StatusBarText.tracks(genre.trackCount))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                Section {
                    TextField("Merge into", text: $name, prompt: Text("Genre name, e.g. Hip-Hop"))
                    if cleanedName == nil {
                        Label("Enter the name of the genre to merge into.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(consequence(changing: changing.count))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("Tracks that change") {
                    TrackListTable(model: preview, configuration: previewConfiguration) {
                        Text("No track changes.").foregroundStyle(.secondary).padding()
                    }
                    .frame(minHeight: 180, idealHeight: 220)
                    Text("Showing \(changing.count.formatted(.number)) of \(StatusBarText.tracks(changing.count)). Their current genre is in the Genre column.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .formStyle(.grouped)
            footer
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 560, idealHeight: 640)
        .task {
            included = Set(genres.map(\.key))
            name = ordered.first?.name ?? ""
            writesTags = await TagWriteSetting.isEnabled(container.configRepository)
            if let repository = GenreRepository.live(container) {
                tracks = (try? await repository.tracks(genreKeys: Set(genres.map(\.key)))) ?? []
            }
            await preview.setTracks(changing)
        }
        .onChange(of: included) { _, _ in Task { await preview.setTracks(changing) } }
        .onChange(of: name) { _, _ in Task { await preview.setTracks(changing) } }
    }

    private var title: String { "Merge \(chosen.count) Genres" }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Undo with ⌘Z after merging")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(title) { merge() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(Spacing.l)
    }

    private var previewConfiguration: TrackListConfiguration {
        TrackListConfiguration(
            listContext: .unnamed,
            persistenceKey: "genreMergePreview",
            columns: [.title, .artist, .genre, .time],
            defaultSort: TrackSortOrder(column: .genre, ascending: true),
            publishesStatusText: false,
            accessibilityID: "genre_merge_preview",
            activate: { track, queue in shell?.activateTrack?(track, queue) }
        )
    }

    private func binding(for genre: GenreSummary) -> Binding<Bool> {
        Binding(
            get: { included.contains(genre.key) },
            set: { on in if on { included.insert(genre.key) } else { included.remove(genre.key) } }
        )
    }

    /// ST-STUDIO-MERGE.E02: how many tracks change, which genres disappear, where it is saved,
    /// that it can be undone.
    private func consequence(changing: Int) -> String {
        guard let target = cleanedName else { return "" }
        guard chosen.count >= 2 else { return "Tick at least two genres to merge." }
        let targetKey = GenreName.key(target)
        let disappearing = chosen.filter { $0.key != targetKey }.map { "“\($0.name)”" }
        var text = "\(StatusBarText.tracks(changing)) get the genre “\(target)”."
        if !disappearing.isEmpty {
            text += " \(ListFormatter.localizedString(byJoining: disappearing)) \(disappearing.count == 1 ? "disappears" : "disappear") from Genres."
        }
        text += writesTags
            ? " The change is saved in the library and written to the files’ tags."
            : " The change is saved in the library; the files aren’t changed."
        text += " Nothing else about the tracks changes, and you can undo the merge."
        return text
    }

    private func merge() {
        guard isValid, let target = cleanedName, let edits = GenreEdits.live(undo: undo, container: container) else { return }
        isMerging = true
        failure = nil
        let merged = chosen
        Task {
            do {
                try await edits.merge(merged, into: target, reportsFailure: false)
                if let newKey = GenreName.key(target) {
                    for genre in merged { GenreWorkbench.shared.move(from: genre.key, to: newKey) }
                    didMerge(newKey)
                }
                dismiss()
            } catch {
                failure = "Couldn’t merge the genres — the library database didn’t answer. Nothing was changed."
                isMerging = false
            }
        }
    }
}
