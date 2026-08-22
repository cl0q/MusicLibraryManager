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
    @State private var isLoading = true
    @State private var loadingError: String?
    @FocusState private var searchFocused: Bool

    enum FilterChip: String, CaseIterable {
        case all = "All tracks"
        case local = "Local only"
        case artwork = "With artwork"
    }

    @State private var activeFilter: FilterChip = .all
    @State private var artworkTrackIds: Set<Int64> = []

    /// In-memory filter — faster than DB round-trip for keystroke search on 10k+ tracks.
    private var filtered: [Track] {
        var tracks = allTracks
        
        switch activeFilter {
        case .all:
            break
        case .local:
            tracks = tracks.filter { $0.isLocal }
        case .artwork:
            tracks = tracks.filter { artworkTrackIds.contains($0.id ?? -1) }
        }
        
        guard !searchQuery.isEmpty else { return tracks }
        return tracks.filter { $0.matches(searchQuery: searchQuery) }
    }

    private var resultCountLabel: String {
        let total = allTracks.count
        let shown = filtered.count
        let selected = selectedIds.count
        let countPart: String
        if searchQuery.isEmpty {
            countPart = "\(total) tracks"
        } else {
            countPart = "\(shown) of \(total) tracks"
        }
        if selected > 0 {
            return "\(countPart) · \(selected) selected"
        }
        return countPart
    }

    var body: some View {
        VStack(spacing: 0) {

            // Sheet title bar
            HStack {
                Text("Add tracks to profile")
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
                Spacer()
            }
            .padding(16)
            .background(Color.mlmBase)

            Divider().background(Color.mlmEdge)

            // Search field — prominent: larger font, more padding, focus ring.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundColor(.mlmInkMuted)
                TextField("Search artist or title...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(.mlmInk)
                    .focused($searchFocused)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.mlmInkMuted)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.mlmRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(searchFocused ? Color.accentColor.opacity(0.6) : Color.mlmEdge, lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FilterChip.allCases, id: \.self) { chip in
                        Button {
                            activeFilter = chip
                        } label: {
                            Text(chip.rawValue)
                                .font(MLMFont.muted)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(activeFilter == chip ? Color.accentColor : Color.mlmRaised)
                                .foregroundColor(activeFilter == chip ? .white : .mlmInk)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("track_picker_filter_chip")
                        .accessibilityLabel(chip.rawValue)
                        .accessibilityValue(activeFilter == chip ? "Selected" : "Not selected")
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 4)

            // Result count line
            HStack {
                Text(resultCountLabel)
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
                Spacer()
                if !selectedIds.isEmpty {
                    Button("Clear selection") { selectedIds.removeAll() }
                        .buttonStyle(.borderless)
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            tracksContent

            Divider().background(Color.mlmEdge)

            // Action buttons
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
                    .foregroundColor(.mlmInkSecondary)
                Spacer()
                Button(
                    selectedIds.isEmpty
                        ? "Add"
                        : "Add (\(selectedIds.count))"
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
        .task { await loadTracks() }
    }

    @ViewBuilder
    private var tracksContent: some View {
        if isLoading {
            ProgressView("Loading tracks...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadingError {
            ContentUnavailableView {
                Label("Could not load tracks", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadingError)
            } actions: {
                Button("Retry") { Task { await loadTracks() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if allTracks.isEmpty {
            ContentUnavailableView {
                Label("No tracks", systemImage: "music.note")
            } description: {
                Text("Import music into your library before adding tracks to a sync profile.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: searchQuery)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filtered, id: \.id) { track in
                let tid = track.id ?? -1
                let isSelected = selectedIds.contains(tid)
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundColor(isSelected ? .accentColor : .mlmInkMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(MLMFont.body)
                            .foregroundColor(.mlmInk)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(track.format.uppercased())
                        .font(MLMFont.badge)
                        .foregroundColor(.mlmInkMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.mlmRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelected {
                        selectedIds.remove(tid)
                    } else {
                        selectedIds.insert(tid)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.mlmBase)
        }
    }

    private func loadTracks() async {
        isLoading = true
        loadingError = nil
        defer {
            isLoading = false
            searchFocused = true
        }

        guard let repo = container.trackRepository else {
            loadingError = "Tracks are unavailable. Try again after the library finishes loading."
            return
        }

        do {
            async let tracks = repo.fetchAllTracks()
            async let artworkIDs = repo.fetchTrackIdsWithArtwork()
            allTracks = try await tracks
            artworkTrackIds = try await artworkIDs
        } catch {
            allTracks = []
            artworkTrackIds = []
            loadingError = "Tracks could not be loaded. Try again."
        }
    }
}
