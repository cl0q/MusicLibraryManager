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
    @State private var bpmSegments: [DanceabilityAnalyzer.BpmSegment] = []
    @State private var isLoadingBpmSegments = false

    // Hover state for fused play/pause cover art button
    @State private var isHoveringCover = false

    var body: some View {
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
            MetadataPanel(
                track: track,
                zoomLevel: $zoomLevel,
                exponent: $exponent,
                gain: $gain,
                waveformHeight: $waveformHeight
            )
        }
        .background(Color.mlmSurface)
        .frame(minWidth: 320)
        .onAppear {
            setupPlaybackVM()
            Task { await loadBpmSegments() }
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
                waveformHeight: $waveformHeight
            ) { fraction in
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
            .frame(height: waveformHeight)
 
            // Per-segment BPM markers (e.g. "1:00–2:00 · 150 BPM")
            bpmTimeline

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

    // MARK: - BPM Timeline

    /// A proportional strip of per-segment BPM markers below the waveform.
    @ViewBuilder
    private var bpmTimeline: some View {
        if isLoadingBpmSegments {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("BPM-Verlauf wird berechnet…")
                    .font(MLMFont.dataSmall)
                    .foregroundColor(.mlmInkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if bpmSegments.count > 1 {
            let total = bpmSegments.last?.endSeconds ?? 0
            if total > 0 {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(bpmSegments) { seg in
                            let fraction = (seg.endSeconds - seg.startSeconds) / total
                            Text("\(seg.bpm)")
                                .font(MLMFont.dataSmall)
                                .monospacedDigit()
                                .foregroundColor(.mlmInkSecondary)
                                .frame(width: max(0, geo.size.width * fraction - 1), height: 16)
                                .background(Color.mlmBase.opacity(0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .help(segmentTooltip(seg))
                        }
                    }
                }
                .frame(height: 16)
            }
        }
    }

    private func segmentTooltip(_ seg: DanceabilityAnalyzer.BpmSegment) -> String {
        "\(timecode(seg.startSeconds))–\(timecode(seg.endSeconds)) · \(seg.bpm) BPM"
    }

    private func timecode(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Compute per-segment BPM for local tracks (best-effort, off the main path).
    private func loadBpmSegments() async {
        guard track.isLocal, let organizedPath = track.organizedPath else { return }
        guard let configRepo = container.configRepository,
              let libraryRoot = try? await configRepo.getLibraryRoot(),
              !libraryRoot.isEmpty else { return }

        let fullPath = URL(fileURLWithPath: libraryRoot)
            .appendingPathComponent(organizedPath).path
        let analyzer = DanceabilityAnalyzer()
        guard analyzer.isAvailable else { return }

        isLoadingBpmSegments = true
        defer { isLoadingBpmSegments = false }
        if let segments = try? await analyzer.analyzeSegments(path: fullPath) {
            bpmSegments = segments
        }
    }
}
