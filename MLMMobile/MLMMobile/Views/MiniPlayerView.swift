import SwiftUI

/// Persistent mini player bar shown above the tab bar when something is playing/queued.
struct MiniPlayerView: View {
    @EnvironmentObject var playbackService: PlaybackService
    @State private var showingFullPlayer = false

    var body: some View {
        if !playbackService.queue.isEmpty {
            Button {
                showingFullPlayer = true
            } label: {
                HStack(spacing: 12) {
                    // Artwork thumbnail
                    artworkThumbnail

                    VStack(alignment: .leading, spacing: 2) {
                        if let item = playbackService.queue[safe: playbackService.currentIndex] {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(item.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // Play/pause button
                    Button {
                        playbackService.togglePlayPause()
                    } label: {
                        Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    // Next button
                    Button {
                        playbackService.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingFullPlayer) {
                FullPlayerView()
                    .environmentObject(playbackService)
            }
        }
    }

    @ViewBuilder
    private var artworkThumbnail: some View {
        if let artwork = playbackService.currentArtwork {
            Image(uiImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
        }
    }
}
