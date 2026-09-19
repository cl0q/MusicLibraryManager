import SwiftUI

/// Detail view for a single playlist: ordered track list, reorder, remove, add-from-library.
struct PlaylistDetailView: View {
    @StateObject var viewModel: PlaylistDetailViewModel
    @EnvironmentObject var playbackService: PlaybackService
    @State private var showingAddTrack = false

    var body: some View {
        Group {
            if viewModel.entries.isEmpty {
                ContentUnavailableView(
                    "Empty Playlist",
                    systemImage: "music.note.list",
                    description: Text("Add tracks from your library.")
                )
            } else {
                List {
                    ForEach(Array(viewModel.entries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            // Build queue from resolved tracks in playlist order
                            let resolvedTracks = viewModel.entryTracks.compactMap { $0 }
                            if let track = viewModel.entryTracks[safe: index] ?? nil {
                                let startIdx = resolvedTracks.firstIndex(where: { $0.uuid == track.uuid }) ?? index
                                playbackService.startPlayback(tracks: resolvedTracks, startIndex: startIdx)
                            }
                        } label: {
                            PlaylistTrackRow(
                                track: viewModel.entryTracks[safe: index] ?? nil,
                                entry: entry,
                                isLiked: viewModel.likedUUIDs.contains(entry.trackUUID),
                                onToggleLike: {
                                    viewModel.toggleLike(trackUUID: entry.trackUUID)
                                }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .onMove { source, destination in
                        viewModel.moveEntries(from: source, to: destination)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            viewModel.removeEntry(at: index)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(viewModel.playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        showingAddTrack = true
                    } label: {
                        Image(systemName: "plus")
                    }

                    EditButton()
                }
            }
        }
        .sheet(isPresented: $showingAddTrack) {
            AddTrackToPlaylistSheet { track in
                viewModel.addTrack(track)
            }
        }
        .onAppear {
            viewModel.load()
        }
    }
}

/// A track row in the playlist detail, with a heart button.
struct PlaylistTrackRow: View {
    let track: IndexedTrack?
    let entry: PlaylistEntry
    let isLiked: Bool
    let onToggleLike: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let track = track {
                EnergyIndicator(bucket: track.energyBucket)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body)
                        .lineLimit(1)
                    Text("\(track.artist) · \(track.album)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(track.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.relativePath)
                        .font(.body)
                        .lineLimit(1)
                    Text("Track not in library")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button(action: onToggleLike) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .foregroundStyle(isLiked ? .red : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
