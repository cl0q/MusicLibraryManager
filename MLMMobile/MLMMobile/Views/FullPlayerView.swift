import SwiftUI

/// Full-screen player with artwork, seek slider, transport controls, and queue list.
struct FullPlayerView: View {
    @EnvironmentObject var playbackService: PlaybackService
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let item = playbackService.queue[safe: playbackService.currentIndex] {
                    // Artwork
                    artworkView(for: item)
                        .padding(.horizontal, 32)

                    // Title / Artist / Album
                    VStack(spacing: 4) {
                        Text(item.title)
                            .font(.title2.weight(.bold))
                            .lineLimit(1)
                        Text(item.artist)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(item.album)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal)

                    // Seek slider
                    seekSlider

                    // Transport controls
                    transportControls

                    // Shuffle + Repeat toggles
                    modeToggles

                    // Missing file notice
                    if let notice = playbackService.missingFileNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal)
                    }

                    Spacer()

                    // Queue button
                    Button {
                        showQueue = true
                    } label: {
                        Label("Queue (\(playbackService.queue.count))", systemImage: "list.bullet")
                            .font(.subheadline)
                    }
                    .padding(.bottom)
                } else {
                    ContentUnavailableView(
                        "Nothing Playing",
                        systemImage: "music.note",
                        description: Text("Select a track to start playback.")
                    )
                }
            }
            .padding(.top)
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showQueue) {
                QueueListView()
                    .environmentObject(playbackService)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private func artworkView(for item: QueueItem) -> some View {
        if let artwork = playbackService.currentArtwork {
            Image(uiImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 8)
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.15))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var seekSlider: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { playbackService.currentTime },
                    set: { playbackService.seek(to: $0) }
                ),
                in: 0...max(playbackService.duration, 1)
            )
            .padding(.horizontal)

            HStack {
                Text(formatTime(playbackService.currentTime))
                Spacer()
                Text("-\(formatTime(max(playbackService.duration - playbackService.currentTime, 0)))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 40) {
            Button {
                playbackService.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
            }

            Button {
                playbackService.togglePlayPause()
            } label: {
                Image(systemName: playbackService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }

            Button {
                playbackService.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
            }
        }
        .foregroundStyle(.primary)
    }

    private var modeToggles: some View {
        HStack(spacing: 40) {
            Button {
                playbackService.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(playbackService.shuffleEnabled ? Color.accentColor : .secondary)
            }

            Button {
                playbackService.cycleRepeatMode()
            } label: {
                Image(systemName: repeatIcon)
                    .foregroundStyle(playbackService.repeatMode != .off ? Color.accentColor : .secondary)
            }
        }
        .font(.title3)
    }

    private var repeatIcon: String {
        switch playbackService.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite && time >= 0 else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Queue list shown in a sheet from the full player.
struct QueueListView: View {
    @EnvironmentObject var playbackService: PlaybackService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(playbackService.queue.enumerated()), id: \.element.id) { index, item in
                    Button {
                        playbackService.jumpTo(index: index)
                        dismiss()
                    } label: {
                        HStack {
                            if index == playbackService.currentIndex {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 20)
                            } else {
                                Color.clear.frame(width: 20)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.body)
                                    .foregroundStyle(index == playbackService.currentIndex ? Color.accentColor : .primary)
                                    .lineLimit(1)
                                Text(item.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if item.resolvedURL == nil {
                                Image(systemName: "cloud.slash")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
