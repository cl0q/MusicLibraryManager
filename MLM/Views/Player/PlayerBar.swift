import SwiftUI

// MARK: Accessibility labels for shotty UI automation (snake_case literals)

/// Toolbar-mounted player widget — centered via `.principal` placement.
///
/// Shows playback control, album art fallback, track info, scrubber, and volume.
struct PlayerBar: View {
    let viewModel: PlaybackViewModel

    @State private var isSeeking = false
    @State private var seekFraction: Double = 0
    @State private var volume: Double = 1.0
    @State private var showLargeCover = false

    var body: some View {
        HStack(spacing: 10) {
            transportCluster
            coverThumbnail
            trackInfoColumn
            scrubberSection
            volumeSection
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minWidth: 440, idealWidth: 620, maxWidth: 800)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Transport Cluster

    private var transportCluster: some View {
        HStack(spacing: 6) {
            Button {
                Task { await viewModel.back() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(viewModel.hasTrack ? .primary : .secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasTrack)
            .accessibilityIdentifier("back_button")
            .accessibilityLabel("back_button")

            Button { viewModel.togglePlayPause() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(viewModel.hasTrack ? .primary : .secondary)
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasTrack)
            .accessibilityIdentifier("play_pause_button")
            .accessibilityLabel("play_pause_button")

            Button {
                Task { await viewModel.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(viewModel.hasTrack ? .primary : .secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasTrack)
            .accessibilityIdentifier("forward_button")
            .accessibilityLabel("forward_button")
        }
    }

    // MARK: - Cover Thumbnail

    @Environment(\.container) private var container

    private var coverThumbnail: some View {
        // UI-SPEC Surface 3: 40pt thumbnail, cornerRadius 5
        TrackCoverView(
            trackId: viewModel.currentTrack?.id ?? 0,
            size: .small,
            cornerRadius: 5
        )
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
        .onTapGesture {
            guard viewModel.hasTrack else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                showLargeCover.toggle()
            }
        }
        .popover(
            isPresented: $showLargeCover,
            attachmentAnchor: .point(.bottom),
            arrowEdge: .top
        ) {
            TrackCoverView(
                trackId: viewModel.currentTrack?.id ?? 0,
                size: .large,
                cornerRadius: 12
            )
            .frame(width: 320, height: 320)
            .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 8)
            .padding(20)
            .presentationBackground(.clear)
            .onTapGesture {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    showLargeCover = false
                }
            }
        }
    }

    // MARK: - Track Info

    private var trackInfoColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let track = viewModel.currentTrack {
                HStack(spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text(subtitleText(for: track))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let error = viewModel.errorMessage {
                    playbackError(error)
                }
            } else if let error = viewModel.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                    if viewModel.unavailableTrack != nil {
                        Button("Retry") {
                            Task { await viewModel.retryUnavailableTrack() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("retry_button")
                        .accessibilityLabel("retry_button")
                    }
                }
            } else {
                Text("Not Playing")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 80, maxWidth: 160)
    }

    @ViewBuilder
    private func playbackError(_ error: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
            Text(error)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.red)
                .lineLimit(1)
            if viewModel.unavailableTrack != nil {
                Button("Retry") {
                    Task { await viewModel.retryUnavailableTrack() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("retry_button")
                .accessibilityLabel("retry_button")
            }
        }
    }

    // MARK: - Scrubber

    private var scrubberSection: some View {
        HStack(spacing: 5) {
            Text(viewModel.hasTrack ? viewModel.formattedPosition : "—:——")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            Slider(value: scrubberBinding, in: 0...1) { editing in
                if editing {
                    seekFraction = viewModel.progress
                    isSeeking = true
                } else {
                    viewModel.seekToProgress(seekFraction)
                    isSeeking = false
                }
            }
            .disabled(!viewModel.hasTrack)
            .accessibilityIdentifier("position_slider")
            .accessibilityLabel("position_slider")

            Text(viewModel.hasTrack ? viewModel.formattedDuration : "—:——")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
        .layoutPriority(2)
    }

    // MARK: - Volume

    private var volumeSection: some View {
        HStack(spacing: 4) {
            Image(systemName: volumeIcon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Slider(value: $volume, in: 0...1)
                .frame(width: 76)
                .onChange(of: volume) { _, newValue in
                    viewModel.setVolume(newValue)
                }
                .accessibilityIdentifier("volume_slider")
                .accessibilityLabel("volume_slider")
        }
    }

    // MARK: - Helpers

    private var scrubberBinding: Binding<Double> {
        Binding(
            get: { isSeeking ? seekFraction : viewModel.progress },
            set: { seekFraction = $0 }
        )
    }

    private var volumeIcon: String {
        if volume < 0.01 { return "speaker.slash.fill" }
        if volume < 0.4 { return "speaker.fill" }
        return "speaker.wave.2.fill"
    }

    private func subtitleText(for track: Track) -> String {
        [track.artist, track.album]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
