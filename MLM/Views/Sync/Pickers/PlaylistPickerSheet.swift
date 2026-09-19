import SwiftUI

/// Multi-select sheet for adding playlists to a sync profile (D-05 / SYNC-v2-06).
///
/// Included playlists stay visible, are visibly marked "In profile", and
/// cannot be selected again. Backed by `PlaylistPickerModel` for pure
/// selection/filter logic.
///
/// Loads all playlists via container.playlistRepository.fetchAll() on appear.
/// Commits selection via vm.addPlaylists(model.commitIDs) then dismisses.
struct PlaylistPickerSheet: View {
    let vm: SyncViewModel

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var allPlaylists: [Playlist] = []
    @State private var model: PlaylistPickerModel?
    @State private var isLoading = true
    @State private var loadingError: String?
    @FocusState private var searchFocused: Bool

    private var includedIDs: Set<Int64> {
        Set(vm.profilePlaylists.compactMap { $0.id })
    }

    var body: some View {
        VStack(spacing: 0) {

            // Sheet title bar
            HStack {
                Text("Add playlists to profile")
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
                Spacer()
            }
            .padding(16)
            .background(Color.mlmBase)

            Divider().background(Color.mlmEdge)

            // Search field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.mlmInkMuted)
                TextField("Search playlist names...", text: bindingSearchQuery)
                    .textFieldStyle(.plain)
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInk)
                    .focused($searchFocused)
                if let query = model?.searchQuery, !query.isEmpty {
                    Button {
                        model?.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.mlmInkMuted)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.mlmRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(16)

            playlistsContent

            Divider().background(Color.mlmEdge)

            // Action buttons
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
                    .foregroundColor(.mlmInkSecondary)
                Spacer()
                Button(
                    (model?.commitIDs.isEmpty ?? true)
                        ? "Add"
                        : "Add (\(model!.commitIDs.count))"
                ) {
                    guard let model else { return }
                    Task {
                        await vm.addPlaylists(model.commitIDs)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model?.commitIDs.isEmpty ?? true)
            }
            .padding(16)
        }
        .frame(width: 400, height: 500)
        .background(Color.mlmBase)
        .task { await loadPlaylists() }
    }

    private var bindingSearchQuery: Binding<String> {
        Binding(
            get: { model?.searchQuery ?? "" },
            set: { model?.searchQuery = $0 }
        )
    }

    @ViewBuilder
    private var playlistsContent: some View {
        if isLoading {
            ProgressView("Loading playlists...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadingError {
            ContentUnavailableView {
                Label("Could not load playlists", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadingError)
            } actions: {
                Button("Retry") { Task { await loadPlaylists() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if allPlaylists.isEmpty {
            ContentUnavailableView {
                Label("No playlists", systemImage: "music.note.list")
            } description: {
                Text("Create one first, then add it to this sync profile.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let model, model.rows.isEmpty {
            ContentUnavailableView.search(text: model.searchQuery)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let model {
            List(model.rows) { row in
                playlistRow(row)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.mlmBase)
        }
    }

    @ViewBuilder
    private func playlistRow(_ row: PlaylistPickerModel.Row) -> some View {
        HStack(spacing: 10) {
            if row.isIncluded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.mlmInkMuted)
            } else {
                Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(row.isSelected ? .accentColor : .mlmInkMuted)
            }
            Text(row.playlist.name)
                .font(MLMFont.body)
                .foregroundColor(row.isIncluded ? Color.mlmInkSecondary : Color.mlmInk)
            Spacer()
            if row.isIncluded {
                Text("In profile")
                    .font(MLMFont.badge)
                    .foregroundColor(.mlmInkMuted)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.mlmRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !row.isIncluded else { return }
            model?.toggle(row.id)
        }
    }

    private func loadPlaylists() async {
        isLoading = true
        loadingError = nil
        defer {
            isLoading = false
            searchFocused = true
        }

        guard let repo = container.playlistRepository else {
            loadingError = "Playlists are unavailable. Try again after the library finishes loading."
            return
        }

        do {
            allPlaylists = try await repo.fetchAll()
            model = PlaylistPickerModel(
                allPlaylists: allPlaylists,
                includedIDs: includedIDs
            )
        } catch {
            allPlaylists = []
            model = nil
            loadingError = "Playlists could not be loaded. Try again."
        }
    }
}
