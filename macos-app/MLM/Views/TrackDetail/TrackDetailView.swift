import SwiftUI

/// Track detail view — shows metadata, waveform, and playback controls
/// for a selected track.
///
/// Layout:
/// ```
/// ┌─────────────────────────────────────────────────┐
/// │  ♫ Track Title                          [▶ Play]│  Header
/// │  Artist — Album                                 │
/// ├─────────────────────────────────────────────────┤
/// │  ▃▅▇▅▃▁▃▅▇▅▃▁▃▅▅▃▁  Waveform  1:42 / 3:24     │  Waveform
/// ├─────────────────────────────────────────────────┤
/// │  Tags    │ Title      Track Title               │  Metadata
/// │          │ Artist     Artist Name               │
/// │  File    │ Format     FLAC                      │
/// │          │ Bitrate    1411 kbps                  │
/// │ Analysis │ LUFS       -14.2 LUFS                │
/// │          │ Energy     ▃▅▇▅▃ 4/5                 │
/// └─────────────────────────────────────────────────┘
/// ```
///
/// Phase 5 implementation. Accessible from:
/// - Double-clicking a track in LibraryTable
/// - "More Info" in TrackContextMenu
struct TrackDetailView: View {
    let track: Track
    @Environment(\.container) private var container
    @State private var playbackVM: PlaybackViewModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                headerSection

                Divider()
                    .background(Color.mlmEdge)

                // Waveform
                waveformSection

                Divider()
                    .background(Color.mlmEdge)

                // Metadata
                MetadataPanel(track: track)
            }
        }
        .background(Color.mlmSurface)
        .frame(minWidth: 320)
        .onAppear {
            setupPlaybackVM()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                // Track icon + status
                ZStack {
                    RoundedRectangle(cornerRadius: MLMSpacing.cornerRadius)
                        .fill(Color.mlmRaised)
                        .frame(width: 56, height: 56)

                    Image(systemName: isCurrentTrackPlaying ? "waveform" : "music.note")
                        .font(.system(size: 24))
                        .foregroundColor(isCurrentTrackPlaying ? .mlmAccent : .mlmInkMuted)
                        .symbolEffect(.variableColor, isActive: isCurrentTrackPlaying)
                }

                VStack(alignment: .leading, spacing: 3) {
                    // Title
                    Text(track.title)
                        .font(MLMFont.sectionHeader)
                        .foregroundColor(.mlmInk)
                        .lineLimit(2)

                    // Artist — Album
                    HStack(spacing: 4) {
                        Text(track.artist)
                            .font(MLMFont.body)
                            .foregroundColor(.mlmInkSecondary)

                        if !track.album.isEmpty {
                            Text("—")
                                .font(MLMFont.body)
                                .foregroundColor(.mlmInkMuted)
                            Text(track.album)
                                .font(MLMFont.body)
                                .foregroundColor(.mlmInkSecondary)
                        }
                    }

                    // Format badge
                    HStack(spacing: 6) {
                        formatBadge

                        if let bitrate = track.bitrate {
                            Text("\(bitrate) kbps")
                                .font(MLMFont.dataSmall)
                                .foregroundColor(.mlmInkMuted)
                        }

                        Text(track.formattedDuration)
                            .font(MLMFont.dataSmall)
                            .foregroundColor(.mlmInkMuted)
                    }
                }

                Spacer()

                // Play button
                if track.isLocal {
                    playButton
                }
            }
        }
        .padding(MLMSpacing.cardPadding)
    }

    private var formatBadge: some View {
        Text(track.format.uppercased())
            .font(MLMFont.badge)
            .foregroundColor(formatColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(formatColor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: MLMSpacing.cornerRadiusSmall))
    }

    private var formatColor: Color {
        switch track.format.lowercased() {
        case "flac", "alac": return .mlmSuccess
        case "mp3": return .mlmActive
        case "aac", "m4a": return .mlmWarning
        case "ogg": return .mlmAccent
        default: return .mlmInkMuted
        }
    }

    private var playButton: some View {
        Button {
            Task {
                guard let vm = playbackVM else { return }
                if isCurrentTrack {
                    vm.togglePlayPause()
                } else {
                    await vm.playTrack(track)
                }
            }
        } label: {
            Image(systemName: isCurrentTrackPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14))
                .foregroundColor(.mlmBase)
                .frame(width: 36, height: 36)
                .background(Color.mlmAccent)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isCurrentTrackPlaying ? "Pause" : "Play")
    }

    // MARK: - Waveform

    private var waveformSection: some View {
        VStack(spacing: 4) {
            WaveformView(
                data: playbackVM?.waveformData ?? [],
                progress: isCurrentTrack ? (playbackVM?.progress ?? 0) : 0,
                isLoading: playbackVM?.isLoadingWaveform ?? false
            ) { fraction in
                if isCurrentTrack {
                    playbackVM?.seekToProgress(fraction)
                }
            }
            .frame(height: 64)

            // Time display
            if isCurrentTrack, let vm = playbackVM {
                HStack {
                    Text(vm.formattedPosition)
                        .font(MLMFont.dataSmall)
                        .foregroundColor(.mlmInkSecondary)
                        .monospacedDigit()
                    Spacer()
                    Text(vm.formattedDuration)
                        .font(MLMFont.dataSmall)
                        .foregroundColor(.mlmInkMuted)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, MLMSpacing.cardPadding)
        .padding(.vertical, MLMSpacing.itemGap)
        .background(Color.mlmBase)
    }

    // MARK: - State Helpers

    /// Whether this track is the currently loaded track in the player.
    private var isCurrentTrack: Bool {
        guard let currentTrack = playbackVM?.currentTrack,
              let currentID = currentTrack.id,
              let trackID = track.id else {
            return false
        }
        return currentID == trackID
    }

    /// Whether this track is currently playing.
    private var isCurrentTrackPlaying: Bool {
        isCurrentTrack && (playbackVM?.isPlaying ?? false)
    }

    // MARK: - Setup

    private func setupPlaybackVM() {
        if playbackVM == nil {
            playbackVM = container.playbackViewModel
        }
    }
}
