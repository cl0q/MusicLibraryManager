import SwiftUI

/// Track detail view — shows metadata, waveform, and playback controls
/// for a selected track.
///
/// Phase 5 implementation. Accessible from:
/// - Double-clicking a track in LibraryTable
/// - "More Info" in TrackContextMenu
struct TrackDetailView: View {
    let track: Track

    /// Called when the user hits the X in the header. ContentView clears
    /// `selectedTrackForDetail`, which collapses the inspector.
    var onClose: (() -> Void)? = nil

    @Environment(\.container) private var container
    @State private var playbackVM: PlaybackViewModel?
    @State private var zoomLevel: CGFloat = 1.0
    @State private var exponent: Float = 1.5
    @State private var gain: Float = 1.0
    @State private var waveformHeight: CGFloat = 80.0

    // Hover state for fused play/pause cover art button
    @State private var isHoveringCover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Waveform
            waveformSection

            Divider()
                .background(Color.mlmEdge)

            // Header
            headerSection

            Divider()
                .background(Color.mlmEdge)

            // Metadata
            MetadataPanel(
                track: track,
                zoomLevel: $zoomLevel,
                exponent: $exponent,
                gain: $gain,
                waveformHeight: $waveformHeight
            )
        }
        .background(Color.mlmSurface)
        .frame(minWidth: ShellMetrics.trailingMinWidth)
        .onAppear {
            setupPlaybackVM()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                // Fused Play Button & Album Cover
                ZStack(alignment: .center) {
                    TrackCoverView(
                        trackId: track.id ?? 0,
                        size: .large,
                        cornerRadius: 6
                    )
                    .frame(width: 56, height: 56)

                    // Hover/Active Play Overlay
                    Color.black.opacity(isHoveringCover && track.isLocal ? 0.4 : 0.0)
                        .frame(width: 56, height: 56)
                        .cornerRadius(6)

                    if isHoveringCover && track.isLocal {
                        Image(systemName: isCurrentTrackPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .transition(.scale.combined(with: .opacity))
                    } else if isCurrentTrackPlaying {
                        // Subdued playing indicator waveform badge when not hovering
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.mlmAccent)
                            .padding(3)
                            .background(Color.mlmBase.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .offset(x: 18, y: 18) // position overlay offset
                    }
                }
                .frame(width: 56, height: 56)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHoveringCover = hovering
                    }
                    if hovering && track.isLocal {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .onTapGesture {
                    Task {
                        guard let vm = playbackVM else { return }
                        if isCurrentTrack {
                            vm.togglePlayPause()
                        } else if track.isLocal {
                            await vm.playTrack(track)
                        }
                    }
                }
                .help(track.isLocal ? (isCurrentTrackPlaying ? "Pause" : "Play") : "")

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

                VStack(alignment: .trailing, spacing: 6) {
                    if onClose != nil {
                        Button {
                            onClose?()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .help("Close detail panel")
                    }
                }
            }
        }
        .padding(12)
    }

    private var formatBadge: some View {
        Text(track.format.uppercased())
            .font(MLMFont.badge)
            .foregroundColor(formatColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(formatColor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
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

    // MARK: - Waveform

    private var waveformSection: some View {
        VStack(spacing: 4) {
            WaveformView(
                data: playbackVM?.waveformData ?? [],
                progress: isCurrentTrack ? (playbackVM?.progress ?? 0) : 0,
                isLoading: playbackVM?.isLoadingWaveform ?? false,
                isScrollable: (track.duration ?? 0) >= 420,
                zoomLevel: $zoomLevel,
                exponent: $exponent,
                gain: $gain,
                waveformHeight: $waveformHeight,
                needleTimeLabel: needleTimeLabel,
                onSeek: { fraction in
                    guard let vm = playbackVM else { return }
                    if isCurrentTrack {
                        vm.seekToProgress(fraction)
                    } else if track.isLocal {
                        Task {
                            await vm.playTrack(track)
                            vm.seekToProgress(fraction)
                        }
                    }
                }
            )
            .frame(height: waveformHeight)

            // Time display — static start/end timestamps. The needle time label
            // is now drawn inside the WaveformView Canvas, aligned by construction.
            if isCurrentTrack, let vm = playbackVM {
                HStack {
                    Text("0:00")
                        .font(.caption)
                        .foregroundColor(.mlmInkSecondary)
                    Spacer()
                    Text(vm.formattedDuration)
                        .font(.caption)
                        .foregroundColor(.mlmInkMuted)
                }
            }

            // Resize Splitter Handle
            Rectangle()
                .fill(Color.mlmEdge.opacity(0.15))
                .frame(height: 4)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        NSCursor.resizeUpDown.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let newHeight = waveformHeight + value.translation.height
                            waveformHeight = min(max(newHeight, 60), 250)
                        }
                )
                .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.mlmBase)
    }

    // MARK: - State Helpers
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

    private var needleTimeLabel: String? {
        guard isCurrentTrack,
              let vm = playbackVM,
              let progress = playbackVM?.progress,
              progress > 0, progress < 1.0 else {
            return nil
        }
        return vm.formattedPosition
    }
}
