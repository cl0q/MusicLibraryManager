import SwiftUI

/// Info ▸ Details (P-INSPECTOR-GENERAL): the tags as plain fields, then the playlists the
/// selection is in. Return or leaving a field commits (Tab commits and moves on), Esc reverts
/// (UC-KEY-20, UC-TRAIL-04); problems are said under the field (UC-SHEET-17); ⌘Z undoes.
struct InspectorDetailsTab: View {
    let model: InspectorModel

    @FocusState private var focus: TrackTagField?

    var body: some View {
        Form {
            Section {
                ForEach(model.editableFields) { field in
                    InspectorTagField(
                        model: model,
                        field: field,
                        focus: $focus,
                        commit: commit,
                        revert: revert
                    )
                }
            }
            .disabled(model.isLoadingSelection)
            // A new selection gets new fields; the old fields' late writes carry the old
            // generation and are ignored by the model (PP-INSPECTOR-04).
            .id(model.generation)

            InspectorPlaylistsSection(trackIDs: model.trackIDs)
        }
        .formStyle(.grouped)
        .onChange(of: focus) { old, new in
            // Leaving a field (Tab, a click elsewhere) commits it.
            if let old, old != new { commit(old) }
        }
    }

    /// Commit; an invalid value keeps (or puts back) the focus in its field with the reason.
    private func commit(_ field: TrackTagField) {
        Task {
            if await model.commitNow(field) == .invalid {
                focus = field
            }
        }
    }

    private func revert(_ field: TrackTagField) {
        model.revert(field)
        focus = nil
    }
}

/// One tag field: label, text field (`Mixed` / fallback as prompt), the issue line under it.
struct InspectorTagField: View {
    let model: InspectorModel
    let field: TrackTagField
    var focus: FocusState<TrackTagField?>.Binding
    let commit: (TrackTagField) -> Void
    let revert: (TrackTagField) -> Void

    var body: some View {
        let generation = model.generation
        let text = Binding(
            get: { model.text(for: field) },
            set: { model.setText($0, for: field, generation: generation) }
        )
        LabeledContent(field.label) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                TextField(field.label, text: text, prompt: Text(model.placeholder(for: field)))
                    .labelsHidden()
                    .focused(focus, equals: field)
                    .onSubmit { commit(field) }
                    .onExitCommand { revert(field) }
                    .font(field.isNumeric ? .body.monospacedDigit() : .body)
                    .disabled(model.saving.contains(field))
                if let issue = model.issues[field] {
                    InspectorIssueLine(
                        message: issue.message,
                        retry: issue.kind == .saveFailed ? { model.retry(field) } : nil
                    )
                }
            }
        }
    }
}

// MARK: - In playlists

/// The playlists the selection is in (P-INSPECTOR-GENERAL.E07): remove is undoable and removes
/// exactly the selection's rows (`PlaylistTrackRemoval`); for several tracks each playlist says
/// how many of them it holds. `Add to Playlist` (P-INSPECTOR.E12) replaces the old footer.
struct InspectorPlaylistsSection: View {
    let trackIDs: [Int64]

    @Environment(\.container) private var container
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ShellActions.self) private var shell: ShellActions?
    @State private var memberships: [InspectorQueries.Membership] = []

    private var menuSources: TrackMenuSources { TrackMenuSources.shared }

    var body: some View {
        Section("In playlists") {
            if memberships.isEmpty {
                Text(trackIDs.count == 1 ? "Not in any playlist." : "None of these tracks is in a playlist.")
                    .foregroundStyle(.secondary)
            }
            ForEach(memberships) { membership in
                HStack(spacing: Spacing.s) {
                    Label(membership.name, systemImage: "music.note.list")
                        .lineLimit(1)
                    Spacer(minLength: Spacing.s)
                    if trackIDs.count > 1 {
                        Text(membership.count == trackIDs.count
                             ? "all \(trackIDs.count.formatted(.number))"
                             : "\(membership.count.formatted(.number)) of \(trackIDs.count.formatted(.number))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button {
                        PlaylistTrackRemoval.remove(Set(trackIDs), fromPlaylist: membership.playlistID, name: membership.name, undo: undo)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from “\(membership.name)”")
                    .accessibilityLabel("Remove from “\(membership.name)”")
                }
            }
            Menu("Add to Playlist") {
                ForEach(menuSources.playlists) { playlist in
                    Button(playlist.name) {
                        if let id = playlist.id { shell?.addToPlaylist(id, trackIDs: trackIDs) }
                    }
                }
                if !menuSources.playlists.isEmpty { Divider() }
                Button("New Playlist…") { shell?.newPlaylistFromSelection(trackIDs: trackIDs) }
            }
            .disabled(shell == nil)
        }
        .task(id: trackIDs) {
            menuSources.loadIfNeeded(container: container)
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { note in
            if let info = note.userInfo, info["coverRevalidation"] != nil || (info["origin"] as? String) == "coverService" { return }
            Task { await load() }
        }
    }

    private func load() async {
        guard let pool = container.databaseManager?.pool else { return }
        memberships = (try? await InspectorQueries(database: pool).memberships(trackIDs: trackIDs)) ?? memberships
    }
}
