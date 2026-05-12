import SwiftUI

/// Toolbar-mounted player widget — centered via `.principal` placement.
///
/// Shows transport controls, album art fallback, track info, scrubber, and volume.
struct PlayerBar: View {
    let viewModel: PlaybackViewModel

    @State private var isSeeking = false
    @State private var seekFraction: Double = 0
    @State private var volume: Double = 1.0

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
            // TODO: wire to queue when PlaybackViewModel gains a queue
            Button {} label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .disabled(true)

            Button { viewModel.togglePlayPause() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(viewModel.hasTrack ? .primary : .secondary)
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasTrack)

            // TODO: wire to queue when PlaybackViewModel gains a queue
            Button {} label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .disabled(true)
        }
    }

    // MARK: - Cover Thumbnail

    private var coverThumbnail: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color(nsColor: .controlColor))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 40, height: 40)
    }

    // MARK: - Track Info

    private var trackInfoColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let error = viewModel.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            } else if let track = viewModel.currentTrack {
                HStack(spacing: 4) {
                    if viewModel.isPreviewMode {
                        Text("PREVIEW")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    Text(track.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text(subtitleText(for: track))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Not Playing")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 80, maxWidth: 160)
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
