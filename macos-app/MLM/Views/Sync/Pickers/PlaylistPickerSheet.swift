import SwiftUI

/// Multi-select sheet for adding playlists to a sync profile (D-05 / SYNC-v2-06).
///
/// Pattern: PlaylistDetailView.swift List with Set<Int64> selection + search field
/// (lines 178-247). Sheet dimensions: 400×500 per UI-SPEC Surface 3.
///
/// Loads all playlists via container.playlistRepository.fetchAll() on appear.
/// Commits selection via vm.addPlaylists(Array(selectedIds)) then dismisses.
struct PlaylistPickerSheet: View {
    let vm: SyncViewModel

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var allPlaylists: [Playlist] = []
    @State private var selectedIds: Set<Int64> = []
    @State private var searchQuery: String = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [Playlist] {
        guard !searchQuery.isEmpty else { return allPlaylists }
        return allPlaylists.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var body: some View {
        VStack(spacing: 0) {

            // Sheet title bar
            HStack {
                Text("Playlists zum Profil hinzufügen")
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
                TextField("Playlist-Namen durchsuchen…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInk)
                    .focused($searchFocused)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
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

            // Playlist list — checkbox-style toggle per row.
            // Plain click toggles selection (no Cmd/Shift needed).
            List(filtered, id: \.id) { playlist in
                let pid = playlist.id ?? -1
                let isSelected = selectedIds.contains(pid)
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundColor(isSelected ? .accentColor : .mlmInkMuted)
                    Text(playlist.name)
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInk)
                    Spacer()
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelected {
                        selectedIds.remove(pid)
                    } else {
                        selectedIds.insert(pid)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.mlmBase)

            Divider().background(Color.mlmEdge)

            // Action buttons
            HStack {
                Button("Abbrechen") { dismiss() }
                    .buttonStyle(.borderless)
                    .foregroundColor(.mlmInkSecondary)
                Spacer()
                Button(
                    selectedIds.isEmpty
                        ? "Hinzufügen"
                        : "Hinzufügen (\(selectedIds.count))"
                ) {
                    Task {
                        await vm.addPlaylists(Array(selectedIds))
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIds.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 400, height: 500)
        .background(Color.mlmBase)
        .task {
            if let repo = container.playlistRepository {
                allPlaylists = (try? await repo.fetchAll()) ?? []
            }
            searchFocused = true
        }
    }
}
