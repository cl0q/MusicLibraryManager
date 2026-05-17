import SwiftUI

/// Multi-select sheet for adding tracks to a sync profile (D-05 / SYNC-v2-07).
///
/// Optimized for 10k+ track libraries: SwiftUI List virtualizes natively via
/// NSTableView under the hood — no pagination needed (T-38-04 mitigation).
/// Sheet dimensions: 500×600 per UI-SPEC Surface 4.
///
/// Loads all local tracks via container.trackRepository.fetchLocalTracks() on appear.
/// Filters in-memory (faster than DB round-trip for search keystroke).
/// Commits selection via vm.addTracks(Array(selectedIds)) then dismisses.
struct TrackPickerSheet: View {
    let vm: SyncViewModel

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var allTracks: [Track] = []
    @State private var selectedIds: Set<Int64> = []
    @State private var searchQuery: String = ""
    @FocusState private var searchFocused: Bool

    /// In-memory filter — faster than DB round-trip for keystroke search on 10k+ tracks.
    private var filtered: [Track] {
        guard !searchQuery.isEmpty else { return allTracks }
        let query = searchQuery.lowercased()
        return allTracks.filter {
            $0.title.lowercased().contains(query) ||
            $0.artist.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {

            // Sheet title bar
            HStack {
                Text("Tracks zum Profil hinzufügen")
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
                TextField("Nach Künstler oder Titel suchen…", text: $searchQuery)
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

            // Track list — SwiftUI List virtualizes for 10k+ rows (T-38-04 mitigation)
            List(filtered, id: \.id, selection: $selectedIds) { track in
                HStack(spacing: 8) {
                    Text("\(track.artist) — \(track.title)")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInk)
                        .lineLimit(1)
                    Spacer()
                    Text(track.format.uppercased())
                        .font(MLMFont.badge)
                        .foregroundColor(.mlmInkMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.mlmRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .padding(.vertical, 2)
                .tag(track.id ?? -1)
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
                        await vm.addTracks(Array(selectedIds))
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIds.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 500, height: 600)
        .background(Color.mlmBase)
        .task {
            if let repo = container.trackRepository {
                allTracks = (try? await repo.fetchLocalTracks()) ?? []
            }
            searchFocused = true
        }
    }
}
