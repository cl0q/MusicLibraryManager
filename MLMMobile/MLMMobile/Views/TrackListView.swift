import SwiftUI

/// Displays the browsable track list with search and energy-bucket filter.
struct TrackListView: View {
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @EnvironmentObject var playbackService: PlaybackService

    var body: some View {
        VStack(spacing: 0) {
            // Search + filter bar
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search tracks…", text: $libraryViewModel.searchQuery)
                        .textFieldStyle(.plain)
                    if !libraryViewModel.searchQuery.isEmpty {
                        Button {
                            libraryViewModel.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                EnergyBucketFilter(
                    selected: $libraryViewModel.selectedEnergyBucket
                )
            }
            .padding(.horizontal)
            .padding(.top, 8)

            // Track list or state views
            if libraryViewModel.isLoading {
                ProgressView("Loading library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = libraryViewModel.loadError {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if libraryViewModel.isEmpty {
                EmptyStateView()
            } else {
                List {
                    ForEach(Array(libraryViewModel.tracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            playbackService.startPlayback(
                                tracks: libraryViewModel.tracks,
                                startIndex: index
                            )
                        } label: {
                            TrackRowView(
                                track: track,
                                isLiked: libraryViewModel.likedUUIDs.contains(track.uuid),
                                onToggleLike: {
                                    libraryViewModel.toggleLike(trackUUID: track.uuid)
                                }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
    }
}
