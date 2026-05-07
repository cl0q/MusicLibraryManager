import SwiftUI

/// Persistent mini-player bar at the bottom of the window.
///
/// Wired to `PlaybackViewModel` from the DependencyContainer.
/// Shows track info, play/pause, seekable progress bar, and time display.
///
/// ## States
/// - **Empty** — No track loaded (muted placeholder text)
/// - **Playing** — Track info, animated play button, live progress
/// - **Paused** — Track info, play button, frozen progress
struct MiniPlayerView: View {
    @Environment(\.container) private var container
    @State private var playbackVM: PlaybackViewModel?

    /// Whether the user is currently dragging the seek bar.
    @State private var isSeeking = false
    @State private var seekFraction: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            // Play/pause button
            playPauseButton

            // Track info
            trackInfo

            Spacer()

            // Seekable progress bar
            progressBar
                .frame(width: 200)

            // Time display
            timeDisplay
        }
        .padding(.horizontal, MLMSpacing.pagePadding)
        .frame(height: MLMSpacing.miniPlayerHeight)
        .background(Color.mlmSurface)
        .onAppear {
            playbackVM = container.playbackViewModel
        }
    }

    // MARK: - Play/Pause Button

    private var playPauseButton: some View {
        Button {
            guard let vm = playbackVM, vm.hasTrack else { return }
            vm.togglePlayPause()
        } label: {
            Image(systemName: playbackIcon)
                .font(.system(size: 12))
                .foregroundColor(hasTrack ? .mlmInk : .mlmInkMuted)
        }
        .buttonStyle(.plain)
        .disabled(!hasTrack)
        .frame(width: 24, height: 24)
    }

    private var playbackIcon: String {
        guard let vm = playbackVM else { return "play.fill" }
        return vm.isPlaying ? "pause.fill" : "play.fill"
    }

    // MARK: - Track Info

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let track = playbackVM?.currentTrack {
                Text(track.title)
                    .font(MLMFont.miniPlayerTitle)
                    .foregroundColor(.mlmInk)
                    .lineLimit(1)

                Text(track.artist)
                    .font(MLMFont.miniPlayerArtist)
                    .foregroundColor(.mlmInkSecondary)
                    .lineLimit(1)
            } else {
                Text("No track playing")
                    .font(MLMFont.miniPlayerTitle)
                    .foregroundColor(.mlmInkMuted)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Progress Bar (seekable)

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.mlmEdge)
                    .frame(height: 2)

                // Progress fill
                RoundedRectangle(cornerRadius: 1)
                    .fill(hasTrack ? Color.mlmAccent : Color.mlmInkMuted)
                    .frame(
                        width: geometry.size.width * CGFloat(displayProgress),
                        height: 2
                    )

                // Seek knob (visible only when seeking)
                if hasTrack {
                    Circle()
                        .fill(Color.mlmAccent)
                        .frame(width: 8, height: 8)
                        .offset(
                            x: geometry.size.width * CGFloat(displayProgress) - 4,
                            y: 0
                        )
                        .opacity(isSeeking ? 1 : 0)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard hasTrack else { return }
                        isSeeking = true
                        let fraction = value.location.x / geometry.size.width
                        seekFraction = min(max(fraction, 0), 1)
                    }
                    .onEnded { value in
                        guard hasTrack else { return }
                        let fraction = value.location.x / geometry.size.width
                        let clampedFraction = min(max(fraction, 0), 1)
                        playbackVM?.seekToProgress(clampedFraction)
                        isSeeking = false
                    }
            )
            .onHover { hovering in
                if !hovering {
                    isSeeking = false
                }
            }
        }
        .frame(height: 12) // Hit target height
    }

    /// Progress to display — uses seek position while dragging, otherwise live progress.
    private var displayProgress: Double {
        if isSeeking {
            return seekFraction
        }
        return playbackVM?.progress ?? 0
    }

    // MARK: - Time Display

    private var timeDisplay: some View {
        Group {
            if hasTrack, let vm = playbackVM {
                Text("\(vm.formattedPosition) / \(vm.formattedDuration)")
                    .font(MLMFont.dataSmall)
                    .foregroundColor(.mlmInkSecondary)
                    .monospacedDigit()
            } else {
                Text("—:— / —:—")
                    .font(MLMFont.dataSmall)
                    .foregroundColor(.mlmInkMuted)
            }
        }
    }

    // MARK: - Helpers

    private var hasTrack: Bool {
        playbackVM?.hasTrack ?? false
    }
}
