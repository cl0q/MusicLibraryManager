import SwiftUI

/// Toolbar-mounted player widget — centered via `.principal` placement.
///
/// Shows transport controls, album art fallback, track info, and a scrubber.
/// Replaces the bottom-pinned MiniPlayerView.
struct PlayerBar: View {
    let viewModel: PlaybackViewModel

    @State private var isSeeking = false
    @State private var seekFraction: Double = 0

    var body: some View {
        HStack(spacing: 8) {
            transportCluster
            coverThumbnail
            trackInfoColumn
            scrubberSection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minWidth: 360, idealWidth: 480, maxWidth: 560)
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
        HStack(spacing: 2) {
            // TODO: wire to queue when PlaybackViewModel gains a queue
            Button {} label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .disabled(true)

            Button { viewModel.togglePlayPause() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(viewModel.hasTrack ? .primary : .secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasTrack)

            // TODO: wire to queue when PlaybackViewModel gains a queue
            Button {} label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .disabled(true)
        }
    }

    // MARK: - Cover Thumbnail

    private var coverThumbnail: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color(nsColor: .controlColor))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)
    }

    // MARK: - Track Info

    private var trackInfoColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
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
        .layoutPriority(1)
    }

    // MARK: - Scrubber

    private var scrubberSection: some View {
        HStack(spacing: 4) {
            Text(viewModel.hasTrack ? viewModel.formattedPosition : "—:——")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)

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
            .frame(minWidth: 80)

            Text(viewModel.hasTrack ? viewModel.formattedDuration : "—:——")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private var scrubberBinding: Binding<Double> {
        Binding(
            get: { isSeeking ? seekFraction : viewModel.progress },
            set: { seekFraction = $0 }
        )
    }

    private func subtitleText(for track: Track) -> String {
        [track.artist, track.album]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
