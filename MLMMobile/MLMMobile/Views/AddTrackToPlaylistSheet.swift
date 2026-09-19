import SwiftUI

/// Sheet for searching the indexed library and adding tracks to a playlist.
struct AddTrackToPlaylistSheet: View {
    let onAdd: (IndexedTrack) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery = ""
    @State private var results: [IndexedTrack] = []
    @State private var indexer: LibraryIndexer?

    init(onAdd: @escaping (IndexedTrack) -> Void) {
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search tracks…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .onChange(of: searchQuery) { _, newValue in
                            performSearch(query: newValue)
                        }
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding()

                // Results
                if results.isEmpty && !searchQuery.isEmpty {
                    ContentUnavailableView.search(text: searchQuery)
                } else if results.isEmpty {
                    ContentUnavailableView(
                        "Search Library",
                        systemImage: "magnifyingglass",
                        description: Text("Type to search your indexed library.")
                    )
                } else {
                    List(results) { track in
                        Button {
                            onAdd(track)
                        } label: {
                            TrackRowView(track: track)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Add Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                indexer = try? LibraryIndexer.makeDefault()
                performSearch(query: "")
            }
        }
    }

    private func performSearch(query: String) {
        guard let indexer else { return }
        do {
            if query.isEmpty {
                results = try indexer.fetchAllTracks()
            } else {
                results = try indexer.searchTracks(query: query)
            }
        } catch {
            results = []
        }
    }
}
